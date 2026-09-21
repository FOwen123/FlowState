import Foundation
import Testing
@testable import FlowStateCore

@Test("an open application action cannot launch outside its approved target")
func openApplicationPayloadMustMatchApprovedTarget() async throws {
    let driver = OpenApplicationRecordingDriver()
    let controller = DesktopAutomationController(driver: driver)
    let grant = DesktopExecutionGrant(
        allowedBundleIdentifiers: ["com.example.Reader"],
        allowedActions: [.openApplication],
        generation: 20,
        expiresAt: Date().addingTimeInterval(60)
    )
    try await controller.begin(grant: grant)

    await #expect(throws: DesktopExecutionError.actionNotGranted) {
        _ = try await controller.execute(
            .openApplication(bundleIdentifier: "com.example.Terminal"),
            expectedBundleIdentifier: "com.example.Reader"
        )
    }
    #expect(await driver.launchedBundleValue() == nil)
}

@Test("post-effect verification binds the focused element as well as the app")
func postVerificationMustKeepFocusedElement() async throws {
    let driver = FocusChangingDriver()
    let controller = DesktopAutomationController(driver: driver)
    let grant = DesktopExecutionGrant(
        allowedBundleIdentifiers: ["com.example.Editor"],
        allowedActions: [.press],
        generation: 21,
        expiresAt: Date().addingTimeInterval(60)
    )
    try await controller.begin(grant: grant)

    await #expect(throws: DesktopExecutionError.targetChanged) {
        _ = try await controller.execute(
            .press,
            expectedBundleIdentifier: "com.example.Editor"
        )
    }
    #expect(await driver.effectCountValue() == 1)
}

@Test("cloud execution rejects a changed focus snapshot before performing")
func expectedObservationBindsCloudDelay() async throws {
    let driver = FocusChangingDriver()
    let controller = DesktopAutomationController(driver: driver)
    let grant = DesktopExecutionGrant(
        allowedBundleIdentifiers: ["com.example.Editor"],
        allowedActions: [.press],
        generation: 22,
        expiresAt: Date().addingTimeInterval(60)
    )
    try await controller.begin(grant: grant)
    let expected = DesktopObservation(
        bundleIdentifier: "com.example.Editor",
        focusedElementID: "stale-control",
        focusedRole: "AXButton",
        focusedLabel: "Open",
        isEditable: false,
        isSecure: false
    )

    await #expect(throws: DesktopExecutionError.targetChanged) {
        _ = try await controller.execute(
            .press(key: "Tab", modifiers: nil),
            expectedBundleIdentifier: "com.example.Editor",
            expectedObservation: expected
        )
    }
    #expect(await driver.effectCountValue() == 0)
}

@Test("control execution rejects generic insertion before observing a target")
func expectedObservationBindsTextSelection() async throws {
    let driver = SelectionChangingDriver()
    let controller = DesktopAutomationController(driver: driver)
    let grant = DesktopExecutionGrant(
        allowedBundleIdentifiers: ["com.example.Editor"],
        allowedActions: [.insertText],
        generation: 23,
        expiresAt: Date().addingTimeInterval(60)
    )
    try await controller.begin(grant: grant)
    let expected = try await controller.observeCurrent()

    await #expect(throws: DesktopExecutionError.actionNotGranted) {
        _ = try await controller.execute(
            .insertText("safe text"),
            expectedBundleIdentifier: "com.example.Editor",
            expectedObservation: expected
        )
    }
    #expect(await driver.effectCountValue() == 0)
}

@Test("an attempted but unverified effect requires reconciliation before replay")
func unverifiedEffectBlocksReplayUntilNewGrant() async throws {
    let driver = OutcomeDriver(outcome: .unverified)
    let controller = DesktopAutomationController(driver: driver)
    try await controller.begin(grant: DesktopExecutionGrant(
        allowedBundleIdentifiers: ["com.example.Editor"],
        allowedActions: [.press],
        generation: 24,
        expiresAt: Date().addingTimeInterval(60)
    ))

    await #expect(throws: DesktopExecutionError.dispatchUncertain) {
        _ = try await controller.execute(.press, expectedBundleIdentifier: "com.example.Editor")
    }
    #expect(await controller.state == .reconciliationRequired)
    #expect(await driver.effectCountValue() == 1)

    await #expect(throws: DesktopExecutionError.reconciliationRequired) {
        _ = try await controller.execute(.press, expectedBundleIdentifier: "com.example.Editor")
    }
    await #expect(throws: DesktopExecutionError.reconciliationRequired) {
        _ = try await controller.observeCurrent()
    }
    await #expect(throws: DesktopExecutionError.reconciliationRequired) {
        _ = try await controller.resume()
    }

    await controller.cancel()
    #expect(await controller.state == .cancelled)
    try await controller.begin(grant: DesktopExecutionGrant(
        allowedBundleIdentifiers: ["com.example.Editor"],
        allowedActions: [.press],
        generation: 25,
        expiresAt: Date().addingTimeInterval(60)
    ))
    #expect(await controller.state == .ready)
}

@Test("a driver throw after dispatch requires reconciliation")
func thrownDispatchUncertaintyBlocksReplay() async throws {
    let driver = OutcomeDriver(outcome: .throwsAfterDispatch)
    let controller = DesktopAutomationController(driver: driver)
    try await controller.begin(grant: DesktopExecutionGrant(
        allowedBundleIdentifiers: ["com.example.Editor"],
        allowedActions: [.press],
        generation: 26,
        expiresAt: Date().addingTimeInterval(60)
    ))

    await #expect(throws: DesktopExecutionError.dispatchUncertain) {
        _ = try await controller.execute(.press, expectedBundleIdentifier: "com.example.Editor")
    }
    #expect(await controller.state == .reconciliationRequired)
    #expect(await driver.effectCountValue() == 1)
}

@Test("a verified effect with failed post-observation requires reconciliation")
func postVerificationFailureBlocksReplay() async throws {
    let driver = PostVerificationFailureDriver()
    let controller = DesktopAutomationController(driver: driver)
    try await controller.begin(grant: DesktopExecutionGrant(
        allowedBundleIdentifiers: ["com.example.Editor"],
        allowedActions: [.press],
        generation: 28,
        expiresAt: Date().addingTimeInterval(60)
    ))

    await #expect(throws: DesktopExecutionError.nativeFailure("post-dispatch observation failed")) {
        _ = try await controller.execute(.press, expectedBundleIdentifier: "com.example.Editor")
    }
    #expect(await controller.state == .reconciliationRequired)
    #expect(await driver.effectCountValue() == 1)
}

@Test("a validation failure before dispatch leaves the controller ready")
func validationFailureDoesNotRequireReconciliation() async throws {
    let driver = OutcomeDriver(outcome: .validationFailure)
    let controller = DesktopAutomationController(driver: driver)
    try await controller.begin(grant: DesktopExecutionGrant(
        allowedBundleIdentifiers: ["com.example.Editor"],
        allowedActions: [.press],
        generation: 27,
        expiresAt: Date().addingTimeInterval(60)
    ))

    await #expect(throws: DesktopExecutionError.verificationFailed) {
        _ = try await controller.execute(.press, expectedBundleIdentifier: "com.example.Editor")
    }
    #expect(await controller.state == .ready)
    #expect(await driver.effectCountValue() == 0)
}

private actor OpenApplicationRecordingDriver: DesktopDriver {
    private var launchedBundle: String?

    func observe() async throws -> DesktopObservation {
        DesktopObservation(bundleIdentifier: "com.example.Reader", focusedElementID: "reader")
    }

    func perform(
        _ action: DesktopAction,
        expectedObservation: DesktopObservation,
        authorize: @escaping @Sendable () async -> Bool
    ) async throws -> DesktopActionResult {
        guard await authorize() else { throw DesktopExecutionError.staleGeneration }
        if case let .openApplication(bundleIdentifier) = action {
            launchedBundle = bundleIdentifier
        }
        return DesktopActionResult(verified: true)
    }

    func restoreValue(
        _ value: String,
        expectedObservation: DesktopObservation,
        authorize: @escaping @Sendable () async -> Bool
    ) async throws {
        guard await authorize() else { throw DesktopExecutionError.staleGeneration }
    }

    func launchedBundleValue() -> String? { launchedBundle }
}

private actor FocusChangingDriver: DesktopDriver {
    private var observationCount = 0
    private var effectCount = 0

    func observe() async throws -> DesktopObservation {
        observationCount += 1
        let focusedElementID = observationCount == 1 ? "first-control" : "second-control"
        return DesktopObservation(bundleIdentifier: "com.example.Editor", focusedElementID: focusedElementID)
    }

    func perform(
        _ action: DesktopAction,
        expectedObservation: DesktopObservation,
        authorize: @escaping @Sendable () async -> Bool
    ) async throws -> DesktopActionResult {
        guard await authorize() else { throw DesktopExecutionError.staleGeneration }
        effectCount += 1
        return DesktopActionResult(verified: true)
    }

    func restoreValue(
        _ value: String,
        expectedObservation: DesktopObservation,
        authorize: @escaping @Sendable () async -> Bool
    ) async throws {
        guard await authorize() else { throw DesktopExecutionError.staleGeneration }
    }

    func effectCountValue() -> Int { effectCount }
}

private actor SelectionChangingDriver: DesktopDriver {
    private var observationCount = 0
    private var effectCount = 0

    func observe() async throws -> DesktopObservation {
        observationCount += 1
        return DesktopObservation(
            bundleIdentifier: "com.example.Editor",
            focusedElementID: "editor",
            focusedRole: "AXTextArea",
            isEditable: true,
            selectedTextRange: DesktopTextRange(location: observationCount == 1 ? 0 : 1, length: 0)
        )
    }

    func perform(
        _ action: DesktopAction,
        expectedObservation: DesktopObservation,
        authorize: @escaping @Sendable () async -> Bool
    ) async throws -> DesktopActionResult {
        guard await authorize() else { throw DesktopExecutionError.staleGeneration }
        effectCount += 1
        return DesktopActionResult(verified: true)
    }

    func restoreValue(
        _ value: String,
        expectedObservation: DesktopObservation,
        authorize: @escaping @Sendable () async -> Bool
    ) async throws {
        guard await authorize() else { throw DesktopExecutionError.staleGeneration }
    }

    func effectCountValue() -> Int { effectCount }
}

private actor OutcomeDriver: DesktopDriver {
    enum Outcome: Sendable {
        case unverified
        case throwsAfterDispatch
        case validationFailure
    }

    private let outcome: Outcome
    private var effectCount = 0

    init(outcome: Outcome) {
        self.outcome = outcome
    }

    func observe() async throws -> DesktopObservation {
        DesktopObservation(bundleIdentifier: "com.example.Editor", focusedElementID: "editor")
    }

    func perform(
        _ action: DesktopAction,
        expectedObservation: DesktopObservation,
        authorize: @escaping @Sendable () async -> Bool
    ) async throws -> DesktopActionResult {
        guard await authorize() else { throw DesktopExecutionError.staleGeneration }
        switch outcome {
        case .unverified:
            effectCount += 1
            return DesktopActionResult(verified: false, effectAttempted: true)
        case .throwsAfterDispatch:
            effectCount += 1
            throw DesktopExecutionError.dispatchUncertain
        case .validationFailure:
            return DesktopActionResult(verified: false)
        }
    }

    func restoreValue(
        _ value: String,
        expectedObservation: DesktopObservation,
        authorize: @escaping @Sendable () async -> Bool
    ) async throws {
        guard await authorize() else { throw DesktopExecutionError.staleGeneration }
    }

    func effectCountValue() -> Int { effectCount }
}

private actor PostVerificationFailureDriver: DesktopDriver {
    private var observationCount = 0
    private var effectCount = 0

    func observe() async throws -> DesktopObservation {
        observationCount += 1
        guard observationCount == 1 else {
            throw DesktopExecutionError.nativeFailure("post-dispatch observation failed")
        }
        return DesktopObservation(bundleIdentifier: "com.example.Editor", focusedElementID: "editor")
    }

    func perform(
        _ action: DesktopAction,
        expectedObservation: DesktopObservation,
        authorize: @escaping @Sendable () async -> Bool
    ) async throws -> DesktopActionResult {
        guard await authorize() else { throw DesktopExecutionError.staleGeneration }
        effectCount += 1
        return DesktopActionResult(verified: true)
    }

    func restoreValue(
        _ value: String,
        expectedObservation: DesktopObservation,
        authorize: @escaping @Sendable () async -> Bool
    ) async throws {
        guard await authorize() else { throw DesktopExecutionError.staleGeneration }
    }

    func effectCountValue() -> Int { effectCount }
}

@Test("late lifecycle mutations cannot cancel or pause a replacement grant")
func staleLifecycleMutationCannotInvalidateNewGrant() async throws {
    let controller = DesktopAutomationController(driver: OpenApplicationRecordingDriver())
    let grant = DesktopExecutionGrant(allowedBundleIdentifiers: ["com.example.Reader"], allowedActions: [.openApplication], generation: 30, expiresAt: Date().addingTimeInterval(60))
    try await controller.begin(grant: grant, lifecycleEpoch: 3)
    await controller.cancel(lifecycleEpoch: 2)
    #expect(await controller.state == .ready)
    await controller.notePhysicalTakeover(lifecycleEpoch: 1)
    #expect(await controller.state == .ready)
    await controller.cancel(lifecycleEpoch: 4)
    #expect(await controller.state == .cancelled)
}

@Test("secure role and secure subrole both prevent context exposure")
func secureRolesAreProtected() {
    #expect(AXDesktopDriver.isSecureTextField(role: "AXSecureTextField", subrole: nil))
    #expect(AXDesktopDriver.isSecureTextField(role: "AXTextField", subrole: "AXSecureTextField"))
    #expect(!AXDesktopDriver.isSecureTextField(role: "AXTextField", subrole: nil))
}

@Test("Tab may move focus within the approved app after its effect is verified")
func tabMayMoveApprovedFocus() async throws {
    let driver = FocusChangingDriver()
    let controller = DesktopAutomationController(driver: driver)
    try await controller.begin(grant: DesktopExecutionGrant(allowedBundleIdentifiers: ["com.example.Editor"],
        allowedActions: [.press], generation: 1, expiresAt: Date().addingTimeInterval(30)))
    _ = try await controller.execute(.press(key: "Tab", modifiers: nil), expectedBundleIdentifier: "com.example.Editor")
    #expect(await driver.effectCountValue() == 1)
}
