import AppKit
import CoreGraphics
import FlowStateCore
import FlowStateCloud
import SwiftUI

@MainActor
final class FlowStateAppModel: ObservableObject {
    @Published var useManagedCommands = UserDefaults.standard.bool(forKey: "FlowState.managedCommands")
    @Published private(set) var executingPlan = false
    private(set) var currentInputGrant: DesktopExecutionGrant?
    private var inputEpoch = InputEpochGate()
    @Published var cloudSession: CloudSession?
    @Published private(set) var cloudStatus = "Sign in through Cloud account to use research"
    @Published private(set) var isListening = false { didSet { updateVoiceHUD() } }
    private var preparingVoice = false
    private var voiceGeneration: UInt64 = 0
    @Published var bundleIdentifier = ""
    @Published var speechSettings = SpeechSettings()
    @Published private(set) var shortcutError: String?
    @Published private(set) var permissionSnapshot = MacPermissionManager.snapshot()
    @Published private(set) var permissionStatus = "Checking Screen Recording permission…"
    @Published private(set) var taskStatus = "Idle — screen capture is off"
    @Published private(set) var voiceStatus = "Voice session is idle" { didSet { updateVoiceHUD() } }
    @Published private(set) var latestTranscript = "" { didSet { updateVoiceHUD() } }
    @Published private(set) var isTaskActive = false
    @Published private(set) var memorySnapshot = MemorySnapshot(preferences: [], syncEnabled: false, learningEnabled: false)
    @Published var inputBundleIdentifier = ""
    @Published private(set) var allowedInputActions: Set<DesktopActionKind> = Set(DesktopActionKind.allCases)
    @Published private(set) var desktopState = DesktopAutomationState.idle
    @Published private(set) var desktopStatus = "Desktop control is idle"

    /// Root may bind this to the managed CloudSession plan cancellation method.
    var onCancelCloud: (() -> Void)?

    /// Research is cancelled only by an explicit Stop, never by an input-grant
    /// cancellation or a physical takeover.
    var onCancelResearch: (() -> Void)?

    /// Root may bind this to the managed Convex research action. It is called
    /// only for the explicit `research …` / `研究 …` command shape.
    var onResearch: ((String) -> Void)?

    let memoryStore = ExplicitMemoryStore()
    private let controller: ScreenCaptureController
    private let desktopController: DesktopAutomationController
    private let speechCoordinator = SpeechSessionCoordinator()
    private let speechCapture = AnalyzerSpeechCapture()
    private let takeoverMonitor = InputTakeoverMonitor()
    private let shortcutMonitor = GlobalVoiceShortcutMonitor()
    private let voiceHUD = VoiceHUDController()
    private var showsVoiceHUD = false
    private var grant: CaptureGrant?
    private var lastVerifiedAction: VerifiedDesktopAction?
    private var statusGeneration: UInt64 = 0

    init(desktopController: DesktopAutomationController = DesktopAutomationController()) {
        self.desktopController = desktopController
        controller = ScreenCaptureController()
        speechSettings = SpeechSettingsStore.load()
        refreshPermissionStatus()
        Task { await refreshMemory() }
    }

    func refreshPermissionStatus() {
        permissionSnapshot = MacPermissionManager.snapshot()
        permissionStatus = permissionSnapshot.screenRecording.isGranted
            ? "Screen Recording permission granted"
            : "Screen Recording permission required"
        shortcutMonitor.startIfNeeded(
            shortcut: speechSettings.shortcut,
            onKeyDown: { [weak self] in self?.handleShortcutDown() },
            onKeyUp: { [weak self] in self?.handleShortcutUp() }
        )
        shortcutError = shortcutMonitor.registrationError == nil ? nil
            : "This shortcut is in use or unavailable. Choose another in Voice & activation."
    }

    func requestPermission(_ permission: MacPermission) {
        Task {
            switch permission {
            case .microphone:
                _ = await MacPermissionManager.requestMicrophone()
            case .speechRecognition:
                _ = await MacPermissionManager.requestSpeechRecognition()
            case .accessibility:
                _ = MacPermissionManager.accessibilityStatus(prompt: true)
            case .screenRecording:
                _ = MacPermissionManager.requestScreenRecording()
            }
            refreshPermissionStatus()
        }
    }

    func requestScreenPermission() {
        requestPermission(.screenRecording)
    }

    func beginTask() {
        let bundle = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bundle.isEmpty else {
            taskStatus = "Enter an approved application bundle ID first"
            return
        }

        statusGeneration &+= 1
        let taskGeneration = statusGeneration
        Task {
            let nextGrant = await controller.beginTask(allowedBundleIdentifiers: [bundle])
            guard taskGeneration == statusGeneration else { return }
            grant = nextGrant
            isTaskActive = true
            taskStatus = "Active for \(bundle) — capture only runs on request"
        }
    }

    func revokeTask() {
        statusGeneration &+= 1
        grant = nil
        isTaskActive = false
        taskStatus = "Revoked — screen capture is off"
        Task { await controller.revoke() }
    }

    func setInputAction(_ action: DesktopActionKind, enabled: Bool) {
        if enabled { allowedInputActions.insert(action) }
        else { allowedInputActions.remove(action) }
    }

    func beginInputTask() {
        let bundle = inputBundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bundle.isEmpty else {
            desktopStatus = "Enter the application bundle ID before granting input"
            return
        }
        guard !allowedInputActions.isEmpty else {
            desktopStatus = "Choose at least one desktop action"
            return
        }
        let epoch = inputEpoch.advance()
        currentInputGrant = nil
        lastVerifiedAction = nil
        takeoverMonitor.stop()
        statusGeneration &+= 1
        let nextGeneration = statusGeneration
        let inputGrant = DesktopExecutionGrant(
            allowedBundleIdentifiers: [bundle],
            allowedActions: allowedInputActions,
            generation: nextGeneration,
            expiresAt: Date().addingTimeInterval(CaptureGrant.defaultDuration)
        )
        Task { [weak self] in
            guard let self else { return }
            do {
                guard inputEpoch.isCurrent(epoch) else { return }
                await desktopController.cancel(lifecycleEpoch: epoch)
                guard inputEpoch.isCurrent(epoch) else { return }
                try await desktopController.begin(grant: inputGrant, lifecycleEpoch: epoch)
                guard inputEpoch.isCurrent(epoch) else {
                    await desktopController.cancel(lifecycleEpoch: epoch)
                    return
                }
                currentInputGrant = inputGrant
                desktopState = await desktopController.state
                desktopStatus = "Input granted for \(bundle) — Flow State will pause on your input"
                installTakeoverMonitor(for: epoch)
            } catch {
                guard inputEpoch.isCurrent(epoch) else { return }
                currentInputGrant = nil
                lastVerifiedAction = nil
                takeoverMonitor.stop()
                desktopState = await desktopController.state
                desktopStatus = error.localizedDescription
            }
        }
    }

    func cancelInputTask() {
        desktopState = .cancelled
        let epoch = inputEpoch.advance()
        currentInputGrant = nil
        lastVerifiedAction = nil
        takeoverMonitor.stop()
        onCancelCloud?()
        Task {
            await desktopController.cancel(lifecycleEpoch: epoch)
            guard inputEpoch.isCurrent(epoch) else { return }
            desktopState = await desktopController.state
            desktopStatus = "Desktop control cancelled locally"
        }
    }

    func handlePhysicalTakeover(for epoch: UInt64) {
        guard inputEpoch.isCurrent(epoch) else { return }
        let invalidatedEpoch = inputEpoch.advance()
        desktopState = .pausedForUser
        // Keep the unexpired grant for explicit Resume; the controller is paused.
        lastVerifiedAction = nil
        takeoverMonitor.stop()
        onCancelCloud?()
        Task { @MainActor [weak self] in
            guard let self else { return }
            await desktopController.notePhysicalTakeover(lifecycleEpoch: invalidatedEpoch)
            guard inputEpoch.isCurrent(invalidatedEpoch) else { return }
            desktopState = await desktopController.state
            desktopStatus = "Paused for your input — resume only when ready"
        }
    }

    private func installTakeoverMonitor(for epoch: UInt64) {
        takeoverMonitor.start(shortcut: speechSettings.shortcut) { [weak self] in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self, self.inputEpoch.isCurrent(epoch) else { return }
                self.handlePhysicalTakeover(for: epoch)
            }
        }
    }

    private func invalidateLocalInputForSessionLoss() {
        desktopState = .cancelled
        let epoch = inputEpoch.advance()
        currentInputGrant = nil
        lastVerifiedAction = nil
        takeoverMonitor.stop()
        Task { @MainActor [weak self] in
            guard let self else { return }
            await desktopController.cancel(lifecycleEpoch: epoch)
            guard inputEpoch.isCurrent(epoch) else { return }
            desktopState = await desktopController.state
            desktopStatus = "Cloud session ended — desktop control cancelled locally"
        }
    }

    func resumeInputTask() {
        let epoch = inputEpoch.current
        guard let grant = currentInputGrant, grant.expiresAt > Date() else {
            desktopStatus = "Renew the app input grant before resuming"
            return
        }
        Task {
            do {
                _ = try await desktopController.resume()
                guard inputEpoch.isCurrent(epoch), currentInputGrant != nil,
                      grant.expiresAt > Date() else { return }
                installTakeoverMonitor(for: epoch)
                desktopState = await desktopController.state
                desktopStatus = "Desktop control resumed after a fresh observation"
            } catch {
                guard inputEpoch.isCurrent(epoch) else { return }
                desktopStatus = error.localizedDescription
                desktopState = await desktopController.state
            }
        }
    }

    func undoLastDesktopAction() {
        guard let lastVerifiedAction else {
            desktopStatus = "There is no verified reversible action to undo"
            return
        }
        Task {
            do {
                try await desktopController.undo(lastVerifiedAction)
                self.lastVerifiedAction = nil
                desktopStatus = "Verified text edit undone"
            } catch {
                desktopStatus = error.localizedDescription
            }
        }
    }

    func captureApprovedWindow() {
        guard let grant else {
            taskStatus = "Start an active task before capturing"
            return
        }

        let bundle = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let taskGeneration = statusGeneration
        taskStatus = "Capturing approved window…"
        Task {
            do {
                let frame = try await controller.capture(bundleIdentifier: bundle, grant: grant)
                guard taskGeneration == statusGeneration else { return }
                taskStatus = "Captured \(frame.image.width)×\(frame.image.height) in memory"
            } catch {
                guard taskGeneration == statusGeneration else { return }
                taskStatus = error.localizedDescription
            }
        }
    }

    func connectCloud(_ configuration: CloudConfiguration) {
        guard cloudSession == nil else { return }
        let session = CloudSession(configuration: configuration)
        cloudSession = session
        session.onSessionInvalidated = { [weak self] in
            self?.invalidateLocalInputForSessionLoss()
        }
        onResearch = { [weak self, weak session] query in
            guard let self, let session else { return }
            guard session.signedIn else { self.cloudStatus = "Sign in before research / 請先登入"; return }
            self.cloudStatus = "Researching public sources / 正在研究公開來源"
            Task {
                do { try await session.research(query: query); self.cloudStatus = "Research ready in Cloud account / 研究結果已就緒" }
                catch { self.cloudStatus = "Research stopped. Check the connection and sign-in. / 研究已停止。" }
            }
        }
        onCancelCloud = { [weak session] in
            Task { await session?.cancelPlan() }
        }
        onCancelResearch = { [weak session] in
            Task { try? await session?.cancelResearch() }
        }
    }

    func prepareCloudCommand(_ command: String) {
        guard let cloudSession, cloudSession.signedIn else { cloudStatus = "Sign in before managed commands / 請先登入"; return }
        guard let grant = currentInputGrant, grant.expiresAt > Date(), let target = grant.allowedBundleIdentifiers.first else { cloudStatus = "Grant input for an app first / 請先授權操作應用程式"; return }
        cloudStatus = "Preparing a plan for review / 正在準備待確認的操作"
        Task {
            do { try await cloudSession.preparePlan(command:command,targetBundleIdentifier:target,locale:speechSettings.language == .traditionalChinese ? "zh-Hant" : "en"); cloudStatus = "Review the proposed actions in Cloud account / 請至雲端帳戶檢視操作" }
            catch { cloudStatus = "This request needs clarification or could not be planned. / 請重新說明操作。" }
        }
    }

    func executeCloudPlan(_ plan: CloudProposal) {
        guard !executingPlan, let session = cloudSession, let grant = currentInputGrant, grant.expiresAt > Date(), let target = grant.allowedBundleIdentifiers.first else { cloudStatus = "Renew the app input grant before continuing / 請重新授權"; return }
        executingPlan = true
        let epoch = inputEpoch.current
        Task {
            var reserved: Int?
            defer { executingPlan = false }
            do {
                // The Confirm button must use the grant that was explicitly
                // started before this cloud request. Never regrant after a
                // network suspension, and never resume a takeover-paused task
                // implicitly.
                guard inputEpoch.isCurrent(epoch), grant.expiresAt > Date(),
                      await desktopController.state == .ready else {
                    throw DesktopExecutionError.pausedForTakeover
                }
                try await session.beginExecution(plan,allowedActions:grant.allowedActions,target:target,expiresAt:grant.expiresAt)
                guard inputEpoch.isCurrent(epoch), session.isCurrent(plan) else { throw CancellationError() }
                for (index, action) in plan.actions.enumerated() {
                    guard inputEpoch.isCurrent(epoch), session.isCurrent(plan) else { throw CancellationError() }
                    try await session.claimStep(plan,ordinal:index)
                    reserved = index
                    guard inputEpoch.isCurrent(epoch), session.isCurrent(plan) else { throw CancellationError() }
                    let result = try await desktopController.execute(action.desktopAction,expectedBundleIdentifier:action.targetBundleIdentifier)
                    guard inputEpoch.isCurrent(epoch), session.isCurrent(plan) else { throw CancellationError() }
                    lastVerifiedAction = result.undoSupport == .restoreText ? result : nil
                    try await session.finishStep(plan,ordinal:index,verified:true)
                    reserved = nil
                }
                cloudStatus = "Plan completed / 操作已完成"
            } catch {
                if let reserved { try? await session.finishStep(plan,ordinal:reserved,verified:false) }
                await session.cancelPlan()
                cloudStatus = "Plan stopped. Check the last action before trying again. / 操作已停止，請檢查最後一步。"
            }
            desktopState = await desktopController.state
        }
    }

    private func updateVoiceHUD() {
        guard showsVoiceHUD else { return }
        voiceHUD.show(status: voiceStatus, transcript: latestTranscript, isListening: isListening,
            onFinish: { [weak self] in self?.finishVoiceSession() },
            onStop: { [weak self] in self?.stopVoiceSession() })
    }

    func startVoiceSession() {
        if isListening {
            if speechSettings.activation == .toggle { finishVoiceSession() }
            return
        }
        showsVoiceHUD = true
        latestTranscript = ""
        refreshPermissionStatus()
        guard permissionSnapshot.microphone.isGranted else {
            voiceStatus = "Microphone permission is required"
            return
        }
        voiceGeneration &+= 1
        let voiceToken = voiceGeneration
        preparingVoice = true
        isListening = true
        voiceStatus = "Preparing on-device speech / 正在準備本機語音辨識"
        Task { [weak self] in
            guard let self, voiceToken == voiceGeneration else { return }
            let currentSettings = speechSettings
            await speechCoordinator.update(settings: currentSettings)
            switch currentSettings.activation {
            case .pushToTalk:
                _ = await speechCoordinator.pushToTalkDown()
            case .toggle:
                _ = await speechCoordinator.toggle()
            case .wakePhrase:
                // The recognizer remains active to hear the configured phrase;
                // the coordinator opens a command session only after a match.
                break
            }
            do {
                try await startSpeechCapture(language: currentSettings.language)
                guard voiceToken == voiceGeneration else { return }
                preparingVoice = false
                isListening = true
                voiceStatus = currentSettings.activation == .wakePhrase
                    ? "Listening for \(currentSettings.wakePhrase)"
                    : "Listening — say a command or press Stop"
            } catch {
                guard voiceToken == voiceGeneration else { return }
                preparingVoice = false; isListening = false
                await speechCoordinator.localStop()
                voiceStatus = error.localizedDescription
            }
        }
    }

    func finishVoiceSession() {
        guard isListening else { return }
        isListening = false
        if preparingVoice {
            preparingVoice = false; voiceGeneration &+= 1; speechCapture.stop()
            Task { await speechCoordinator.localStop() }
            voiceStatus = "Released before speech was ready. Hold again. / 請再次按住快捷鍵。"
            return
        }
        speechCapture.finish()
        Task { await speechCoordinator.pushToTalkUp() }
        voiceStatus = "Finishing transcription / 正在完成辨識"
    }

    func stopVoiceSession() {
        showsVoiceHUD = false
        voiceHUD.hide()
        voiceGeneration &+= 1
        preparingVoice = false
        isListening = false
        speechCapture.stop()
        cancelInputTask()
        onCancelResearch?()
        let token = voiceGeneration
        Task {
            await speechCoordinator.localStop()
            guard token == voiceGeneration else { return }
            voiceStatus = "Voice session stopped locally"
        }
    }

    func installSpeechLanguage() {
        voiceStatus = "Installing on-device language model… / 正在安裝語音模型"
        let language = speechSettings.language
        Task {
            do { try await AnalyzerSpeechCapture.installLanguage(language); voiceStatus = "Language model ready / 語音模型已就緒" }
            catch { voiceStatus = "Could not install language model. Check your connection. / 無法安裝語音模型。" }
        }
    }

    func updateSpeechSettings(_ settings: SpeechSettings) {
        stopVoiceSession()
        speechSettings = settings
        SpeechSettingsStore.save(settings)
        shortcutMonitor.stop()
        shortcutMonitor.startIfNeeded(
            shortcut: settings.shortcut,
            onKeyDown: { [weak self] in self?.handleShortcutDown() },
            onKeyUp: { [weak self] in self?.handleShortcutUp() }
        )
        shortcutError = shortcutMonitor.registrationError == nil ? nil
            : "This shortcut is in use or unavailable. Choose another in Voice & activation."
        if currentInputGrant != nil {
            let epoch = inputEpoch.current
            installTakeoverMonitor(for: epoch)
        }
        Task { await speechCoordinator.update(settings: settings) }
    }

    func refreshMemory() async {
        memorySnapshot = await memoryStore.snapshot()
    }

    func setMemorySync(_ enabled: Bool) {
        Task {
            try? await memoryStore.setSyncEnabled(enabled)
            await refreshMemory()
        }
    }

    func setMemoryLearning(_ enabled: Bool) {
        Task {
            try? await memoryStore.setLearningEnabled(enabled)
            await refreshMemory()
        }
    }

    func addMemory(trigger: String, value: String, category: MemoryCategory) {
        Task {
            _ = try? await memoryStore.upsert(trigger: trigger, value: value, category: category)
            await refreshMemory()
        }
    }

    func deleteMemory(id: UUID) {
        Task {
            try? await memoryStore.delete(id: id)
            await refreshMemory()
        }
    }

    private func consume(_ result: SpeechRecognitionResult, token: UInt64) {
        guard token == voiceGeneration else { return }
        latestTranscript = result.transcript
        if result.isFinal {
            isListening = false
            voiceStatus = result.transcript.isEmpty
                ? "No speech detected. Try again. / 未偵測到語音，請重試。"
                : "Transcript ready / 辨識完成"
        }
        Task {
            if speechSettings.activation == .wakePhrase,
               await speechCoordinator.detectWakePhrase(result.transcript) {
                speechCapture.stop()
                voiceGeneration &+= 1
                try? await startSpeechCapture(language: speechSettings.language)
                voiceStatus = "Wake phrase heard — listening"
                return
            }
            let personalized = await memoryStore.personalize(result.transcript, mode: speechSettings.mode)
            guard token == voiceGeneration else { return }
            guard let command = await speechCoordinator.consume(
                transcript: personalized,
                isFinal: result.isFinal
            ) else { return }
            guard token == voiceGeneration else { return }
            switch command {
            case .stop:
                voiceGeneration &+= 1
                isListening = false
                speechCapture.stop()
                cancelInputTask()
                onCancelResearch?()
                voiceStatus = "Stopped locally"
            case let .dictate(text):
                guard result.isFinal else { return }
                executeDesktopAction(.insertText(text))
            case let .scroll(lines):
                executeDesktopAction(.scroll(lines: lines))
            case let .openApp(bundle):
                guard bundle == inputBundleIdentifier else {
                    desktopStatus = "Open \(bundle) requires an explicit input grant for that app"
                    return
                }
                executeDesktopAction(.openApplication(bundleIdentifier: bundle))
            case let .research(query):
                if let onResearch { onResearch(query); voiceStatus = cloudStatus }
                else { voiceStatus = "Connect your cloud account before research / 請先連結雲端帳戶" }
            case .resume:
                resumeInputTask()
            case .undo:
                undoLastDesktopAction()
            case .unknown:
                guard result.isFinal else { return }
                if useManagedCommands { prepareCloudCommand(personalized); voiceStatus = cloudStatus }
                else { voiceStatus = "Speech received. Try “scroll down” or “scroll up”. Natural-language commands need cloud interpretation." }
            }
        }
    }

    private func executeDesktopAction(_ action: DesktopAction) {
        let bundle = inputBundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bundle.isEmpty, let grant = currentInputGrant, grant.expiresAt > Date(), desktopState == .ready else {
            desktopStatus = "Choose an app and grant desktop control in Tasks & history before using commands"
            voiceStatus = desktopStatus
            return
        }
        let epoch = inputEpoch.current
        Task {
            do {
                guard inputEpoch.isCurrent(epoch), currentInputGrant != nil,
                      grant.expiresAt > Date(), desktopState == .ready else { return }
                let verified = try await desktopController.execute(action, expectedBundleIdentifier: bundle)
                guard inputEpoch.isCurrent(epoch), currentInputGrant != nil else { return }
                lastVerifiedAction = verified.undoSupport == .restoreText ? verified : nil
                desktopState = await desktopController.state
                desktopStatus = "Verified \(action.kind.rawValue) for \(bundle)"
                voiceStatus = "Completed: \(action.kind.rawValue)"
            } catch {
                guard inputEpoch.isCurrent(epoch) else { return }
                desktopState = await desktopController.state
                desktopStatus = error.localizedDescription
                voiceStatus = desktopStatus
            }
        }
    }

    private func startSpeechCapture(language: SpeechLanguage) async throws {
        let token = voiceGeneration
        try await speechCapture.start(language: language, onResult: { [weak self] result in
            Task { @MainActor [weak self] in
                self?.consume(result, token: token)
            }
        }, onFailure: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.voiceGeneration == token else { return }
                self.stopVoiceSession()
                self.showsVoiceHUD = true
                self.voiceStatus = "Speech recognition stopped. Check microphone and on-device language support. / 語音辨識已停止。"
            }
        })
    }

    private func handleShortcutDown() {
        switch speechSettings.activation {
        case .pushToTalk, .toggle:
            startVoiceSession()
        case .wakePhrase:
            break
        }
    }

    private func handleShortcutUp() {
        if speechSettings.activation == .pushToTalk { finishVoiceSession() }
    }
}

struct FlowStateMenuView: View {
    @Environment(\.openSettings) private var openSettings
    @ObservedObject var model: FlowStateAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Flow State")
                    .font(.custom("Space Grotesk", size: 20, relativeTo: .headline))
                Spacer()
                Button {
                    NSApplication.shared.activate()
                    openSettings()
                } label: {
                    Image(systemName: "gearshape")
                        .accessibilityLabel("Open settings")
                }
                .buttonStyle(.plain)
            }
            Text("A voice controller for your Mac. Sessions start only when you ask.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            statusRow("Voice", detail: model.voiceStatus, icon: "waveform")
            if !model.latestTranscript.isEmpty {
                Text(model.latestTranscript).textSelection(.enabled)
                    .accessibilityLabel("Latest transcript: \(model.latestTranscript)")
            }
            Button("Start voice session") { model.startVoiceSession() }

            Button("Stop listening") { model.stopVoiceSession() }

            Divider()
            statusRow("Screen capture", detail: model.permissionStatus, icon: "lock.shield")
            HStack {
                Button("Request permission") { model.requestScreenPermission() }
                Button("Refresh") { model.refreshPermissionStatus() }
            }

            Divider()
            TextField("Approved app bundle ID", text: $model.bundleIdentifier)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Approved application bundle identifier")
            HStack {
                Button("Begin task") { model.beginTask() }
                    .disabled(model.isTaskActive)
                Button("Revoke") { model.revokeTask() }
                    .disabled(!model.isTaskActive)
            }
            Button("Capture approved window") { model.captureApprovedWindow() }
                .disabled(!model.isTaskActive)
            Text(model.taskStatus)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Divider()
            Text("Desktop control")
                .font(.system(size: 14, weight: .medium))
            TextField("Input grant target bundle ID", text: $model.inputBundleIdentifier)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Desktop input grant target bundle identifier")
            HStack {
                Button("Grant input") { model.beginInputTask() }
                Button("Cancel") { model.cancelInputTask() }
            }
            HStack {
                Button("Resume") { model.resumeInputTask() }
                Button("Undo last edit") { model.undoLastDesktopAction() }
            }
            Text(model.desktopStatus)
                .font(.system(size: 12))
                .foregroundStyle(model.desktopState == .pausedForUser ? .orange : .secondary)
        }
        .padding(18)
        .frame(width: 380)
        .background(PaperStyle.canvas)
        .preferredColorScheme(.dark)
    }

    private func statusRow(_ title: String, detail: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .frame(width: 18)
                .foregroundStyle(PaperStyle.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14, weight: .medium))
                Text(detail).font(.system(size: 12)).foregroundStyle(PaperStyle.muted)
            }
        }
    }
}

@main
struct FlowStateApp: App {
    @StateObject private var model = FlowStateAppModel()

    var body: some Scene {
        MenuBarExtra("Flow State", systemImage: "waveform") {
            FlowStateMenuView(model: model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            FlowStateSettingsView(model: model)
        }
    }
}
