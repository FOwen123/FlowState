import AppKit
import CoreGraphics
import Combine
import FlowStateCore
import FlowStateCloud
import SwiftUI

@MainActor
final class FlowStateAppModel: ObservableObject {
    @Published var useManagedCommands = UserDefaults.standard.object(forKey: "FlowState.managedCommands") as? Bool ?? true {
        didSet {
            if !useManagedCommands {
                intentTask?.cancel(); cloudSession?.cancelIntent()
                pendingIntent = nil; pendingIntentSummary = nil
            }
        }
    }
    @Published var allowCloudScreenContext = false {
        didSet {
            preferences?.set(allowCloudScreenContext, forKey: "FlowState.allowCloudScreenContext")
            if !allowCloudScreenContext {
                intentTask?.cancel()
                cloudSession?.cancelIntent()
                pendingIntent = nil; pendingIntentSummary = nil
                revokeTask()
            }
        }
    }
    private let preferences: UserDefaults?
    private let accessibilityGranted: () -> Bool
    private let frontmostApplication: () -> String?
    private var applicationActivationObserver: AnyCancellable?
    private var lastExternalApplication: String?

    private var voiceSessionID = UUID().uuidString
    private var intentTask: Task<Void, Never>?
    private var contextRevision = 0
    private var consumedUtterances = Set<UUID>()
    @Published private(set) var pendingIntentSummary: String?
    private var pendingIntent: (action: NativePlanAction, observation: DesktopObservation, epoch: UInt64, screen: CaptureObservation?)?
    @Published private(set) var executingPlan = false
    private(set) var currentInputGrant: DesktopExecutionGrant?
    private var inputEpoch = InputEpochGate()
    @Published var cloudSession: CloudSession?
    @Published private(set) var cloudStatus = "Sign in through Cloud account to use research"
    @Published private(set) var isListening = false { didSet { updateVoiceHUD() } }
    @Published private(set) var isFinishingVoice = false
    private var preparingVoice = false
    private var voiceGeneration: UInt64 = 0
    private var utteranceGeneration: UInt64 = 0
    private var captureLifecycleEpoch: UInt64 = 0
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
    @Published var settingsSection: FlowStateSettingsSection = .voice
    @Published var inputBundleIdentifier = ""
    @Published private(set) var allowedInputActions: Set<DesktopActionKind> = Set(DesktopActionKind.allCases) {
        didSet { preferences?.set(allowedInputActions.map(\.rawValue).sorted(), forKey: "FlowState.allowedInputActions") }
    }
    @Published private(set) var desktopState = DesktopAutomationState.idle
    @Published private(set) var desktopStatus = "Desktop control is idle"

    /// Root may bind this to the managed CloudSession plan cancellation method.
    var onCancelCloud: (() -> Void)?

    /// Research is cancelled only by an explicit Stop, never by an input-grant
    /// cancellation or a physical takeover.
    var onCancelResearch: (() -> Void)?

    /// Root may bind this to the managed Convex research action. It is called
    /// only for the explicit `research …` command shape.
    var onResearch: ((String) -> Void)?

    let memoryStore = ExplicitMemoryStore()
    private let controller: ScreenCaptureController
    private let desktopController: DesktopAutomationController
    private let speechCoordinator: SpeechSessionCoordinator
    private let speechCapture = AnalyzerSpeechCapture()
    private let takeoverMonitor = InputTakeoverMonitor()
    private let shortcutMonitor = GlobalVoiceShortcutMonitor()
    private let voiceHUD = VoiceHUDController()
    private var showsVoiceHUD = false
    private var grant: CaptureGrant?
    private var lastVerifiedAction: VerifiedDesktopAction?
    private var cloudPlanTarget: (id: String, observation: DesktopObservation, epoch: UInt64)?
    private var statusGeneration: UInt64 = 0

    init(desktopController: DesktopAutomationController = DesktopAutomationController(),
         accessibilityGranted: @escaping () -> Bool = { MacPermissionManager.accessibilityStatus().isGranted },
         frontmostApplication: @escaping () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier },
         speechCoordinator: SpeechSessionCoordinator = SpeechSessionCoordinator(), preferences: UserDefaults? = nil) {
        self.preferences = preferences
        self.accessibilityGranted = accessibilityGranted
        self.frontmostApplication = frontmostApplication
        self.speechCoordinator = speechCoordinator
        self.desktopController = desktopController
        controller = ScreenCaptureController()
        allowCloudScreenContext = preferences?.bool(forKey: "FlowState.allowCloudScreenContext") ?? false
        if let stored = preferences?.stringArray(forKey: "FlowState.allowedInputActions") {
            allowedInputActions = Set(stored.compactMap(DesktopActionKind.init(rawValue:)))
        }
        speechSettings = SpeechSettingsStore.load()
        if let bundle = frontmostApplication(), bundle != Bundle.main.bundleIdentifier, bundle != "com.flowstate.dev" {
            lastExternalApplication = bundle
        }
        applicationActivationObserver = NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .sink { [weak self] notification in
                let bundle = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
                Task { @MainActor [weak self] in
                    guard let bundle, bundle != Bundle.main.bundleIdentifier, bundle != "com.flowstate.dev" else { return }
                    self?.lastExternalApplication = bundle
                }
            }
        refreshPermissionStatus()
        Task { await refreshMemory() }
        if let url = Bundle.main.object(forInfoDictionaryKey: "FlowStateConvexURL") as? String,
           let key = Bundle.main.object(forInfoDictionaryKey: "FlowStateClerkPublishableKey") as? String,
           let configuration = try? CloudConfiguration(deploymentURL: url, publishableKey: key) {
            connectCloud(configuration)
        }
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
            taskStatus = "Open an app or name it in your command."
            return
        }

        statusGeneration &+= 1
        let taskGeneration = statusGeneration
        captureLifecycleEpoch &+= 1
        let captureEpoch = captureLifecycleEpoch
        Task {
            guard let nextGrant = try? await controller.beginAutomaticTask(allowedBundleIdentifiers: [bundle], lifecycleEpoch: captureEpoch) else { return }
            guard taskGeneration == statusGeneration else { return }
            grant = nextGrant
            isTaskActive = true
            taskStatus = L10n.format("Active for %@. Screenshots are taken only when requested.", L10n.appName(bundle))
        }
    }

    private func prepareAutomaticObservation(bundle: String) async -> CaptureGrant? {
        guard !Task.isCancelled, allowCloudScreenContext, MacPermissionManager.snapshot().screenRecording.isGranted else { return nil }
        let epoch = inputEpoch.current
        captureLifecycleEpoch &+= 1
        let captureEpoch = captureLifecycleEpoch
        guard let next = try? await controller.beginAutomaticTask(allowedBundleIdentifiers: [bundle], lifecycleEpoch: captureEpoch),
              captureEpoch == captureLifecycleEpoch, inputEpoch.isCurrent(epoch), allowCloudScreenContext else { return nil }
        guard !Task.isCancelled else {
            await controller.revoke(lifecycleEpoch: captureEpoch)
            return nil
        }
        bundleIdentifier = bundle
        grant = next
        isTaskActive = true
        taskStatus = L10n.format("Screen context ready for %@ when needed.", L10n.appName(bundle))
        return next
    }

    func captureGrantForCloud(bundleIdentifier: String) -> CaptureGrant? {
        guard allowCloudScreenContext, isTaskActive, let grant,
              grant.expiresAt > Date(), grant.allowedBundleIdentifiers.contains(bundleIdentifier) else { return nil }
        return grant
    }

    func revokeTask() {
        statusGeneration &+= 1
        grant = nil
        isTaskActive = false
        taskStatus = "Revoked — screen capture is off"
        captureLifecycleEpoch &+= 1
        let captureEpoch = captureLifecycleEpoch
        Task { await controller.revoke(lifecycleEpoch: captureEpoch) }
    }

    func setInputAction(_ action: DesktopActionKind, enabled: Bool) {
        if enabled { allowedInputActions.insert(action) }
        else { allowedInputActions.remove(action) }
        if currentInputGrant != nil { cancelInputTask() }
    }

    @discardableResult
    func beginInputTask(ifCurrent: @escaping () -> Bool = { true }) -> Task<Void, Never>? {
        let bundle = inputBundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bundle.isEmpty else {
            desktopStatus = "Open an app or name it in your command."
            return nil
        }
        guard !allowedInputActions.isEmpty else {
            desktopStatus = "Choose at least one desktop action"
            return nil
        }
        let epoch = inputEpoch.advance()
        currentInputGrant = nil
        lastVerifiedAction = nil
        takeoverMonitor.stop()
        statusGeneration &+= 1
        let inputGrant = DesktopExecutionGrant(
            allowedBundleIdentifiers: [bundle],
            allowedActions: allowedInputActions,
            generation: epoch,
            expiresAt: Date().addingTimeInterval(CaptureGrant.defaultDuration)
        )
        return Task { [weak self] in
            guard let self else { return }
            do {
                guard inputEpoch.isCurrent(epoch), ifCurrent() else { return }
                await desktopController.cancel(lifecycleEpoch: epoch)
                guard inputEpoch.isCurrent(epoch), ifCurrent() else { return }
                try await desktopController.begin(grant: inputGrant, lifecycleEpoch: epoch)
                guard inputEpoch.isCurrent(epoch), ifCurrent() else {
                    await desktopController.cancel(lifecycleEpoch: epoch)
                    return
                }
                let readyState = await desktopController.state
                guard inputEpoch.isCurrent(epoch), ifCurrent() else {
                    await desktopController.cancel(lifecycleEpoch: epoch)
                    return
                }
                currentInputGrant = inputGrant
                desktopState = readyState
                desktopStatus = L10n.format("Control allowed for %@. Using your mouse or keyboard pauses actions.", L10n.appName(bundle))
                installTakeoverMonitor(for: epoch)
            } catch {
                guard inputEpoch.isCurrent(epoch), ifCurrent() else { return }
                currentInputGrant = nil
                lastVerifiedAction = nil
                takeoverMonitor.stop()
                desktopState = await desktopController.state
                desktopStatus = error.localizedDescription
            }
        }
    }

    private var activeCommandApplication: String? {
        let foreground = frontmostApplication()
        if let foreground, foreground != Bundle.main.bundleIdentifier, foreground != "com.flowstate.dev" { return foreground }
        return lastExternalApplication
    }

    /// Called only for a new finalized user command, never by a late model response.
    func prepareAutomaticTarget(for command: VoiceCommand, activeBundleIdentifier: String?, utteranceToken: UInt64? = nil) async throws -> DesktopObservation? {
        switch command {
        case .stop, .resume, .undo, .research: return nil
        default: break
        }
        guard accessibilityGranted() else { throw DesktopExecutionError.accessibilityDenied }
        guard !allowedInputActions.isEmpty else { throw DesktopExecutionError.nativeFailure("Desktop controls are turned off. Enable a control in Settings.") }
        let entryEpoch = inputEpoch.current
        let actualState = await desktopController.state
        guard !Task.isCancelled, inputEpoch.isCurrent(entryEpoch), utteranceToken == nil || utteranceToken == utteranceGeneration else { throw DesktopExecutionError.staleGeneration }
        desktopState = actualState
        guard desktopState != .reconciliationRequired else { throw DesktopExecutionError.reconciliationRequired }
        guard desktopState != .running else { throw DesktopExecutionError.nativeFailure("An action is still running. Wait for it to finish.") }
        let target: String
        if case .openApp(let bundle) = command { target = bundle }
        else if let activeBundleIdentifier, !activeBundleIdentifier.isEmpty { target = activeBundleIdentifier }
        else { throw DesktopExecutionError.nativeFailure("Open an app or name the app you want to control.") }
        // A new utterance supersedes older inference, even in the same app.
        inputBundleIdentifier = target
        await beginInputTask(ifCurrent: { [weak self] in
            guard let self else { return false }
            return utteranceToken == nil || utteranceToken == self.utteranceGeneration
        })?.value
        guard let grant = currentInputGrant, grant.expiresAt > Date(), grant.allowedBundleIdentifiers.contains(target), desktopState == .ready else {
            throw DesktopExecutionError.staleGeneration
        }
        if case .openApp = command { return nil }
        let observation = try await desktopController.observeCurrent()
        guard observation.bundleIdentifier == target else { throw DesktopExecutionError.targetChanged }
        return observation
    }

    func cancelInputTask() {
        cloudPlanTarget = nil
        pendingIntent = nil; pendingIntentSummary = nil
        intentTask?.cancel()
        cloudSession?.cancelIntent()
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
        pendingIntent = nil; pendingIntentSummary = nil
        intentTask?.cancel()
        cloudSession?.cancelIntent()
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
        cloudPlanTarget = nil
        pendingIntent = nil; pendingIntentSummary = nil
        intentTask?.cancel()
        cloudSession?.cancelIntent()
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
            desktopStatus = "Repeat your command to start a new control session."
            voiceStatus = desktopStatus
            return
        }
        Task {
            do {
                _ = try await desktopController.resume()
                guard inputEpoch.isCurrent(epoch), currentInputGrant != nil,
                      grant.expiresAt > Date() else { return }
                installTakeoverMonitor(for: epoch)
                desktopState = await desktopController.state
                desktopStatus = "Desktop control resumed. Repeat your command."
                voiceStatus = desktopStatus
            } catch {
                guard inputEpoch.isCurrent(epoch) else { return }
                desktopStatus = error.localizedDescription
                voiceStatus = desktopStatus
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
                taskStatus = L10n.format("Screenshot captured (%d × %d).", frame.image.width, frame.image.height)
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
            guard session.signedIn else { self.cloudStatus = "Sign in before research"; return }
            self.cloudStatus = "Researching public sources"
            Task {
                do { try await session.research(query: query); self.cloudStatus = "Research ready in Cloud account" }
                catch { self.cloudStatus = "Research stopped. Check the connection and sign-in." }
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
        guard let cloudSession, cloudSession.signedIn else { cloudStatus = "Sign in before managed commands"; return }
        cloudStatus = "Preparing a plan for review"
        cloudPlanTarget = nil
        let active = activeCommandApplication
        Task {
            do {
                let prepared = try await prepareAutomaticTarget(for: VoiceCommandRouter.resolve(command, mode: .auto), activeBundleIdentifier: active)
                let observation: DesktopObservation
                if let prepared { observation = prepared } else { observation = try await desktopController.observeCurrent() }
                let target = inputBundleIdentifier
                let epoch = inputEpoch.current
                try await cloudSession.preparePlan(command:command,targetBundleIdentifier:target,locale:"en")
                guard inputEpoch.isCurrent(epoch), let proposal = cloudSession.proposal else { return }
                cloudPlanTarget = (proposal.id, observation, epoch)
                cloudStatus = "Review the proposed actions in Cloud account"
            }
            catch { cloudStatus = "This request needs clarification or could not be planned." }
        }
    }

    func executeCloudPlan(_ plan: CloudProposal) {
        guard !executingPlan, let session = cloudSession, let grant = currentInputGrant, grant.expiresAt > Date(), let target = grant.allowedBundleIdentifiers.first else { cloudStatus = "Repeat your command to start a new control session."; return }
        guard let prepared = cloudPlanTarget, prepared.id == plan.id, inputEpoch.isCurrent(prepared.epoch) else {
            cloudStatus = "The prepared target is no longer current. Please make a new request."
            return
        }
        executingPlan = true
        let epoch = inputEpoch.current
        Task {
            var reserved: Int?
            var expectedObservation = prepared.observation
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
                    let (result, nextObservation) = try await executePlanStep(action, expectedObservation: expectedObservation)
                    expectedObservation = nextObservation
                    guard inputEpoch.isCurrent(epoch), session.isCurrent(plan) else { throw CancellationError() }
                    lastVerifiedAction = result.undoSupport == .restoreText ? result : nil
                    try await session.finishStep(plan,ordinal:index,verified:true)
                    reserved = nil
                }
                cloudStatus = "Plan completed"
            } catch {
                if let reserved { try? await session.finishStep(plan,ordinal:reserved,verified:false) }
                await session.cancelPlan()
                cloudStatus = "Plan stopped. Check the last action before trying again."
            }
            desktopState = await desktopController.state
        }
    }

    func executePlanStep(_ action: NativePlanAction, expectedObservation: DesktopObservation) async throws -> (VerifiedDesktopAction, DesktopObservation) {
        let result = try await desktopController.execute(action.desktopAction,
            expectedBundleIdentifier: action.targetBundleIdentifier,
            expectedObservation: action.kind == .openApplication ? nil : expectedObservation)
        let nextObservation = try await desktopController.observeCurrent()
        return (result, nextObservation)
    }

    private func updateVoiceHUD() {
        guard showsVoiceHUD else { return }
        voiceHUD.show(status: voiceStatus, transcript: latestTranscript, isListening: isListening,
            onStop: { [weak self] in self?.stopVoiceSession() },
            onConfirm: pendingIntent == nil ? nil : { [weak self] in self?.confirmPendingIntent() },
            onSettings: { [weak self] in
                guard let self else { return }
                self.settingsSection = self.accessibilityGranted() ? .tasks : .permissions
            })
    }

    func startVoiceSession() {
        guard !isFinishingVoice else { return }
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
        voiceSessionID = UUID().uuidString
        consumedUtterances.removeAll()
        pendingIntent = nil; pendingIntentSummary = nil
        intentTask?.cancel()
        cloudSession?.cancelIntent()
        preparingVoice = true
        isListening = true
        voiceStatus = "Preparing on-device speech"
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
                    ? L10n.format("Listening for %@", currentSettings.wakePhrase)
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
            voiceStatus = "Released before speech was ready. Hold again."
            return
        }
        isFinishingVoice = true
        speechCapture.finish()
        Task { await speechCoordinator.finish() }
        voiceStatus = "Finishing transcription"
    }

    func stopVoiceSession() {
        showsVoiceHUD = false
        isFinishingVoice = false
        voiceHUD.hide()
        voiceGeneration &+= 1
        preparingVoice = false
        isListening = false
        speechCapture.stop()
        cancelInputTask()
        revokeTask()
        onCancelResearch?()
        let token = voiceGeneration
        Task {
            await speechCoordinator.localStop()
            guard token == voiceGeneration else { return }
            voiceStatus = "Voice session stopped locally"
        }
    }

    func installSpeechLanguage() {
        voiceStatus = "Downloading Apple’s English speech model…"
        let language = speechSettings.language
        Task {
            do { try await AnalyzerSpeechCapture.installLanguage(language); voiceStatus = "English speech model ready" }
            catch { voiceStatus = "Could not download the English speech model. Check your internet connection and try again." }
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

    func consume(_ result: SpeechRecognitionResult, token: UInt64) {
        guard token == voiceGeneration else { return }
        if !result.transcript.isEmpty || !result.sessionEnded { latestTranscript = result.transcript }
        if result.sessionEnded {
            isFinishingVoice = false
            isListening = false
            voiceStatus = latestTranscript.isEmpty
                ? "No speech detected. Try again."
                : "Voice session finished"
        }
        if result.isFinal, let id = result.utteranceID, !consumedUtterances.insert(id).inserted { return }
        if result.isFinal, pendingIntent != nil,
           result.transcript.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).lowercased() == "confirm" {
            confirmPendingIntent()
            return
        }
        if result.isFinal { utteranceGeneration &+= 1 }
        let utteranceToken = utteranceGeneration
        let activeAtArrival = activeCommandApplication
        if result.isFinal {
            intentTask?.cancel(); cloudSession?.cancelIntent()
            pendingIntent = nil; pendingIntentSummary = nil
        }
        Task {
            guard token == voiceGeneration, utteranceToken == utteranceGeneration else { return }
            if speechSettings.activation == .wakePhrase {
                let woke = await speechCoordinator.detectWakePhrase(result.transcript)
                guard token == voiceGeneration, utteranceToken == utteranceGeneration else { return }
                if woke {
                    let wasCapturing = isListening && !result.sessionEnded
                    speechCapture.stop()
                    voiceGeneration &+= 1
                    if wasCapturing { try? await startSpeechCapture(language: speechSettings.language) }
                    voiceStatus = "Wake phrase heard — listening"
                    return
                }
                if await speechCoordinator.phase == .idle { return }
                guard token == voiceGeneration, utteranceToken == utteranceGeneration else { return }
            }
            var arrivalObservation: DesktopObservation?
            if result.isFinal, !result.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                do {
                    let rawCommand = VoiceCommandRouter.resolve(result.transcript, mode: speechSettings.mode)
                    arrivalObservation = try await prepareAutomaticTarget(for: rawCommand, activeBundleIdentifier: activeAtArrival, utteranceToken: utteranceToken)
                } catch {
                    guard token == voiceGeneration, utteranceToken == utteranceGeneration else { return }
                    voiceStatus = error.localizedDescription
                    return
                }
            }
            let personalized = await memoryStore.personalize(result.transcript, mode: speechSettings.mode)
            guard token == voiceGeneration, utteranceToken == utteranceGeneration else { return }
            guard let command = await speechCoordinator.consume(
                transcript: personalized,
                isFinal: result.isFinal,
                sessionEnded: result.sessionEnded,
                utteranceID: result.utteranceID
            ) else { return }
            guard token == voiceGeneration, utteranceToken == utteranceGeneration else { return }
            if result.isFinal, command != .unknown {
                intentTask?.cancel(); cloudSession?.cancelIntent()
                pendingIntent = nil; pendingIntentSummary = nil
            }
            switch command {
            case .stop:
                voiceGeneration &+= 1
                isListening = false
                speechCapture.stop()
                cancelInputTask()
                revokeTask()
                onCancelResearch?()
                voiceStatus = "Stopped locally"
            case let .dictate(text):
                guard result.isFinal else { return }
                executeDesktopAction(.insertText(text), expectedObservation: arrivalObservation)
            case let .scroll(lines):
                executeDesktopAction(.scroll(lines: lines), expectedObservation: arrivalObservation)
            case let .openApp(bundle):
                if inputBundleIdentifier != bundle {
                    do { _ = try await prepareAutomaticTarget(for: command, activeBundleIdentifier: activeAtArrival, utteranceToken: utteranceToken) }
                    catch { voiceStatus = error.localizedDescription; return }
                }
                guard token == voiceGeneration, utteranceToken == utteranceGeneration else { return }
                executeDesktopAction(.openApplication(bundleIdentifier: bundle))
            case let .focus(role, label):
                executeDesktopAction(.focus(role: role, label: label), expectedObservation: arrivalObservation)
            case let .select(label):
                executeDesktopAction(.select(label: label), expectedObservation: arrivalObservation)
            case let .press(key, modifiers):
                if key == "Enter" || modifiers != nil {
                    prepareLocalKeyConfirmation(key: key, modifiers: modifiers, expectedObservation: arrivalObservation)
                } else {
                    executeDesktopAction(.press(key: key, modifiers: modifiers), expectedObservation: arrivalObservation)
                }
            case let .research(query):
                if let onResearch { onResearch(query); voiceStatus = cloudStatus }
                else { voiceStatus = "Connect your cloud account before research" }
            case .resume:
                resumeInputTask()
            case .undo:
                undoLastDesktopAction()
            case .unknown:
                guard result.isFinal else { return }
                if shouldInterpret(command) { resolveManagedUtterance(personalized, utteranceID: result.utteranceID ?? UUID(), token: token, originalObservation: arrivalObservation) }
                else { voiceStatus = "I could not match that request. Turn on cloud interpretation for natural-language controls." }
            }
        }
    }

    func shouldInterpret(_ command: VoiceCommand) -> Bool {
        useManagedCommands && command == .unknown && speechSettings.mode != .dictation
    }

    private func resolveManagedUtterance(_ transcript: String, utteranceID: UUID, token: UInt64, originalObservation: DesktopObservation?) {
        guard let session = cloudSession, session.signedIn else {
            voiceStatus = "Sign in to use Auto interpretation, or choose Commands only for local controls."
            return
        }
        pendingIntent = nil; pendingIntentSummary = nil
        let previous = intentTask
        let sessionID = voiceSessionID
        let epoch = inputEpoch.current
        intentTask = Task { [weak self] in
            guard let self, !Task.isCancelled, token == voiceGeneration, inputEpoch.isCurrent(epoch) else { return }
            do {
                guard let observation = originalObservation else { throw DesktopExecutionError.targetChanged }
                await previous?.value
                guard !Task.isCancelled, token == voiceGeneration, inputEpoch.isCurrent(epoch) else { return }
                guard !observation.isSecure else {
                    voiceStatus = "Use system autofill for protected fields."
                    return
                }
                contextRevision += 1
                var revision = contextRevision
                guard let inputGrant = currentInputGrant, inputGrant.expiresAt > Date(), desktopState == .ready else {
                    voiceStatus = "The active app changed. Repeat your command."
                    return
                }
                let apps = ApplicationCatalog.installed().sorted {
                    let left = inputGrant.allowedBundleIdentifiers.contains($0.bundleIdentifier) || $0.bundleIdentifier == observation.bundleIdentifier
                    let right = inputGrant.allowedBundleIdentifiers.contains($1.bundleIdentifier) || $1.bundleIdentifier == observation.bundleIdentifier
                    return left != right ? left : $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
                var candidates = apps.prefix(99).map {
                    CloudIntentCandidate(id: "app:" + $0.bundleIdentifier, label: $0.name,
                        bundleIdentifier: $0.bundleIdentifier, kind: "app")
                }
                if let element = observation.focusedElementID {
                    candidates.append(CloudIntentCandidate(id: element,
                        label: observation.focusedLabel ?? "Focused control", bundleIdentifier: observation.bundleIdentifier, kind: "control"))
                }
                let routingGrant = DesktopExecutionGrant(
                    allowedBundleIdentifiers: Set(candidates.compactMap(\.bundleIdentifier)).union([observation.bundleIdentifier]),
                    allowedActions: inputGrant.allowedActions, generation: inputGrant.generation, expiresAt: inputGrant.expiresAt)
                try await desktopController.begin(grant: routingGrant, lifecycleEpoch: epoch)
                guard !Task.isCancelled, inputEpoch.isCurrent(epoch) else { return }
                currentInputGrant = routingGrant
                let context = CloudIntentContext(focusedAppBundleIdentifier: observation.bundleIdentifier,
                    focusedRole: observation.focusedRole, editable: observation.isEditable, targetCandidates: candidates)
                voiceStatus = "Understanding your request…"
                let captureGrant = await prepareAutomaticObservation(bundle: observation.bundleIdentifier)
                var screenObservation: CaptureObservation?
                var decision = try await session.routeIntent(utterance: transcript, sessionID: sessionID,
                    utteranceID: utteranceID.uuidString, contextRevision: revision,
                    mode: speechSettings.mode.rawValue == "command" ? "commands" : speechSettings.mode.rawValue,
                    context: context, grant: currentInputGrant, observationAllowedUntil: captureGrant?.expiresAt)
                guard !Task.isCancelled, token == voiceGeneration, inputEpoch.isCurrent(epoch),
                      sessionID == voiceSessionID, revision == contextRevision else { return }
                if decision.requiresObservation {
                    guard let captureGrant, captureGrantForCloud(bundleIdentifier: observation.bundleIdentifier) == captureGrant else {
                        voiceStatus = "Enable screen context in Settings and allow Screen Recording to use visual commands."
                        return
                    }
                    voiceStatus = "Looking at the approved window…"
                    let frame = try await controller.capture(bundleIdentifier: observation.bundleIdentifier, grant: captureGrant)
                    try await controller.revalidate(frame.observation, grant: captureGrant, forUpload: true)
                    guard !Task.isCancelled, token == voiceGeneration, inputEpoch.isCurrent(epoch),
                          captureGrantForCloud(bundleIdentifier: observation.bundleIdentifier) == captureGrant else { throw CancellationError() }
                    screenObservation = frame.observation
                    let bounds = frame.observation.windowFrame
                    let cloudImage = CloudIntentObservation(id: frame.observation.id.uuidString,
                        displayId: String(frame.observation.displayID), windowId: String(frame.observation.windowID),
                        observedAt: frame.observation.capturedAt.timeIntervalSince1970 * 1000,
                        geometry: .init(x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height, scale: frame.observation.scale),
                        imageDataUrl: try frame.pngDataURL(uploadApproved: true))
                    contextRevision += 1; revision = contextRevision
                    decision = try await session.routeIntent(utterance: transcript, sessionID: sessionID,
                        utteranceID: utteranceID.uuidString, contextRevision: revision,
                        mode: speechSettings.mode == .command ? "commands" : speechSettings.mode.rawValue,
                        context: context, grant: currentInputGrant, observation: cloudImage,
                        observationAllowedUntil: captureGrant.expiresAt)
                    guard !Task.isCancelled, token == voiceGeneration, inputEpoch.isCurrent(epoch),
                          sessionID == voiceSessionID, revision == contextRevision else { throw CancellationError() }
                    try await revalidateScreen(frame.observation)

                }
                guard decision.decision == .execute || decision.decision == .dictation,
                      let action = decision.action?.nativePlanAction else {
                    voiceStatus = decision.clarification ?? "Please clarify what you want Flow State to do."
                    return
                }
                if action.requiresApproval {
                    pendingIntent = (action, observation, epoch, screenObservation)
                    pendingIntentSummary = L10n.planSummary(action.parameters, appName: L10n.appName(action.targetBundleIdentifier))
                    voiceStatus = "Confirm: " + (pendingIntentSummary ?? "this action") + ". Say confirm or cancel."
                    return
                }
                try await executeResolvedIntent(action, observation: observation, epoch: epoch, screen: screenObservation)
            } catch is CancellationError {
                // A newer session, Stop, or physical takeover owns the UI now.
            } catch {
                guard !Task.isCancelled, token == voiceGeneration, inputEpoch.isCurrent(epoch) else { return }
                desktopState = await desktopController.state
                voiceStatus = (error as? DesktopExecutionError)?.localizedDescription
                    ?? (error as? CaptureError)?.localizedDescription
                    ?? "This request could not be completed. Check your connection, permissions, and target app."
            }
        }
    }

    func prepareLocalKeyConfirmation(key: String, modifiers: String?, expectedObservation: DesktopObservation? = nil) {
        guard desktopState == .ready, let grant = currentInputGrant, grant.expiresAt > Date() else {
            voiceStatus = blockedControlMessage
            return
        }
        let epoch = inputEpoch.current
        intentTask = Task {
            do {
                let observation: DesktopObservation
                if let expectedObservation { observation = expectedObservation }
                else { observation = try await desktopController.observeCurrent() }
                guard !Task.isCancelled, inputEpoch.isCurrent(epoch), let grant = currentInputGrant,
                      grant.allowedBundleIdentifiers.contains(observation.bundleIdentifier), !observation.isSecure else { return }
                let action = NativePlanAction(kind: .press, targetBundleIdentifier: observation.bundleIdentifier,
                    parameters: .press(key: key, modifiers: modifiers), capability: "app.input", requiresApproval: true)
                pendingIntent = (action, observation, epoch, nil)
                pendingIntentSummary = "Press " + key + " in " + L10n.appName(observation.bundleIdentifier)
                voiceStatus = "Confirm this keyboard shortcut. Say confirm or cancel."
            } catch {
                guard !Task.isCancelled, inputEpoch.isCurrent(epoch) else { return }
                voiceStatus = error.localizedDescription
            }
        }
    }

    func confirmPendingIntent() {
        guard let pending = pendingIntent else { return }
        pendingIntent = nil; pendingIntentSummary = nil
        intentTask = Task {
            do { try await executeResolvedIntent(pending.action, observation: pending.observation, epoch: pending.epoch, screen: pending.screen, approved: true) }
            catch {
                if inputEpoch.isCurrent(pending.epoch) {
                    desktopState = await desktopController.state
                    voiceStatus = error.localizedDescription
                }
            }
        }
    }

    private func revalidateScreen(_ screen: CaptureObservation) async throws {
        guard let captureGrant = captureGrantForCloud(bundleIdentifier: screen.bundleIdentifier),
              Date().timeIntervalSince(screen.capturedAt) <= 30 else { throw CaptureError.staleObservation }
        try await controller.revalidate(screen, grant: captureGrant, forUpload: true)
        guard captureGrantForCloud(bundleIdentifier: screen.bundleIdentifier) == captureGrant else { throw CaptureError.staleGeneration }
    }

    func executeResolvedIntent(_ action: NativePlanAction, observation: DesktopObservation, epoch: UInt64, screen: CaptureObservation? = nil, approved: Bool = false) async throws {
        guard !action.requiresApproval || approved else { throw DesktopExecutionError.actionNotGranted }
        if let screen { try await revalidateScreen(screen) }
        guard !Task.isCancelled, inputEpoch.isCurrent(epoch), let grant = currentInputGrant,
              grant.expiresAt > Date(), grant.allows(action.desktopAction, bundleIdentifier: action.targetBundleIdentifier),
              desktopState == .ready else { throw DesktopExecutionError.actionNotGranted }
        voiceStatus = L10n.planSummary(action.parameters, appName: L10n.appName(action.targetBundleIdentifier))
        let verified = try await desktopController.execute(action.desktopAction,
            expectedBundleIdentifier: action.targetBundleIdentifier,
            expectedObservation: action.kind == .openApplication ? nil : observation)
        guard !Task.isCancelled, inputEpoch.isCurrent(epoch) else { throw CancellationError() }
        lastVerifiedAction = verified.undoSupport == .restoreText ? verified : nil
        desktopState = await desktopController.state
        desktopStatus = "Completed: " + L10n.actionName(action.desktopAction.kind)
        voiceStatus = desktopStatus
    }

    private var blockedControlMessage: String {
        switch desktopState {
        case .pausedForUser:
            return "Paused after mouse or keyboard input. Say Resume, then repeat your command."
        case .reconciliationRequired:
            return "Check the last action's result, then choose I've checked the result in Tasks & history."
        case .running:
            return "An action is still running. Wait for it to finish."
        default:
            return accessibilityGranted() ? "Repeat your command to use the active app automatically." : "Allow Accessibility in Settings, then repeat your command."
    }
    }

    func executeDesktopAction(_ action: DesktopAction, expectedObservation: DesktopObservation? = nil) {
        let bundle = inputBundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bundle.isEmpty, let grant = currentInputGrant, grant.expiresAt > Date(), desktopState == .ready else {
            desktopStatus = blockedControlMessage
            voiceStatus = desktopStatus
            return
        }
        if action.kind == .insertText, expectedObservation == nil {
            voiceStatus = "The original text field is unavailable. Focus it and repeat your dictation."
            return
        }
        let epoch = inputEpoch.current
        Task {
            do {
                guard inputEpoch.isCurrent(epoch), currentInputGrant != nil,
                      grant.expiresAt > Date(), desktopState == .ready else { return }
                let verified = try await desktopController.execute(action, expectedBundleIdentifier: bundle, expectedObservation: expectedObservation)
                guard inputEpoch.isCurrent(epoch), currentInputGrant != nil else { return }
                lastVerifiedAction = verified.undoSupport == .restoreText ? verified : nil
                desktopState = await desktopController.state
                desktopStatus = L10n.format("Completed %@ in %@.", L10n.actionName(action.kind), L10n.appName(bundle))
                voiceStatus = L10n.format("Completed: %@", L10n.actionName(action.kind))
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
                self.voiceStatus = "Speech recognition stopped. Check microphone and on-device language support."
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
        VStack(spacing: 4) {
            Button {
                if model.isListening || model.isFinishingVoice { model.stopVoiceSession() }
                else { model.startVoiceSession() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: model.isListening || model.isFinishingVoice ? "stop" : "play")
                        .font(.system(size: 12))
                        .frame(width: 14)
                    Text(model.isListening || model.isFinishingVoice ? "Stop session" : "Start session")
                    Spacer()
                }
            }
            .accessibilityLabel(model.isListening || model.isFinishingVoice ? "Stop voice session" : "Start voice session")
            Divider().overlay(Color.white.opacity(0.12))
            Button("Settings…") {
                NSApplication.shared.activate()
                openSettings()
            }
            .accessibilityLabel("Open settings")
            Divider().overlay(Color.white.opacity(0.12))
            Button("Quit Flow State") {
                model.stopVoiceSession()
                NSApplication.shared.terminate(nil)
            }
        }
        .buttonStyle(FlowStateMenuRowStyle())
        .padding(6)
        .frame(width: 280)
        .glassEffect(.regular.tint(PaperStyle.hud), in: .rect(cornerRadius: 12))
        .preferredColorScheme(.dark)
    }
}

private struct FlowStateMenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration)
    }

    private struct Row: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false
        var body: some View {
            configuration.label
                .font(.custom("Helvetica Neue", size: 14))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .frame(height: 32)
                .foregroundStyle(hovering || configuration.isPressed ? PaperStyle.accent : .white)
                .background(hovering || configuration.isPressed ? PaperStyle.selected : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

@main
struct FlowStateApp: App {
    @StateObject private var model = FlowStateAppModel(preferences: .standard)

    var body: some Scene {
        MenuBarExtra {
            FlowStateMenuView(model: model)
        } label: {
            Image(nsImage: FlowStateBrandMark.menuBarImage)
                .accessibilityLabel("Flow State")
        }
        .menuBarExtraStyle(.window)

        Settings {
            FlowStateSettingsView(model: model)
        }
        .defaultSize(width: 960, height: 680)
    }
}
