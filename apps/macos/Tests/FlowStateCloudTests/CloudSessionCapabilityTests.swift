import Foundation
import Testing
import FlowStateCore
@testable import FlowStateCloud

@Test("execution grants use validated plan capabilities")
func executionGrantsUseValidatedPlanCapabilities() {
    let press = NativePlanAction(
        kind: .press,
        targetBundleIdentifier: "com.example.Editor",
        parameters: .press(key: "A", modifiers: "Command"),
        capability: "app.input",
        requiresApproval: true
    )
    let open = NativePlanAction(
        kind: .openApplication,
        targetBundleIdentifier: "com.example.Editor",
        parameters: .openApplication,
        capability: "app.open",
        requiresApproval: true
    )

    #expect(cloudExecutionCapabilities(for: [press, open]) == ["app.input", "app.open"])
}

@Test("structured native support is limited to verified service handoffs")
func structuredNativeSupportIsFailClosed() {
    let open = NativePlanAction(
        kind: .openURL,
        targetBundleIdentifier: "com.brave.Browser",
        parameters: .openURL(url: "https://example.com"),
        capability: "app.control",
        executor: "service",
        requiresApproval: false,
        route: .structuredIntegration,
        verifier: NativePlanVerifier(kind: .externalEffectReconciled)
    )
    let draft = NativePlanAction(
        kind: .draftMessage,
        targetBundleIdentifier: "com.brave.Browser",
        parameters: .draftMessage(recipient: "person@example.com", subject: "Project", body: "See the page."),
        capability: "mail.draft",
        executor: "service",
        requiresApproval: true,
        route: .structuredIntegration,
        verifier: NativePlanVerifier(kind: .externalEffectReconciled),
        risk: .confirm
    )
    let attach = NativePlanAction(
        kind: .attachFile,
        parameters: .attachFile(fileID: "file-1"),
        capability: "file.upload",
        executor: "service",
        requiresApproval: true,
        route: .structuredIntegration,
        verifier: NativePlanVerifier(kind: .externalEffectReconciled),
        risk: .confirm
    )
    let visual = NativePlanAction(
        kind: .openURL,
        parameters: .openURL(url: "https://example.com"),
        capability: "app.control",
        executor: "service",
        requiresApproval: true,
        visualTarget: .object(["windowId": .string("window")]),
        route: .visualComputerUse,
        verifier: NativePlanVerifier(kind: .visualObservation),
        risk: .confirm
    )

    #expect(isSupportedNativePlanAction(open))
    #expect(isSupportedNativePlanAction(draft))
    #expect(!isSupportedNativePlanAction(attach))
    #expect(!isSupportedNativePlanAction(visual))
}

@Test("visual support accepts only a bound desktop click")
func visualSupportRequiresBoundDesktopClick() {
    let visual = NativePlanAction(
        kind: .click,
        targetBundleIdentifier: "com.example.Canvas",
        parameters: .click(label: "Visible control"),
        capability: "app.control",
        requiresApproval: true,
        visualTarget: .object([
            "observationId": .string("00000000-0000-0000-0000-000000000042"),
            "displayId": .string("7"),
            "windowId": .string("42"),
            "x": .number(0.1),
            "y": .number(0.2),
            "width": .number(0.3),
            "height": .number(0.2),
            "observedAt": .number(1_800_000_000_000),
        ]),
        route: .visualComputerUse,
        risk: .confirm
    )

    #expect(isSupportedNativePlanAction(visual))
}

@Test("structured draft support rejects an unapproved reversible draft")
func structuredDraftRequiresCanonicalApproval() {
    let draft = NativePlanAction(
        kind: .draftMessage,
        targetBundleIdentifier: "com.brave.Browser",
        parameters: .draftMessage(recipient: "person@example.com", subject: "Project", body: "See the page."),
        capability: "mail.draft",
        executor: "service",
        requiresApproval: false,
        route: .structuredIntegration,
        verifier: NativePlanVerifier(kind: .externalEffectReconciled),
        risk: .reversible
    )

    #expect(!isSupportedNativePlanAction(draft))
}

@Test("external effect retries retain reconcile receipts instead of replaying")
func externalEffectRetriesRequireReceiptReconciliation() {
    let pending = externalEffectResolution(status: "pending", receiptID: "receipt-1")
    let succeeded = externalEffectResolution(status: "succeeded", receiptID: "receipt-1")
    let reconcile = externalEffectResolution(status: "reconcile", receiptID: "receipt-1")
    let uncertain = externalEffectResolution(status: "uncertain", receiptID: "receipt-1")
    #expect(pending == .pending(receiptID: "receipt-1"))
    #expect(succeeded == .alreadySucceeded(receiptID: "receipt-1"))
    #expect(reconcile == .needsReconciliation(receiptID: "receipt-1"))
    #expect(uncertain == .needsReconciliation(receiptID: "receipt-1"))
    #expect(pending.allowsLaunch)
    #expect(!succeeded.allowsLaunch)
    #expect(!reconcile.allowsLaunch)
    #expect(!uncertain.allowsLaunch)
    #expect(externalEffectResolution(status: "failed", receiptID: "receipt-1") == .invalid)
}

@Test("authoritative reconciliation status overrides the requested choice")
func authoritativeExternalEffectOutcomeIsTerminalAndTyped() throws {
    let succeeded = try JSONDecoder().decode(
        ExternalEffectReconcileResponse.self,
        from: Data("{\"status\":\"succeeded\",\"receiptId\":\"receipt-1\"}".utf8)
    )
    let failed = try JSONDecoder().decode(
        ExternalEffectReconcileResponse.self,
        from: Data("{\"status\":\"failed\",\"receiptId\":\"receipt-2\"}".utf8)
    )
    let requested = CloudSession.ExternalEffectOutcome.failed
    let actual = try #require(CloudSession.ExternalEffectOutcome(rawValue: succeeded.status))
    #expect(actual == .succeeded)
    #expect(actual != requested)
    #expect(actual.isTerminal)
    #expect(CloudSession.ExternalEffectOutcome(rawValue: failed.status) == .failed)
    #expect(!CloudSession.ExternalEffectOutcome.uncertain.isTerminal)
    #expect(CloudSession.ExternalEffectOutcome(rawValue: "unexpected") == nil)
}

@Test("external effect request fingerprints use only the canonical structured action")
func externalEffectRequestFingerprintIsRedacted() {
    let firstAction = NativePlanAction(
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
    let sameActionInAnotherPlan = NativePlanAction(
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
    let firstDraft = NativePlanAction(
        kind: .draftMessage,
        targetBundleIdentifier: "com.brave.Browser",
        parameters: .draftMessage(
            recipient: "owner@example.com",
            subject: "Project",
            body: "quarterly results are private"
        ),
        capability: "mail.draft",
        executor: "service",
        requiresApproval: true,
        route: .structuredIntegration,
        verifier: NativePlanVerifier(kind: .externalEffectReconciled),
        risk: .confirm
    )
    let changedDraft = NativePlanAction(
        kind: .draftMessage,
        targetBundleIdentifier: "com.brave.Browser",
        parameters: .draftMessage(
            recipient: "owner@example.com",
            subject: "Project",
            body: "quarterly results are public"
        ),
        capability: "mail.draft",
        executor: "service",
        requiresApproval: true,
        route: .structuredIntegration,
        verifier: NativePlanVerifier(kind: .externalEffectReconciled),
        risk: .confirm
    )
    let first = externalEffectRequestFingerprint(action: firstAction)
    let second = externalEffectRequestFingerprint(action: sameActionInAnotherPlan)
    let different = externalEffectRequestFingerprint(action: differentURL)
    let firstDraftFingerprint = externalEffectRequestFingerprint(action: firstDraft)
    let changedDraftFingerprint = externalEffectRequestFingerprint(action: changedDraft)
    let surroundingStep = NativePlanAction(
        kind: .openApplication,
        targetBundleIdentifier: "com.apple.Finder",
        parameters: .openApplication,
        capability: "app.open",
        requiresApproval: false
    )
    let firstPlan = CloudProposal(
        id: "plan-a",
        fingerprint: "plan-fingerprint-a",
        actions: [firstAction],
        expiresAt: 2_000_000_000_000,
        generation: 1
    )
    let secondPlan = CloudProposal(
        id: "plan-b",
        fingerprint: "plan-fingerprint-b",
        actions: [surroundingStep, sameActionInAnotherPlan],
        expiresAt: 2_000_000_000_000,
        generation: 2
    )

    #expect(first == second)
    #expect(first != different)
    #expect(first.count == 64)
    #expect(!first.contains("private.example"))
    #expect(!first.contains("token=secret"))
    #expect(firstDraftFingerprint != changedDraftFingerprint)
    #expect(!firstDraftFingerprint.contains("owner@example.com"))
    #expect(!firstDraftFingerprint.contains("quarterly results are private"))
    #expect(externalEffectRequestFingerprint(action: firstPlan.actions[0]) == externalEffectRequestFingerprint(action: secondPlan.actions[1]))
}

@Test("managed dictation cleanup uses the text-only Convex action contract")
func managedDictationCleanupRequestContract() {
    let request = DictationCleanupRequest(
        transcript: "um hello comma",
        cleanupInstructions: "Keep product names unchanged",
        enabled: true
    )
    #expect(DictationCleanupRequest.actionName == "dictation:clean")
    #expect(request.transcript == "um hello comma")
    #expect(request.cleanupInstructions == "Keep product names unchanged")
    #expect(request.enabled)
}
