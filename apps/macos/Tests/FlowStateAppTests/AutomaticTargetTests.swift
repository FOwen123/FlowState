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

private actor FinalizationDriver: DesktopDriver {
    private var observing = false
    private var released = false
    private var inputs: [DesktopAction] = []

    func observe() async throws -> DesktopObservation {
        observing = true
        while !released { try await Task.sleep(for: .milliseconds(1)) }
        return DesktopObservation(bundleIdentifier: "com.example.Editor", focusedElementID: "field")
    }

    func perform(_ action: DesktopAction, expectedObservation: DesktopObservation, authorize: @escaping @Sendable () async -> Bool) async throws -> DesktopActionResult {
        guard await authorize() else { throw DesktopExecutionError.staleGeneration }
        inputs.append(action)
        return DesktopActionResult(verified: true)
    }

    func restoreValue(_ value: String, expectedObservation: DesktopObservation, authorize: @escaping @Sendable () async -> Bool) async throws {}
    func waitForObservation() async { while !observing { try? await Task.sleep(for: .milliseconds(1)) } }
    func release() { released = true }
    func recordedInputs() -> [DesktopAction] { inputs }
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
    ("Scroll down.", DesktopAction.scroll(lines: -3)),
    ("Scroll up.", DesktopAction.scroll(lines: 3))
])
@MainActor func automaticSpeechPipeline(transcript: String, expected: DesktopAction) async throws {
    let driver = AutomaticTargetDriver()
    let coordinator = SpeechSessionCoordinator()
    await coordinator.pushToTalkDown()
    let model = FlowStateAppModel(desktopController: DesktopAutomationController(driver: driver), accessibilityGranted: { true }, frontmostApplication: { "com.example.Editor" }, speechCoordinator: coordinator)
    model.consume(SpeechRecognitionResult(transcript: transcript, language: .english, isFinal: true, utteranceID: UUID(), sessionEnded: false), token: 0)
    for _ in 0..<100 { if await !driver.inputs.isEmpty { break }; try await Task.sleep(for: .milliseconds(5)) }
    #expect(await driver.inputs == [expected])
    model.cancelInputTask()
}

@Test("an empty terminal result waits for the preceding finalized control task")
@MainActor func emptyTerminalWaitsForFinalizedControlTask() async throws {
    let driver = FinalizationDriver()
    let coordinator = SpeechSessionCoordinator()
    await coordinator.pushToTalkDown()
    let model = FlowStateAppModel(
        desktopController: DesktopAutomationController(driver: driver),
        accessibilityGranted: { true },
        frontmostApplication: { "com.example.Editor" },
        speechCoordinator: coordinator
    )
    model.consume(SpeechRecognitionResult(
        transcript: "Scroll down",
        language: .english,
        isFinal: true,
        utteranceID: UUID(),
        sessionEnded: false
    ), token: 0)
    await driver.waitForObservation()
    model.consume(SpeechRecognitionResult(
        transcript: "",
        language: .english,
        isFinal: true,
        utteranceID: UUID(),
        sessionEnded: true
    ), token: 0)
    try await Task.sleep(for: .milliseconds(20))
    #expect(model.voiceStatus != "Voice session finished")
    await driver.release()
    for _ in 0..<100 {
        if await !driver.recordedInputs().isEmpty { break }
        try await Task.sleep(for: .milliseconds(2))
    }
    #expect(await driver.recordedInputs() == [.scroll(lines: -3)])
    for _ in 0..<100 {
        if model.voiceStatus.hasPrefix("Completed:") { break }
        try await Task.sleep(for: .milliseconds(2))
    }
    #expect(model.voiceStatus == "Completed: Scroll")
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

@Test("dictation cleanup and history retention settings persist")
@MainActor func dictationCleanupAndRetentionPersist() throws {
    let suite = "FlowState.DictationSettingsTests." + UUID().uuidString
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }

    let model = FlowStateAppModel(preferences: preferences)
    model.setDictationCleanup(enabled: false, instructions: "Keep product names unchanged")
    model.setDictationRetentionDays(7)
    model.setControlRetentionDays(14)

    let reopened = FlowStateAppModel(preferences: preferences)
    #expect(!reopened.dictationCleanupEnabled)
    #expect(reopened.dictationCleanupInstructions == "Keep product names unchanged")
    #expect(reopened.dictationRetentionDays == 7)
    #expect(reopened.controlRetentionDays == 14)
}

@Test("unbound speech never starts a control session")
@MainActor func unboundSpeechDoesNotStartControl() async throws {
    let coordinator = SpeechSessionCoordinator(purpose: .control)
    let model = FlowStateAppModel(accessibilityGranted: { false }, frontmostApplication: { nil }, speechCoordinator: coordinator)
    model.consume(SpeechRecognitionResult(transcript: "Hey Flow State", language: .english, isFinal: true, utteranceID: UUID(), sessionEnded: false, purpose: .control), token: 0)
    for _ in 0..<100 { if await coordinator.phase == .listening { break }; try await Task.sleep(for: .milliseconds(2)) }
    #expect(await coordinator.phase == .idle)
    #expect(model.currentInputGrant == nil)
}

@Test("background speech does not prepare app control")
@MainActor func automaticWakeIgnoresBackgroundSpeech() async throws {
    let coordinator = SpeechSessionCoordinator(purpose: .control)
    let model = FlowStateAppModel(desktopController: DesktopAutomationController(driver: AutomaticTargetDriver()), accessibilityGranted: { true }, frontmostApplication: { "com.example.Editor" }, speechCoordinator: coordinator)
    model.consume(SpeechRecognitionResult(transcript: "Hello there", language: .english, isFinal: true, utteranceID: UUID(), sessionEnded: false, purpose: .control), token: 0)
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

@Test("ending capture does not discard an already finalized command", arguments: [false, true], [
    ("Open TextEdit.", DesktopAction.openApplication(bundleIdentifier: "com.apple.TextEdit")),
    ("Scroll down.", .scroll(lines: -3)),
    ("Scroll up.", .scroll(lines: 3)),
    ("Press tab.", .press(key: "Tab", modifiers: nil))
])
@MainActor func sessionEndPreservesFinalCommand(waitForAction: Bool, command: (String, DesktopAction)) async throws {
    let driver = AutomaticTargetDriver()
    let coordinator = SpeechSessionCoordinator(settings: SpeechSettings(mode: .command), purpose: .control)
    await coordinator.pushToTalkDown(purpose: .control)
    let model = FlowStateAppModel(desktopController: DesktopAutomationController(driver: driver), accessibilityGranted: { true }, frontmostApplication: { "com.example.Editor" }, speechCoordinator: coordinator)
    model.speechSettings = SpeechSettings(mode: .command)
    model.consume(SpeechRecognitionResult(transcript: command.0, language: .english, isFinal: true, utteranceID: UUID(), sessionEnded: false, purpose: .control), token: 0)
    if waitForAction {
        for _ in 0..<100 { if model.voiceStatus.hasPrefix("Completed:") { break }; try await Task.sleep(for: .milliseconds(5)) }
    }
    model.consume(SpeechRecognitionResult(transcript: "", language: .english, isFinal: true, utteranceID: UUID(), sessionEnded: true, purpose: .control), token: 0)
    for _ in 0..<100 { if model.voiceStatus.hasPrefix("Completed:") { break }; try await Task.sleep(for: .milliseconds(5)) }
    #expect(await driver.inputs == [command.1])
    #expect(model.voiceStatus.hasPrefix("Completed:"))
    model.cancelInputTask()
}
