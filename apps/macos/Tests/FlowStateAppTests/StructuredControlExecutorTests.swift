import Foundation
import FlowStateCore
import Testing
@testable import FlowStateApp

private actor OpenedURLStore {
    var values: [(URL, String?)] = []

    func append(_ value: (URL, String?)) {
        values.append(value)
    }

    func snapshot() -> [(URL, String?)] { values }
}

@Test("the bounded Brave plan opens its page and prepares a Gmail draft")
func boundedBraveProjectPlanUsesOnlyStructuredHandoffs() async throws {
    let launch = NativePlanAction(
        kind: .openApplication,
        targetBundleIdentifier: "com.brave.Browser",
        parameters: .openApplication,
        capability: "app.open",
        requiresApproval: false
    )
    let actions = [
        NativePlanAction(
            kind: .openURL,
            targetBundleIdentifier: "com.brave.Browser",
            parameters: .openURL(url: "https://example.com/project"),
            capability: "app.control",
            executor: "service",
            requiresApproval: false,
            route: .structuredIntegration,
            risk: .reversible
        ),
        NativePlanAction(
            kind: .draftMessage,
            targetBundleIdentifier: "com.brave.Browser",
            parameters: .draftMessage(
                recipient: "person@example.com",
                subject: "Project page",
                body: "Here is the project page: https://example.com/project"
            ),
            capability: "mail.draft",
            executor: "service",
            requiresApproval: true,
            route: .structuredIntegration,
            risk: .confirm
        )
    ]
    #expect(launch.desktopAction == .openApplication(bundleIdentifier: "com.brave.Browser"))
    let opened = OpenedURLStore()
    let executor = StructuredControlExecutor { url, bundleIdentifier in
        await opened.append((url, bundleIdentifier))
        return true
    }

    for action in actions {
        _ = try await executor.execute(action, isCurrent: { true })
    }

    let values = await opened.snapshot()
    #expect(values.count == 2)
    #expect(values[0].0.absoluteString == "https://example.com/project")
    #expect(values[0].1 == "com.brave.Browser")
    #expect(values[1].0.host == "mail.google.com")
    #expect(values[1].1 == "com.brave.Browser")
    #expect(values[1].0.absoluteString.contains("Project%20page"))
    let body = try #require(URLComponents(url: values[1].0, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "body" }?.value)
    #expect(body.contains("https://example.com/project"))
}

@Test("structured handoff cancellation is checked after the opener returns")
func structuredHandoffRejectsLateGeneration() async throws {
    let state = CancellationState()
    let executor = StructuredControlExecutor { _, _ in
        state.cancel()
        return true
    }
    let action = NativePlanAction(
        kind: .openURL,
        targetBundleIdentifier: "com.brave.Browser",
        parameters: .openURL(url: "https://example.com/project"),
        capability: "app.control",
        executor: "service",
        requiresApproval: false,
        route: .structuredIntegration,
        risk: .reversible
    )

    await #expect(throws: StructuredControlError.cancelled) {
        _ = try await executor.execute(action, isCurrent: { state.isCurrent })
    }
}

@Test("structured handoff requires a concrete browser target")
func structuredHandoffRequiresConcreteTarget() async {
    let executor = StructuredControlExecutor { _, _ in true }
    let action = NativePlanAction(
        kind: .draftMessage,
        parameters: .draftMessage(recipient: "person@example.com", subject: "Project", body: "See the page."),
        capability: "mail.draft",
        executor: "service",
        requiresApproval: true,
        route: .structuredIntegration,
        risk: .confirm
    )

    await #expect(throws: StructuredControlError.invalidTarget) {
        _ = try await executor.execute(action, isCurrent: { true })
    }
}

@Test("structured handoff rejects a changed post-launch browser")
func structuredHandoffRejectsWrongPostBrowser() async {
    let executor = StructuredControlExecutor(
        launcher: { _, _ in true },
        verifier: { _, _ in false }
    )
    let action = NativePlanAction(
        kind: .openURL,
        targetBundleIdentifier: "com.brave.Browser",
        parameters: .openURL(url: "https://example.com/project"),
        capability: "app.control",
        executor: "service",
        requiresApproval: false,
        route: .structuredIntegration,
        risk: .reversible
    )

    await #expect(throws: StructuredControlError.postHandoffTargetMismatch) {
        _ = try await executor.execute(action, isCurrent: { true })
    }
}

@Test("structured target matching fails closed when focus changes")
func structuredTargetMatchingFailsClosed() {
    #expect(StructuredControlExecutor.targetMatches(expected: "com.brave.Browser", observed: "com.brave.Browser"))
    #expect(!StructuredControlExecutor.targetMatches(expected: "com.brave.Browser", observed: "com.apple.Safari"))
    #expect(!StructuredControlExecutor.targetMatches(expected: "com.brave.Browser", observed: nil))
}

@Test("uncertain handoff recovery blocks the same redacted operation after cancellation")
func uncertainHandoffRecoveryBlocksReplayWithoutPrivateParameters() {
    let action = NativePlanAction(
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
    let recovery = ExternalEffectRecovery(
        planID: "old-plan",
        ordinal: 0,
        receiptID: "receipt-1",
        summary: "Opened the reviewed URL handoff",
        operationFingerprint: externalEffectOperationFingerprint(action: action)
    )

    #expect(externalEffectRecoveryBlocks(recovery, operationFingerprint: externalEffectOperationFingerprint(action: action)))
    #expect(!externalEffectRecoveryBlocks(recovery, operationFingerprint: externalEffectOperationFingerprint(action: NativePlanAction(
        kind: .openURL,
        targetBundleIdentifier: "com.brave.Browser",
        parameters: .openURL(url: "https://private.example/other"),
        capability: "app.control",
        executor: "service",
        requiresApproval: false,
        route: .structuredIntegration,
        verifier: NativePlanVerifier(kind: .externalEffectReconciled),
        risk: .reversible
    ))))
    #expect(!recovery.summary.contains("private.example"))
    #expect(!recovery.summary.contains("token"))
}

@Test("structured handoff rechecks the expected pre-state before opening the target")
func structuredHandoffRechecksPreStateAndVerifiesBrave() async throws {
    let expected = DesktopObservation(
        bundleIdentifier: "com.apple.TextEdit",
        focusedElementID: "field-1",
        focusedRole: "AXTextArea"
    )
    let unchanged = DesktopObservation(
        bundleIdentifier: "com.apple.TextEdit",
        focusedElementID: "field-1",
        focusedRole: "AXTextArea"
    )
    let diverged = DesktopObservation(bundleIdentifier: "com.apple.Safari", focusedElementID: "field-1")
    #expect(structuredControlPreconditionMatches(unchanged, expected: expected))
    #expect(!structuredControlPreconditionMatches(diverged, expected: expected))

    let observed = LockedString("com.apple.TextEdit")
    let executor = StructuredControlExecutor(
        launcher: { _, _ in
            observed.set("com.brave.Browser")
            return true
        },
        verifier: { target, _ in observed.value == target }
    )
    let action = NativePlanAction(
        kind: .openURL,
        targetBundleIdentifier: "com.brave.Browser",
        parameters: .openURL(url: "https://example.com/project"),
        capability: "app.control",
        executor: "service",
        requiresApproval: false,
        route: .structuredIntegration,
        risk: .reversible
    )

    let result = try await executor.execute(action, isCurrent: { true })
    #expect(result.targetBundleIdentifier == "com.brave.Browser")
    #expect(observed.value == "com.brave.Browser")
}

@Test("structured plan cancellation prevents the next handoff")
func structuredPlanCancellationBetweenSteps() async throws {
    let generation = StructuredControlGeneration()
    let token = generation.begin()
    let state = OpenedURLStore()
    let executor = StructuredControlExecutor { url, target in
        await state.append((url, target))
        generation.invalidate()
        return true
    }
    let actions = [
        NativePlanAction(
            kind: .openURL,
            targetBundleIdentifier: "com.brave.Browser",
            parameters: .openURL(url: "https://example.com/project"),
            capability: "app.control",
            executor: "service",
            requiresApproval: false,
            route: .structuredIntegration,
            risk: .reversible
        ),
        NativePlanAction(
            kind: .draftMessage,
            targetBundleIdentifier: "com.brave.Browser",
            parameters: .draftMessage(recipient: "person@example.com", subject: "Project", body: "See the page."),
            capability: "mail.draft",
            executor: "service",
            requiresApproval: true,
            route: .structuredIntegration,
            risk: .confirm
        )
    ]

    do {
        _ = try await executor.execute(actions[0], isCurrent: { generation.isCurrent(token) })
    } catch StructuredControlError.cancelled {
        // The first handoff completed, but its late callback is not allowed
        // to authorize a second step.
    }
    await #expect(throws: StructuredControlError.cancelled) {
        _ = try await executor.execute(actions[1], isCurrent: { generation.isCurrent(token) })
    }
    #expect(await state.snapshot().count == 1)
}

private final class CancellationState: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCurrent: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !cancelled
    }
}

private final class LockedString: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String

    init(_ stored: String) { self.stored = stored }

    var value: String {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ value: String) {
        lock.lock()
        stored = value
        lock.unlock()
    }
}

@Test("unsupported service and visual routes fail closed")
func unsupportedStructuredRoutesFailClosed() async {
    let executor = StructuredControlExecutor { _, _ in true }
    let actions = [
        NativePlanAction(
            kind: .attachFile,
            parameters: .attachFile(fileID: "file-1"),
            capability: "file.upload",
            executor: "service",
            requiresApproval: true,
            route: .structuredIntegration,
            risk: .confirm
        ),
        NativePlanAction(
            kind: .sendEmail,
            parameters: .sendEmail(recipient: "person@example.com", subject: "Subject", body: "Body"),
            capability: "mail.send",
            executor: "service",
            requiresApproval: true,
            route: .structuredIntegration,
            risk: .confirm
        ),
        NativePlanAction(
            kind: .openURL,
            parameters: .openURL(url: "https://example.com"),
            capability: "app.control",
            executor: "desktop",
            requiresApproval: true,
            visualTarget: .object(["windowId": .string("window")]),
            route: .visualComputerUse,
            risk: .confirm
        )
    ]

    for action in actions {
        await #expect(throws: StructuredControlError.unsupportedAction) {
            _ = try await executor.execute(action, isCurrent: { true })
        }
    }
}
