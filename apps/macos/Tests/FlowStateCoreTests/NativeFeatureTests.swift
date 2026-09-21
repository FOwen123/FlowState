import Foundation
import Testing
@testable import FlowStateCore

@Test("hold activation is explicit")
func activationModesAreExplicit() async {
    let session = SpeechSessionCoordinator(purpose: .control)
    #expect(await session.phase == .idle)
    await session.pushToTalkDown(purpose: .control)
    #expect(await session.phase == .listening)
    await session.pushToTalkUp(purpose: .control)
    #expect(await session.phase == .stopping)
}

@Test("stop is handled locally in control mode")
func localStopAndDictationMode() async {
    let coordinator = SpeechSessionCoordinator(purpose: .control)
    await coordinator.pushToTalkDown()
    let stop = await coordinator.consume(transcript: "Stop", isFinal: true)
    #expect(stop == .stop)
    #expect(await coordinator.phase == .idle)
}

@Test("an empty terminal endpoint ends the session without dispatching a command")
func emptyTerminalEndpointEndsSession() async {
    let coordinator = SpeechSessionCoordinator(settings: SpeechSettings(mode: .command))
    await coordinator.pushToTalkDown()
    let result = await coordinator.consume(
        transcript: "",
        isFinal: true,
        sessionEnded: true,
        utteranceID: UUID()
    )
    #expect(result == nil)
    #expect(await coordinator.phase == .idle)
}

@Test("partial utterance IDs do not consume the later final result")
func partialUtteranceIDDoesNotDeduplicateFinal() async {
    let coordinator = SpeechSessionCoordinator(settings: SpeechSettings(mode: .command))
    await coordinator.pushToTalkDown()
    let id = UUID()
    #expect(await coordinator.consume(
        transcript: "scroll down",
        isFinal: false,
        sessionEnded: false,
        utteranceID: id
    ) == nil)
    #expect(await coordinator.consume(
        transcript: "scroll down",
        isFinal: true,
        sessionEnded: true,
        utteranceID: id
    ) == .scroll(-3))
}

@Test("speech activation settings persist as user configuration")
func speechSettingsRoundTrip() {
    let defaults = UserDefaults(suiteName: "flowstate-speech-\(UUID().uuidString)")!
    let settings = SpeechSettings(
        language: .english,
        dictationShortcut: .controlOptionSpace,
        controlShortcut: .optionSpace
    )
    SpeechSettingsStore.save(settings, defaults: defaults)
    #expect(SpeechSettingsStore.load(defaults: defaults) == settings)
}

@Test("legacy Traditional Chinese speech settings migrate to English without changing Unicode data")
func legacySpeechSettingsMigrateToEnglish() throws {
    let data = Data("""
    {
      "language": "zh-TW",
      "mode": "command",
      "activation": "toggle",
      "wakePhrase": "嘿 Flow State",
      "pushToTalkKey": "⌥ Space",
      "draft": "繁體中文內容 — keep unchanged"
    }
    """.utf8)
    let settings = try JSONDecoder().decode(SpeechSettings.self, from: data)
    #expect(settings.language == .english)
    #expect(settings.controlShortcut == .optionSpace)
    #expect(settings.dictationShortcut == .controlOptionSpace)
}

@Test("desktop execution rejects stale, expired, and unapproved actions")
func desktopExecutionGrantValidation() async throws {
    let driver = RecordingDesktopDriver()
    let controller = DesktopAutomationController(driver: driver)
    let grant = DesktopExecutionGrant(
        allowedBundleIdentifiers: ["com.example.Reader"],
        allowedActions: [.scroll],
        generation: 1,
        expiresAt: Date().addingTimeInterval(60)
    )
    try await controller.begin(grant: grant)
    let result = try await controller.execute(
        .scroll(lines: -3),
        expectedBundleIdentifier: "com.example.Reader"
    )
    #expect(result.undoSupport == .none)
    await controller.cancel()

    await #expect(throws: DesktopExecutionError.staleGeneration) {
        _ = try await controller.execute(
            .scroll(lines: -3),
            expectedBundleIdentifier: "com.example.Reader"
        )
    }

    let switchDriver = RecordingDesktopDriver(bundleIdentifier: "com.example.Editor")
    let switchController = DesktopAutomationController(driver: switchDriver)
    let openGrant = DesktopExecutionGrant(
        allowedBundleIdentifiers: ["com.example.Reader"],
        allowedActions: [.openApplication],
        generation: 2,
        expiresAt: Date().addingTimeInterval(60)
    )
    try await switchController.begin(grant: openGrant)
    _ = try await switchController.execute(
        .openApplication(bundleIdentifier: "com.example.Reader"),
        expectedBundleIdentifier: "com.example.Reader"
    )
}

@Test("secure Accessibility boundaries reject both role and subrole representations")
func secureAccessibilityBoundary() {
    #expect(AXDesktopDriver.isSecureTextField(role: "AXTextField", subrole: "AXSecureTextField"))
    #expect(AXDesktopDriver.isSecureTextField(role: "AXSecureTextField", subrole: nil))
    #expect(!AXDesktopDriver.isSecureTextField(role: "AXTextField", subrole: "AXTextField"))
    #expect(AXDesktopDriver.canReadValue(role: "AXTextField", subrole: nil))
    #expect(!AXDesktopDriver.canReadValue(role: nil, subrole: nil))
    #expect(!AXDesktopDriver.canReadValue(role: "AXSecureTextField", subrole: nil))
    #expect(!AXDesktopDriver.canReadValue(role: "AXTextField", subrole: "AXSecureTextField"))
}

@Test("an expired grant is rejected immediately before a native effect")
func expirationIsCheckedAtEffectBoundary() async throws {
    let driver = ExpiringAuthorizationDriver()
    let controller = DesktopAutomationController(driver: driver)
    let grant = DesktopExecutionGrant(
        allowedBundleIdentifiers: ["com.example.Reader"],
        allowedActions: [.press],
        generation: 11,
        expiresAt: Date().addingTimeInterval(0.01)
    )
    try await controller.begin(grant: grant)

    await #expect(throws: DesktopExecutionError.staleGeneration) {
        _ = try await controller.execute(
            .press,
            expectedBundleIdentifier: "com.example.Reader"
        )
    }
    #expect(await driver.effectCount() == 0)
}

@Test("physical input leaves automation active and the next action reobserves")
func physicalInputContinuesWithReobserve() async throws {
    let driver = RecordingDesktopDriver()
    let controller = DesktopAutomationController(driver: driver)
    let grant = DesktopExecutionGrant(
        allowedBundleIdentifiers: ["com.example.Reader"],
        allowedActions: [.press],
        generation: 4,
        expiresAt: Date().addingTimeInterval(60)
    )
    try await controller.begin(grant: grant)
    await controller.notePhysicalTakeover()
    #expect(await controller.state == .ready)
    _ = try await controller.execute(.press, expectedBundleIdentifier: "com.example.Reader")
    #expect(await controller.state == .ready)
}

@Test("execution reserves the controller before its first observation")
func executionReservesBeforeObservation() async throws {
    let driver = ObservationGateDriver()
    let controller = DesktopAutomationController(driver: driver)
    let grant = DesktopExecutionGrant(
        allowedBundleIdentifiers: ["com.example.Reader"],
        allowedActions: [.press],
        generation: 6,
        expiresAt: Date().addingTimeInterval(60)
    )
    try await controller.begin(grant: grant)

    let first = Task {
        try await controller.execute(.press, expectedBundleIdentifier: "com.example.Reader")
    }
    await driver.waitForFirstObservation()

    let second = Task {
        try await controller.execute(.press, expectedBundleIdentifier: "com.example.Reader")
    }
    try await Task.sleep(for: .milliseconds(20))
    #expect(await driver.observationCount() == 1)

    await driver.releaseObservation()
    _ = try? await first.value
    _ = try? await second.value
}

@Test("cancelling while observing cannot install a new grant")
func cancellationDuringObservationDoesNotRevive() async throws {
    let driver = ObservationGateDriver()
    let controller = DesktopAutomationController(driver: driver)
    let grant = DesktopExecutionGrant(
        allowedBundleIdentifiers: ["com.example.Reader"],
        allowedActions: [.press],
        generation: 7,
        expiresAt: Date().addingTimeInterval(60)
    )
    try await controller.begin(grant: grant)
    let execution = Task { try await controller.execute(.press, expectedBundleIdentifier: "com.example.Reader") }
    await driver.waitForFirstObservation()
    await controller.cancel()
    await driver.releaseObservation()

    await #expect(throws: DesktopExecutionError.staleGeneration) {
        _ = try await execution.value
    }
    #expect(await controller.state == .cancelled)
}

@Test("cancelled work cannot become valid again after physical input")
func cancellationSurvivesPhysicalInput() async throws {
    let driver = GatedDesktopDriver()
    let controller = DesktopAutomationController(driver: driver)
    let grant = DesktopExecutionGrant(
        allowedBundleIdentifiers: ["com.example.Reader"],
        allowedActions: [.press],
        generation: 8,
        expiresAt: Date().addingTimeInterval(60)
    )
    try await controller.begin(grant: grant)
    let task = Task {
        try await controller.execute(.press, expectedBundleIdentifier: "com.example.Reader")
    }
    await driver.waitForPerform()
    await controller.notePhysicalTakeover()
    await controller.cancel()
    await driver.releasePerform()
    await #expect(throws: DesktopExecutionError.staleGeneration) {
        _ = try await task.value
    }
    #expect(await controller.state == .cancelled)
}

@Test("control execution rejects generic insertion before undo")
func verifiedTextUndo() async throws {
    let driver = RecordingDesktopDriver(initialValue: "before", bundleIdentifier: "com.example.Editor")
    let controller = DesktopAutomationController(driver: driver)
    let grant = DesktopExecutionGrant(
        allowedBundleIdentifiers: ["com.example.Editor"],
        allowedActions: [.insertText],
        generation: 5,
        expiresAt: Date().addingTimeInterval(60)
    )
    try await controller.begin(grant: grant)
    await #expect(throws: DesktopExecutionError.actionNotGranted) {
        _ = try await controller.execute(.insertText("after"), expectedBundleIdentifier: "com.example.Editor")
    }
    #expect(await driver.currentValue() == "before")
}

@Test("generic insertion is rejected before a cancellable undo")
func cancellationDuringUndoDoesNotRestore() async throws {
    let driver = GatedUndoDriver()
    let controller = DesktopAutomationController(driver: driver)
    let grant = DesktopExecutionGrant(
        allowedBundleIdentifiers: ["com.example.Editor"],
        allowedActions: [.insertText],
        generation: 9,
        expiresAt: Date().addingTimeInterval(60)
    )
    try await controller.begin(grant: grant)
    await #expect(throws: DesktopExecutionError.actionNotGranted) {
        _ = try await controller.execute(.insertText("after"), expectedBundleIdentifier: "com.example.Editor")
    }
    #expect(await driver.restoreCount() == 0)
}

@Test("a cancelled driver error does not restore ready state")
func cancellationDuringDriverErrorPreservesCancelledState() async throws {
    let driver = ThrowingGatedDriver()
    let controller = DesktopAutomationController(driver: driver)
    let grant = DesktopExecutionGrant(
        allowedBundleIdentifiers: ["com.example.Reader"],
        allowedActions: [.press],
        generation: 10,
        expiresAt: Date().addingTimeInterval(60)
    )
    try await controller.begin(grant: grant)

    let execution = Task {
        try await controller.execute(.press, expectedBundleIdentifier: "com.example.Reader")
    }
    await driver.waitForPerform()
    await controller.cancel()
    await driver.releasePerform()
    _ = try? await execution.value
    #expect(await controller.state == .cancelled)
}

@Test("file approval binds an exact file and expires")
func approvedFileBoundary() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("flowstate-file-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("notes.txt")
    try Data("hello".utf8).write(to: file)

    let approved = try ApprovedFile.approve(
        fileURL: file,
        taskID: "task-1",
        allowedDirectory: directory,
        expiresAt: Date().addingTimeInterval(60)
    )
    #expect(try approved.readData() == Data("hello".utf8))
    #expect(throws: FileBoundaryError.self) {
        try FileUploadBoundary.validate(approved, taskID: "other-task")
    }
    let expired = try ApprovedFile.approve(
        fileURL: file,
        taskID: "task-1",
        allowedDirectory: directory,
        expiresAt: Date().addingTimeInterval(-1)
    )
    #expect(throws: FileBoundaryError.expired) {
        try expired.readData()
    }
}

@Test("explicit memory persists and explicit values win")
func explicitMemoryPersistenceAndPrecedence() async throws {
    let suite = "flowstate-memory-\(UUID().uuidString)"
    let first = ExplicitMemoryStore(suiteName: suite)
    let explicit = try await first.upsert(
        trigger: "my browser",
        value: "Brave",
        category: .appAlias
    )
    try await first.setLearningEnabled(true)
    _ = try await first.upsert(
        trigger: "my browser",
        value: "Safari",
        category: .appAlias,
        source: .learned
    )
    #expect(await first.effectiveValue(for: "my browser") == "Brave")
    #expect(await first.snapshot().syncEnabled == false)

    let second = ExplicitMemoryStore(suiteName: suite)
    #expect(await second.preference(id: explicit.id)?.value == "Brave")
    try await second.delete(id: explicit.id)
    #expect(await second.effectiveValue(for: "my browser") == "Safari")
}

@Test("learned memory requires explicit opt in")
func learnedMemoryRequiresOptIn() async throws {
    let store = ExplicitMemoryStore(suiteName: "flowstate-memory-opt-in-\(UUID().uuidString)")
    await #expect(throws: MemoryStoreError.self) {
        _ = try await store.upsert(
            trigger: "my browser",
            value: "Safari",
            category: .appAlias,
            source: .learned
        )
    }
    #expect(await store.snapshot().preferences.isEmpty)

    try await store.setLearningEnabled(true)
    _ = try await store.upsert(
        trigger: "my browser",
        value: "Safari",
        category: .appAlias,
        source: .learned
    )
    #expect(await store.effectiveValue(for: "my browser") == "Safari")
}

@Test("workflow recovery distinguishes uncertain work and bounds retries")
func workflowRecovery() async throws {
    let store = WorkflowRecoveryStore(suiteName: "flowstate-recovery-\(UUID().uuidString)")
    try await store.begin(operationID: "op-1", title: "Send draft")
    try await store.markUncertain(operationID: "op-1", reason: "provider accepted request")
    #expect(await store.recoveryAction(operationID: "op-1") == .reconcile)

    var budget = RetryBudget(maxAttempts: 2)
    #expect(budget.consume() == true)
    #expect(budget.consume() == true)
    #expect(budget.consume() == false)
}

private actor RecordingDesktopDriver: DesktopDriver {
    private var value: String
    private var activeBundle: String

    init(initialValue: String = "", bundleIdentifier: String = "com.example.Reader") {
        value = initialValue
        activeBundle = bundleIdentifier
    }

    func observe() async throws -> DesktopObservation {
        DesktopObservation(
            bundleIdentifier: activeBundle,
            focusedElementID: "focused-1",
            value: value
        )
    }

    func perform(
        _ action: DesktopAction,
        expectedObservation: DesktopObservation,
        authorize: @escaping @Sendable () async -> Bool
    ) async throws -> DesktopActionResult {
        guard await authorize() else { throw DesktopExecutionError.staleGeneration }
        switch action {
        case let .insertText(text):
            let before = value
            value = text
            return DesktopActionResult(verified: true, valueBefore: before, valueAfter: text)
        case let .openApplication(bundleIdentifier):
            activeBundle = bundleIdentifier
            return DesktopActionResult(verified: true)
        default:
            return DesktopActionResult(verified: true)
        }
    }

    func restoreValue(
        _ value: String,
        expectedObservation: DesktopObservation,
        authorize: @escaping @Sendable () async -> Bool
    ) async throws {
        guard await authorize() else { throw DesktopExecutionError.staleGeneration }
        self.value = value
    }

    func currentValue() -> String { value }
    func setValue(_ value: String) { self.value = value }
}

private actor GatedDesktopDriver: DesktopDriver {
    private var performing = false
    private var released = false

    func observe() async throws -> DesktopObservation {
        DesktopObservation(bundleIdentifier: "com.example.Reader", focusedElementID: "focused-1")
    }

    func perform(
        _ action: DesktopAction,
        expectedObservation: DesktopObservation,
        authorize: @escaping @Sendable () async -> Bool
    ) async throws -> DesktopActionResult {
        performing = true
        while !released {
            try await Task.sleep(for: .milliseconds(1))
        }
        guard await authorize() else { throw DesktopExecutionError.staleGeneration }
        return DesktopActionResult(verified: true)
    }

    func restoreValue(
        _ value: String,
        expectedObservation: DesktopObservation,
        authorize: @escaping @Sendable () async -> Bool
    ) async throws {
        guard await authorize() else { throw DesktopExecutionError.staleGeneration }
    }

    func waitForPerform() async {
        while !performing {
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    func releasePerform() {
        released = true
    }
}

private actor ObservationGateDriver: DesktopDriver {
    private var observations = 0
    private var firstObservationStarted = false
    private var released = false

    func observe() async throws -> DesktopObservation {
        observations += 1
        firstObservationStarted = true
        while !released {
            try await Task.sleep(for: .milliseconds(1))
        }
        return DesktopObservation(bundleIdentifier: "com.example.Reader", focusedElementID: "focused-1")
    }

    func perform(
        _ action: DesktopAction,
        expectedObservation: DesktopObservation,
        authorize: @escaping @Sendable () async -> Bool
    ) async throws -> DesktopActionResult {
        guard await authorize() else { throw DesktopExecutionError.staleGeneration }
        return DesktopActionResult(verified: true)
    }

    func restoreValue(
        _ value: String,
        expectedObservation: DesktopObservation,
        authorize: @escaping @Sendable () async -> Bool
    ) async throws {
        guard await authorize() else { throw DesktopExecutionError.staleGeneration }
    }

    func waitForFirstObservation() async {
        while !firstObservationStarted {
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    func observationCount() -> Int { observations }

    func releaseObservation() { released = true }
}

private actor GatedUndoDriver: DesktopDriver {
    private var value = "before"
    private var shouldBlockObservation = false
    private var blockedObservationStarted = false
    private var released = false
    private var restores = 0

    func observe() async throws -> DesktopObservation {
        if shouldBlockObservation {
            blockedObservationStarted = true
            while !released {
                try await Task.sleep(for: .milliseconds(1))
            }
        }
        return DesktopObservation(
            bundleIdentifier: "com.example.Editor",
            focusedElementID: "focused-1",
            value: value
        )
    }

    func perform(
        _ action: DesktopAction,
        expectedObservation: DesktopObservation,
        authorize: @escaping @Sendable () async -> Bool
    ) async throws -> DesktopActionResult {
        guard case let .insertText(text) = action else {
            return DesktopActionResult(verified: true)
        }
        guard await authorize() else { throw DesktopExecutionError.staleGeneration }
        let before = value
        value = text
        return DesktopActionResult(verified: true, valueBefore: before, valueAfter: value)
    }

    func restoreValue(
        _ value: String,
        expectedObservation: DesktopObservation,
        authorize: @escaping @Sendable () async -> Bool
    ) async throws {
        guard await authorize() else { throw DesktopExecutionError.staleGeneration }
        restores += 1
        self.value = value
    }

    func blockNextObservation() {
        shouldBlockObservation = true
        blockedObservationStarted = false
        released = false
    }

    func waitForBlockedObservation() async {
        while !blockedObservationStarted {
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    func releaseObservation() { released = true }
    func restoreCount() -> Int { restores }
}

private actor ThrowingGatedDriver: DesktopDriver {
    private var performing = false
    private var released = false

    func observe() async throws -> DesktopObservation {
        DesktopObservation(bundleIdentifier: "com.example.Reader", focusedElementID: "focused-1")
    }

    func perform(
        _ action: DesktopAction,
        expectedObservation: DesktopObservation,
        authorize: @escaping @Sendable () async -> Bool
    ) async throws -> DesktopActionResult {
        performing = true
        while !released {
            try await Task.sleep(for: .milliseconds(1))
        }
        guard await authorize() else { throw DesktopExecutionError.staleGeneration }
        throw DriverFailure.failed
    }

    func restoreValue(
        _ value: String,
        expectedObservation: DesktopObservation,
        authorize: @escaping @Sendable () async -> Bool
    ) async throws {
        guard await authorize() else { throw DesktopExecutionError.staleGeneration }
    }

    func waitForPerform() async {
        while !performing {
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    func releasePerform() { released = true }
}

private actor ExpiringAuthorizationDriver: DesktopDriver {
    private var effects = 0

    func observe() async throws -> DesktopObservation {
        DesktopObservation(bundleIdentifier: "com.example.Reader", focusedElementID: "focused-1")
    }

    func perform(
        _ action: DesktopAction,
        expectedObservation: DesktopObservation,
        authorize: @escaping @Sendable () async -> Bool
    ) async throws -> DesktopActionResult {
        try await Task.sleep(for: .milliseconds(50))
        guard await authorize() else { throw DesktopExecutionError.staleGeneration }
        effects += 1
        return DesktopActionResult(verified: true)
    }

    func restoreValue(
        _ value: String,
        expectedObservation: DesktopObservation,
        authorize: @escaping @Sendable () async -> Bool
    ) async throws {
        guard await authorize() else { throw DesktopExecutionError.staleGeneration }
    }

    func effectCount() -> Int { effects }
}

private enum DriverFailure: Error {
    case failed
}
