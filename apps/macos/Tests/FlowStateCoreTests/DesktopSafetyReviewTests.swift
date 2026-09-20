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
