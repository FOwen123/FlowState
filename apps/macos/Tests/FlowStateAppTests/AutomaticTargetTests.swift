import Foundation
import FlowStateCore
import Testing
@testable import FlowStateApp

private actor AutomaticTargetDriver: DesktopDriver {
    var active = "com.example.Editor"
    var inputs: [DesktopAction] = []
    func observe() -> DesktopObservation { DesktopObservation(bundleIdentifier: active, focusedElementID: "field", value: "", focusedRole: "AXTextField", isEditable: true) }
    func perform(_ action: DesktopAction, expectedObservation: DesktopObservation, authorize: @escaping @Sendable () async -> Bool) async throws -> DesktopActionResult {
        guard await authorize() else { throw DesktopExecutionError.staleGeneration }
        inputs.append(action)
        if case .openApplication(let bundle) = action { active = bundle }
        return DesktopActionResult(verified: true)
    }
    func restoreValue(_ value: String, expectedObservation: DesktopObservation, authorize: @escaping @Sendable () async -> Bool) async throws {}
}

@Test("Accessibility access automatically targets the active app without a user grant", arguments: [
    VoiceCommand.scroll(-3), .scroll(3), .dictate("literal"), .focus(role: "AXTextField", label: nil), .select(label: "Editor"), .press(key: "Tab", modifiers: nil), .unknown
])
@MainActor func automaticActiveTarget(command: VoiceCommand) async throws {
    let model = FlowStateAppModel(desktopController: DesktopAutomationController(driver: AutomaticTargetDriver()), accessibilityGranted: { true })
    let observation = try await model.prepareAutomaticTarget(for: command, activeBundleIdentifier: "com.example.Editor")
    #expect(model.inputBundleIdentifier == "com.example.Editor")
    #expect(model.currentInputGrant?.allowedBundleIdentifiers == ["com.example.Editor"])
    #expect(observation?.bundleIdentifier == "com.example.Editor")
    model.cancelInputTask()
}

@Test("an explicit app command targets the named app instead of the foreground app")
@MainActor func automaticNamedTarget() async throws {
    let driver = AutomaticTargetDriver()
    let model = FlowStateAppModel(desktopController: DesktopAutomationController(driver: driver), accessibilityGranted: { true })
    let observation = try await model.prepareAutomaticTarget(for: .openApp("com.brave.Browser"), activeBundleIdentifier: "com.example.Editor")
    #expect(observation == nil)
    #expect(model.inputBundleIdentifier == "com.brave.Browser")
    model.executeDesktopAction(.openApplication(bundleIdentifier: "com.brave.Browser"))
    try await Task.sleep(for: .milliseconds(20))
    #expect(await driver.inputs == [.openApplication(bundleIdentifier: "com.brave.Browser")])
    model.cancelInputTask()
}

@Test("missing Accessibility permission never creates an automatic grant")
@MainActor func automaticTargetRequiresOSPermission() async {
    let model = FlowStateAppModel(desktopController: DesktopAutomationController(driver: AutomaticTargetDriver()), accessibilityGranted: { false })
    await #expect(throws: (any Error).self) {
        try await model.prepareAutomaticTarget(for: .scroll(3), activeBundleIdentifier: "com.example.Editor")
    }
    #expect(model.currentInputGrant == nil)
}

@Test("a new spoken command rearms a paused task without a settings grant")
@MainActor func automaticCommandAfterTakeover() async throws {
    let model = FlowStateAppModel(desktopController: DesktopAutomationController(driver: AutomaticTargetDriver()), accessibilityGranted: { true })
    _ = try await model.prepareAutomaticTarget(for: .scroll(3), activeBundleIdentifier: "com.example.Editor")
    let first = try #require(model.currentInputGrant)
    model.handlePhysicalTakeover(for: first.generation)
    try await Task.sleep(for: .milliseconds(10))
    _ = try await model.prepareAutomaticTarget(for: .scroll(-3), activeBundleIdentifier: "com.example.Editor")
    #expect(model.desktopState == .ready)
    #expect(model.currentInputGrant?.generation != first.generation)
    model.cancelInputTask()
}

@Test("automatic targeting honors disabled controls")
@MainActor func automaticTargetHonorsControlSettings() async throws {
    let driver = AutomaticTargetDriver()
    let model = FlowStateAppModel(desktopController: DesktopAutomationController(driver: driver), accessibilityGranted: { true })
    _ = try await model.prepareAutomaticTarget(for: .scroll(3), activeBundleIdentifier: "com.example.Editor")
    model.setInputAction(.scroll, enabled: false)
    _ = try await model.prepareAutomaticTarget(for: .scroll(3), activeBundleIdentifier: "com.example.Editor")
    model.executeDesktopAction(.scroll(lines: 3))
    try await Task.sleep(for: .milliseconds(20))
    #expect(await driver.inputs.isEmpty)
    model.cancelInputTask()
}

@Test("final speech reaches app controls with no manual app selection", arguments: [
    ("Open Brave.", DesktopAction.openApplication(bundleIdentifier: "com.brave.Browser")),
    ("Scroll down.", .scroll(lines: -3)),
    ("Scroll up.", .scroll(lines: 3))
])
@MainActor func automaticSpeechPipeline(transcript: String, expected: DesktopAction) async throws {
    let driver = AutomaticTargetDriver()
    let coordinator = SpeechSessionCoordinator()
    await coordinator.pushToTalkDown()
    let model = FlowStateAppModel(desktopController: DesktopAutomationController(driver: driver), accessibilityGranted: { true }, frontmostApplication: { "com.example.Editor" }, speechCoordinator: coordinator)
    model.speechSettings.mode = .command
    model.consume(SpeechRecognitionResult(transcript: transcript, language: .english, isFinal: true, utteranceID: UUID(), sessionEnded: false), token: 0)
    for _ in 0..<100 { if await !driver.inputs.isEmpty { break }; try await Task.sleep(for: .milliseconds(5)) }
    #expect(await driver.inputs == [expected])
    model.cancelInputTask()
}

@Test("Stop invalidates a finalized command before automatic setup can begin")
@MainActor func automaticSpeechCancelledBeforeSetup() async throws {
    let driver = AutomaticTargetDriver()
    let coordinator = SpeechSessionCoordinator()
    await coordinator.pushToTalkDown()
    let model = FlowStateAppModel(desktopController: DesktopAutomationController(driver: driver), accessibilityGranted: { true }, frontmostApplication: { "com.example.Editor" }, speechCoordinator: coordinator)
    model.consume(SpeechRecognitionResult(transcript: "Open Brave", language: .english, isFinal: true, utteranceID: UUID()), token: 0)
    model.stopVoiceSession()
    try await Task.sleep(for: .milliseconds(20))
    #expect(model.currentInputGrant == nil)
    #expect(await driver.inputs.isEmpty)
}

@Test("global control preferences persist independently of app targets")
@MainActor func automaticControlPreferencesPersist() throws {
    let suite = "FlowState.AutomaticTargetTests." + UUID().uuidString
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let model = FlowStateAppModel(preferences: preferences)
    model.allowCloudScreenContext = true
    model.setInputAction(.press, enabled: false)
    let reopened = FlowStateAppModel(preferences: preferences)
    #expect(reopened.allowCloudScreenContext)
    #expect(!reopened.allowedInputActions.contains(.press))
    #expect(reopened.inputBundleIdentifier.isEmpty)
}

@Test("wake activation needs no target app or Accessibility grant")
@MainActor func automaticWakeDoesNotRequireTarget() async throws {
    var settings = SpeechSettings()
    settings.activation = .wakePhrase
    let coordinator = SpeechSessionCoordinator(settings: settings)
    let model = FlowStateAppModel(accessibilityGranted: { false }, frontmostApplication: { nil }, speechCoordinator: coordinator)
    model.speechSettings = settings
    model.consume(SpeechRecognitionResult(transcript: settings.wakePhrase, language: .english, isFinal: true, utteranceID: UUID(), sessionEnded: false), token: 0)
    for _ in 0..<100 { if await coordinator.phase == .listening { break }; try await Task.sleep(for: .milliseconds(2)) }
    #expect(await coordinator.phase == .listening)
    #expect(model.currentInputGrant == nil)
}

@Test("background speech before the wake phrase does not prepare app control")
@MainActor func automaticWakeIgnoresBackgroundSpeech() async throws {
    var settings = SpeechSettings()
    settings.activation = .wakePhrase
    let coordinator = SpeechSessionCoordinator(settings: settings)
    let model = FlowStateAppModel(desktopController: DesktopAutomationController(driver: AutomaticTargetDriver()), accessibilityGranted: { true }, frontmostApplication: { "com.example.Editor" }, speechCoordinator: coordinator)
    model.speechSettings = settings
    model.consume(SpeechRecognitionResult(transcript: "Hello there", language: .english, isFinal: true, utteranceID: UUID(), sessionEnded: false), token: 0)
    try await Task.sleep(for: .milliseconds(30))
    #expect(await coordinator.phase == .idle)
    #expect(model.currentInputGrant == nil)
}

@Test("a newer finalized utterance supersedes queued automatic setup")
@MainActor func automaticNewestUtteranceWins() async throws {
    let driver = AutomaticTargetDriver()
    let coordinator = SpeechSessionCoordinator()
    await coordinator.pushToTalkDown()
    var permissionChecks = 0
    let model = FlowStateAppModel(desktopController: DesktopAutomationController(driver: driver), accessibilityGranted: { permissionChecks += 1; return true }, frontmostApplication: { "com.example.Editor" }, speechCoordinator: coordinator)
    for transcript in ["Open Brave", "Scroll down"] {
        model.consume(SpeechRecognitionResult(transcript: transcript, language: .english, isFinal: true, utteranceID: UUID(), sessionEnded: false), token: 0)
    }
    for _ in 0..<200 { if await !driver.inputs.isEmpty { break }; try await Task.sleep(for: .milliseconds(5)) }
    #expect(permissionChecks == 1)
    #expect(await driver.inputs == [.scroll(lines: -3)])
    model.cancelInputTask()
}

@Test("superseded setup cannot publish an input grant")
@MainActor func automaticSetupRejectsSupersededCommand() async throws {
    let model = FlowStateAppModel(desktopController: DesktopAutomationController(driver: AutomaticTargetDriver()))
    model.inputBundleIdentifier = "com.example.Editor"
    var current = true
    let setup = model.beginInputTask(ifCurrent: { current })
    current = false
    await setup?.value
    #expect(model.currentInputGrant == nil)
}

@Test("new speech cancels queued keyboard confirmation")
@MainActor func automaticSupersedesKeyboardConfirmation() async throws {
    let driver = AutomaticTargetDriver()
    let model = FlowStateAppModel(desktopController: DesktopAutomationController(driver: driver), accessibilityGranted: { true })
    let observation = try await model.prepareAutomaticTarget(for: .press(key: "Enter", modifiers: nil), activeBundleIdentifier: "com.example.Editor")
    model.prepareLocalKeyConfirmation(key: "Enter", modifiers: nil, expectedObservation: observation)
    model.consume(SpeechRecognitionResult(transcript: "Resume", language: .english, isFinal: true, utteranceID: UUID(), sessionEnded: false), token: 0)
    try await Task.sleep(for: .milliseconds(50))
    #expect(model.pendingIntentSummary == nil)
    model.cancelInputTask()
}
