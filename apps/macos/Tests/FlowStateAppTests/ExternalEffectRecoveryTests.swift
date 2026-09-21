import Foundation
import FlowStateCore
import FlowStateCloud
import Testing
@testable import FlowStateApp

private func recovery(
    planID: String,
    receiptID: String,
    operationFingerprint: String,
    summary: String = "Opened the reviewed URL handoff"
) -> ExternalEffectRecovery {
    ExternalEffectRecovery(
        planID: planID,
        ordinal: 0,
        receiptID: receiptID,
        summary: summary,
        operationFingerprint: operationFingerprint
    )
}

private let reviewedOpenURL = NativePlanAction(
    kind: .openURL,
    targetBundleIdentifier: "com.brave.Browser",
    parameters: .openURL(url: "https://private.example/project?token=secret"),
    capability: "app.control",
    executor: "service",
    requiresApproval: false,
    route: .structuredIntegration,
    verifier: NativePlanVerifier(kind: .externalEffectReconciled),
    risk: .reversible
)

@Test("unresolved handoff receipts persist, stay redacted, and reconcile one at a time")
func externalEffectRecoveryPersistsEveryReceipt() throws {
    let defaults = try #require(UserDefaults(suiteName: "flowstate.external-effects.\(UUID().uuidString)"))
    let first = recovery(
        planID: "plan-old-1",
        receiptID: "receipt-1",
        operationFingerprint: externalEffectOperationFingerprint(action: reviewedOpenURL)
    )
    let second = recovery(
        planID: "plan-old-2",
        receiptID: "receipt-2",
        operationFingerprint: externalEffectOperationFingerprint(action: reviewedOpenURL),
        summary: "Opened the Gmail compose handoff"
    )
    let store = ExternalEffectRecoveryStore(defaults: defaults)
    store.upsert(first)
    store.upsert(second)

    let persisted = String(decoding: try #require(defaults.data(forKey: ExternalEffectRecoveryStore.defaultKey)), as: UTF8.self)
    #expect(!persisted.contains("owner@example.com"))
    #expect(!persisted.contains("private.example"))
    #expect(!persisted.contains("quarterly results are private"))

    let restarted = ExternalEffectRecoveryStore(defaults: defaults)
    #expect(Set(restarted.list()) == Set([first, second]))
    restarted.remove(receiptID: first.receiptID)
    #expect(restarted.list() == [second])
    restarted.remove(receiptID: second.receiptID)
    #expect(restarted.list().isEmpty)
}

@Test("canonical operation fingerprints block the same operation across plan IDs but allow distinct operations")
func externalEffectRecoveryUsesCanonicalOperationFingerprint() {
    let old = recovery(
        planID: "plan-old",
        receiptID: "receipt-old",
        operationFingerprint: externalEffectOperationFingerprint(action: reviewedOpenURL)
    )
    let sameOperation = recovery(
        planID: "plan-new",
        receiptID: "receipt-new",
        operationFingerprint: externalEffectOperationFingerprint(action: reviewedOpenURL)
    )
    let differentURL = NativePlanAction(
        kind: .openURL,
        targetBundleIdentifier: "com.brave.Browser",
        parameters: .openURL(url: "https://private.example/other"),
        capability: "app.control",
        executor: "service",
        requiresApproval: false,
        route: .structuredIntegration,
        verifier: NativePlanVerifier(kind: .externalEffectReconciled),
        risk: .reversible
    )
    let differentOperation = recovery(
        planID: "plan-new",
        receiptID: "receipt-other",
        operationFingerprint: externalEffectOperationFingerprint(action: differentURL)
    )

    #expect(externalEffectRecoveryBlocks(old, operationFingerprint: sameOperation.operationFingerprint))
    #expect(!externalEffectRecoveryBlocks(old, operationFingerprint: differentOperation.operationFingerprint))
    #expect(old.planID != sameOperation.planID)
}

@Test("external effect recovery is persisted before launch and survives cancellation")
func externalEffectRecoveryPersistsBeforeStructuredLaunch() async throws {
    let defaults = try #require(UserDefaults(suiteName: "flowstate.external-effects.ordering.\(UUID().uuidString)"))
    let store = ExternalEffectRecoveryStore(defaults: defaults)
    let plan = CloudProposal(
        id: "plan-before-launch",
        fingerprint: "plan-fingerprint",
        actions: [reviewedOpenURL],
        expiresAt: 2_000_000_000_000,
        generation: 1
    )
    let reservation = CloudSession.ExternalEffectReservation(
        receiptID: "receipt-before-launch",
        requestFingerprint: externalEffectOperationFingerprint(action: reviewedOpenURL)
    )
    let recovery = persistExternalEffectRecoveryBeforeLaunch(
        plan: plan,
        ordinal: 0,
        reservation: reservation,
        summary: "Opened the reviewed URL handoff",
        store: store
    )
    let launchSawPersistedRecovery = store.list().contains { $0.receiptID == recovery.receiptID }
    let executor = StructuredControlExecutor { _, _ in
        #expect(launchSawPersistedRecovery)
        return true
    }
    _ = try await executor.execute(reviewedOpenURL, isCurrent: { true })
    #expect(store.list() == [recovery])

    let generation = StructuredControlGeneration()
    let token = generation.begin()
    generation.invalidate()
    let cancelledExecutor = StructuredControlExecutor { _, _ in
        Issue.record("The structured executor must not launch after cancellation.")
        return true
    }
    await #expect(throws: StructuredControlError.cancelled) {
        _ = try await cancelledExecutor.execute(
            reviewedOpenURL,
            isCurrent: { generation.isCurrent(token) }
        )
    }
    #expect(store.list() == [recovery])
}

@Test("terminal retry cleanup uses the authoritative outcome and only removes that receipt")
func externalEffectRecoveryRetryCleanupUsesAuthoritativeStatus() throws {
    let defaults = try #require(UserDefaults(suiteName: "flowstate.external-effects.reconcile.\(UUID().uuidString)"))
    let store = ExternalEffectRecoveryStore(defaults: defaults)
    let first = recovery(
        planID: "plan-terminal-one",
        receiptID: "receipt-terminal-one",
        operationFingerprint: externalEffectOperationFingerprint(action: reviewedOpenURL)
    )
    let second = recovery(
        planID: "plan-terminal-two",
        receiptID: "receipt-terminal-two",
        operationFingerprint: externalEffectOperationFingerprint(action: reviewedOpenURL)
    )
    store.upsert(first)
    store.upsert(second)

    let requestedFirst = CloudSession.ExternalEffectOutcome.failed
    let authoritativeFirst = CloudSession.ExternalEffectOutcome.succeeded
    #expect(requestedFirst != authoritativeFirst)
    #expect(authoritativeFirst.isTerminal)
    store.remove(receiptID: first.receiptID)
    #expect(store.list() == [second])

    let requestedSecond = CloudSession.ExternalEffectOutcome.succeeded
    let authoritativeSecond = CloudSession.ExternalEffectOutcome.failed
    #expect(requestedSecond != authoritativeSecond)
    #expect(authoritativeSecond.isTerminal)
    store.remove(receiptID: second.receiptID)
    #expect(store.list().isEmpty)
}
