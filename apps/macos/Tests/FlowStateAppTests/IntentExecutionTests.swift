import Foundation
import FlowStateCore
import Testing
@testable import FlowStateApp

private actor IntentFixtureDriver: DesktopDriver {
    var observation = DesktopObservation(bundleIdentifier: "com.example.Editor", focusedElementID: "field-1", value: "before")
    var inputs: [DesktopAction] = []
    func observe() -> DesktopObservation { observation }
    func moveFocus() { observation = DesktopObservation(bundleIdentifier: "com.example.Editor", focusedElementID: "field-2", value: "unrelated") }
    func perform(_ action: DesktopAction, expectedObservation: DesktopObservation, authorize: @escaping @Sendable () async -> Bool) async throws -> DesktopActionResult {
        guard await authorize() else { throw DesktopExecutionError.staleGeneration }
        inputs.append(action)
        if case .openApplication(let bundle) = action {
            observation = DesktopObservation(bundleIdentifier: bundle, focusedElementID: "new-window", value: "")
        }
        if case .insertText(let text) = action {
            observation = DesktopObservation(bundleIdentifier: observation.bundleIdentifier, focusedElementID: observation.focusedElementID, value: text)
            return DesktopActionResult(verified: true, valueBefore: expectedObservation.value, valueAfter: text)
        }
        return DesktopActionResult(verified: true)
    }
    func restoreValue(_ value: String, expectedObservation: DesktopObservation, authorize: @escaping @Sendable () async -> Bool) async throws {}
}

@Test("resolved dictation never follows focus changes during cloud inference")
@MainActor func resolvedDictationBindsOriginalFocus() async throws {
    let driver = IntentFixtureDriver()
    let model = FlowStateAppModel(desktopController: DesktopAutomationController(driver: driver))
    model.inputBundleIdentifier = "com.example.Editor"
    model.beginInputTask()
    for _ in 0..<100 { if model.currentInputGrant != nil { break }; try await Task.sleep(for: .milliseconds(2)) }
    let grant = try #require(model.currentInputGrant)
    let original = await driver.observe()
    await driver.moveFocus()
    let action = NativePlanAction(kind: .insertText, targetBundleIdentifier: "com.example.Editor", parameters: .insertText(text: "literal open Brave", replaceSelection: true), capability: "app.input", requiresApproval: false)
    await #expect(throws: (any Error).self) {
        try await model.executeResolvedIntent(action, observation: original, epoch: grant.generation)
    }
    #expect(await driver.inputs.isEmpty)
    model.cancelInputTask()
}

@Test("every supported resolved control reaches the same permission-bound executor", arguments: [
    NativePlanParameters.openApplication,
    .scroll(lines: -3), .scroll(lines: 3),
    .focus(role: "AXTextField", label: "Editor"),
    .select(label: "Editor"), .press(key: "Tab", modifiers: nil)
])
@MainActor func resolvedControlsUseSharedExecutor(parameters: NativePlanParameters) async throws {
    let driver = IntentFixtureDriver()
    let model = FlowStateAppModel(desktopController: DesktopAutomationController(driver: driver))
    model.inputBundleIdentifier = "com.example.Editor"
    model.beginInputTask()
    for _ in 0..<100 { if model.currentInputGrant != nil { break }; try await Task.sleep(for: .milliseconds(2)) }
    let grant = try #require(model.currentInputGrant)
    let kind: NativePlanActionKind
    switch parameters {
    case .openApplication: kind = .openApplication
    case .scroll: kind = .scroll
    case .focus: kind = .focus
    case .select: kind = .select
    case .press: kind = .press
    case .openURL, .attachFile, .sendEmail, .draftMessage:
        preconditionFailure("structured service actions are not native desktop controls")
    case .insertText: preconditionFailure("generic text is not a supported control parameter")
    }
    let capability = kind == .openApplication ? "app.open" : kind == .press ? "app.input" : "app.control"
    let action = NativePlanAction(kind: kind, targetBundleIdentifier: "com.example.Editor", parameters: parameters,
        capability: capability, requiresApproval: false)
    let desktopAction = try #require(action.desktopAction)
    try await model.executeResolvedIntent(action, observation: await driver.observe(), epoch: grant.generation)
    #expect(await driver.inputs == [desktopAction])
    model.cancelInputTask()
    await #expect(throws: (any Error).self) {
        try await model.executeResolvedIntent(action, observation: await driver.observe(), epoch: grant.generation)
    }
    #expect(await driver.inputs.count == 1)
}

@Test("only unresolved speech needs cloud interpretation; exact controls remain available offline")
@MainActor func exactCommandsDoNotDependOnCloudCalibration() {
    let model = FlowStateAppModel()
    model.useManagedCommands = true
    #expect(model.shouldInterpret(.unknown))
    for command in [VoiceCommand.openApp("com.brave.Browser"), .scroll(-3), .stop, .resume, .undo, .dictate("open Brave"), .press(key: "Tab", modifiers: nil)] {
        #expect(!model.shouldInterpret(command))
    }
    model.useManagedCommands = false
    #expect(!model.shouldInterpret(.unknown))
}

@Test("screen fallback needs a current matching task and separate upload consent")
@MainActor func screenFallbackRequiresMatchingConsent() async throws {
    let model = FlowStateAppModel()
    model.bundleIdentifier = "com.example.Editor"
    model.beginTask()
    for _ in 0..<100 { if model.isTaskActive { break }; try await Task.sleep(for: .milliseconds(2)) }
    #expect(model.captureGrantForCloud(bundleIdentifier: "com.example.Editor") == nil)
    model.allowCloudScreenContext = true
    #expect(model.captureGrantForCloud(bundleIdentifier: "com.example.Other") == nil)
    #expect(model.captureGrantForCloud(bundleIdentifier: "com.example.Editor") != nil)
    model.revokeTask()
    #expect(model.captureGrantForCloud(bundleIdentifier: "com.example.Editor") == nil)
}

@Test("review-required actions cannot bypass confirmation at the app executor")
@MainActor func requiredReviewIsEnforcedAtExecution() async throws {
    let driver = IntentFixtureDriver()
    let model = FlowStateAppModel(desktopController: DesktopAutomationController(driver: driver))
    model.inputBundleIdentifier = "com.example.Editor"
    model.beginInputTask()
    for _ in 0..<100 { if model.currentInputGrant != nil { break }; try await Task.sleep(for: .milliseconds(2)) }
    let grant = try #require(model.currentInputGrant)
    let observation = await driver.observe()
    let action = NativePlanAction(kind: .press, targetBundleIdentifier: observation.bundleIdentifier,
        parameters: .press(key: "Enter", modifiers: nil), capability: "app.input", requiresApproval: true)
    await #expect(throws: (any Error).self) {
        try await model.executeResolvedIntent(action, observation: observation, epoch: grant.generation)
    }
    #expect(await driver.inputs.isEmpty)
    try await model.executeResolvedIntent(action, observation: observation, epoch: grant.generation, approved: true)
    #expect(await driver.inputs.count == 1)
    model.cancelInputTask()
}

@Test("compound plans auto-run only the reversible prefix")
@MainActor func compoundPlanAutoRunStopsAtApprovalStep() {
    let reversible = NativePlanAction(
        kind: .scroll,
        targetBundleIdentifier: "com.example.Editor",
        parameters: .scroll(lines: -2),
        capability: "app.control",
        requiresApproval: false,
        risk: .reversible
    )
    let consequential = NativePlanAction(
        kind: .press,
        targetBundleIdentifier: "com.example.Editor",
        parameters: .press(key: "Enter", modifiers: nil),
        capability: "app.input",
        requiresApproval: true,
        risk: .confirm
    )
    let trailing = NativePlanAction(
        kind: .scroll,
        targetBundleIdentifier: "com.example.Editor",
        parameters: .scroll(lines: 2),
        capability: "app.control",
        requiresApproval: false,
        risk: .reversible
    )

    #expect(automaticPlanPrefixCount([reversible, consequential, trailing]) == 1)
    #expect(automaticPlanPrefixCount([consequential, trailing]) == 0)
    #expect(consequential.requiresApproval)
}

@Test("physical input continues while each next action is revalidated")
@MainActor func physicalInputDoesNotPauseControl() async throws {
    let driver = IntentFixtureDriver()
    let model = FlowStateAppModel(desktopController: DesktopAutomationController(driver: driver))
    model.inputBundleIdentifier = "com.example.Editor"
    model.beginInputTask()
    for _ in 0..<100 { if model.currentInputGrant != nil { break }; try await Task.sleep(for: .milliseconds(2)) }
    let grant = try #require(model.currentInputGrant)
    model.handlePhysicalTakeover(for: grant.generation)
    #expect(model.desktopState == .ready)
    model.executeDesktopAction(.scroll(lines: 3))
    for _ in 0..<100 { if await !driver.inputs.isEmpty { break }; try await Task.sleep(for: .milliseconds(2)) }
    #expect(await driver.inputs == [.scroll(lines: 3)])
    model.cancelInputTask()
}

@Test("a verified app launch binds following plan controls to the newly opened app")
@MainActor func planLaunchRefreshesTarget() async throws {
    let driver = IntentFixtureDriver()
    let model = FlowStateAppModel(desktopController: DesktopAutomationController(driver: driver))
    model.inputBundleIdentifier = "com.example.Reader"
    model.beginInputTask()
    for _ in 0..<100 { if model.currentInputGrant != nil { break }; try await Task.sleep(for: .milliseconds(2)) }
    _ = try #require(model.currentInputGrant)
    let launch = NativePlanAction(kind: .openApplication, targetBundleIdentifier: "com.example.Reader", parameters: .openApplication, capability: "app.open", requiresApproval: false)
    let (_, next) = try await model.executePlanStep(launch, expectedObservation: await driver.observe())
    #expect(next.bundleIdentifier == "com.example.Reader")
    let scroll = NativePlanAction(kind: .scroll, targetBundleIdentifier: "com.example.Reader", parameters: .scroll(lines: 3), capability: "app.control", requiresApproval: false)
    _ = try await model.executePlanStep(scroll, expectedObservation: next)
    #expect(await driver.inputs.count == 2)
    model.cancelInputTask()
}
