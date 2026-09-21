import AppKit
import CoreGraphics
import Combine
import FlowStateCore
import FlowStateCloud
import SwiftUI

struct ExternalEffectRecovery: Codable, Hashable, Identifiable, Sendable {
    let planID: String
    let ordinal: Int
    let receiptID: String
    let summary: String
    let operationFingerprint: String

    var id: String { receiptID }
}

func makeExternalEffectRecovery(
    plan: CloudProposal,
    ordinal: Int,
    reservation: CloudSession.ExternalEffectReservation,
    summary: String
) -> ExternalEffectRecovery {
    ExternalEffectRecovery(
        planID: plan.id,
        ordinal: ordinal,
        receiptID: reservation.receiptID,
        summary: summary,
        operationFingerprint: externalEffectOperationFingerprint(action: plan.actions[ordinal])
    )
}

@discardableResult
func persistExternalEffectRecoveryBeforeLaunch(
    plan: CloudProposal,
    ordinal: Int,
    reservation: CloudSession.ExternalEffectReservation,
    summary: String,
    store: ExternalEffectRecoveryStore
) -> ExternalEffectRecovery {
    let recovery = makeExternalEffectRecovery(
        plan: plan,
        ordinal: ordinal,
        reservation: reservation,
        summary: summary
    )
    store.upsert(recovery)
    return recovery
}

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
    private var controlProcessingTask: Task<Void, Never>?
    private var cloudPreparationTask: Task<Void, Never>?
    private var cloudPreparationGeneration: UInt64 = 0
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
    @Published private(set) var listeningPurpose: SpeechSessionPurpose? { didSet { updateVoiceHUD() } }
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
    @Published private(set) var dictationRecovery: DictationRecoveryCard?
    @Published private(set) var dictationHistory: [DictationHistoryEntry] = []
    @Published private(set) var controlHistory: [ControlHistoryEntry] = []
    @Published private(set) var spokenVoiceIdentifier: String?
    @Published private(set) var spokenResponsesMuted = false
    @Published private(set) var lastSpokenResponse: String?
    @Published private(set) var currentPlanStep: String? { didSet { updateVoiceHUD() } }
    @Published private(set) var pendingExternalEffectRecovery: ExternalEffectRecovery? { didSet { updateVoiceHUD() } }
    @Published private(set) var unresolvedExternalEffectRecoveries: [ExternalEffectRecovery] = [] { didSet { updateVoiceHUD() } }
    @Published private(set) var dictationCleanupEnabled = true
    @Published private(set) var dictationCleanupInstructions = ""
    @Published private(set) var dictationRetentionDays = 30.0
    @Published private(set) var controlRetentionDays = 30.0
    @Published private(set) var isTaskActive = false
    @Published private(set) var memorySnapshot = MemorySnapshot(preferences: [], syncEnabled: false, learningEnabled: false)
    @Published var settingsSection: FlowStateSettingsSection = .voice
    @Published var inputBundleIdentifier = ""
    @Published private(set) var allowedInputActions: Set<DesktopActionKind> = Set(DesktopActionKind.allCases) {
        didSet { preferences?.set(allowedInputActions.map(\.rawValue).sorted(), forKey: "FlowState.allowedInputActions") }
    }
    @Published private(set) var desktopState = DesktopAutomationState.idle
    @Published private(set) var desktopStatus = "Desktop control is idle"

    var externalEffectRecovery: ExternalEffectRecovery? {
        externalEffectRecoveries.first
    }

    var externalEffectRecoveries: [ExternalEffectRecovery] {
        var recoveries = unresolvedExternalEffectRecoveries
        if let pending = pendingExternalEffectRecovery,
           !recoveries.contains(where: { $0.receiptID == pending.receiptID }) {
            recoveries.insert(pending, at: 0)
        }
        return recoveries
    }

    /// Root may bind this to the managed CloudSession plan cancellation method.
    var onCancelCloud: (() -> Void)?

    /// Research is cancelled only by an explicit Stop, never by an input-grant
    /// cancellation or a physical takeover.
    var onCancelResearch: (() -> Void)?

    /// Root may bind this to the managed Convex research action. It is called
    /// only for the explicit `research …` command shape.
    var onResearch: ((String) -> Void)?

    let memoryStore = ExplicitMemoryStore()
    private let controlConversation = ControlConversationSession()
    private let controller: ScreenCaptureController
    private let desktopController: DesktopAutomationController
    private let speechCoordinator: SpeechSessionCoordinator
    private let speechCapture = AnalyzerSpeechCapture()
    private let dictationTargetObserver: any DictationTargetObserver
    private let dictationOutputController: DictationOutputController
    private let dictationHistoryStore: DictationHistoryStore
    private var managedDictationCleanupClient: (any ManagedDictationCleanupClient)?
    private let spokenResponseController: SpokenResponseController
    private let controlHistoryStore: ControlHistoryStore
    private let externalEffectRecoveryStore: ExternalEffectRecoveryStore
    private let structuredControlExecutor: StructuredControlExecutor
    private let structuredControlGeneration = StructuredControlGeneration()
    private let takeoverMonitor = InputTakeoverMonitor()
    private let dictationShortcutMonitor = GlobalVoiceShortcutMonitor()
    private let controlShortcutMonitor = GlobalVoiceShortcutMonitor()
    private let voiceHUD = VoiceHUDController()
    private var showsVoiceHUD = false
    private var activeSpeechPurpose: SpeechSessionPurpose?
    private var activeControlConversationToken: ControlConversationToken?
    private var dictationTarget: DictationTarget?
    private var dictationPendingText = ""
    private var dictationGeneration: UInt64 = 0
    private var dictationInsertionTask: Task<Void, Never>?
    private var dictationRecoveryExpiryTask: Task<Void, Never>?
    private var grant: CaptureGrant?
    private var lastVerifiedAction: VerifiedDesktopAction?
    private var cloudPlanTarget: (id: String, observation: DesktopObservation, epoch: UInt64)?
    private var cloudPlanRegistrySnapshot = Set<String>()
    private var cloudExecutionStartedPlanID: String?
    private var cloudNextPlanStep = 0
    @Published private(set) var pendingCloudApprovalStep: Int? { didSet { updateVoiceHUD() } }
    private struct PendingExternalEffect {
        let plan: CloudProposal
        let ordinal: Int
        let reservation: CloudSession.ExternalEffectReservation
        let epoch: UInt64
    }
    private var pendingExternalEffect: PendingExternalEffect?
    private var statusGeneration: UInt64 = 0

    init(desktopController: DesktopAutomationController = DesktopAutomationController(),
         accessibilityGranted: @escaping () -> Bool = { MacPermissionManager.accessibilityStatus().isGranted },
         frontmostApplication: @escaping () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier },
         speechCoordinator: SpeechSessionCoordinator = SpeechSessionCoordinator(), preferences: UserDefaults? = nil,
         dictationTargetObserver: (any DictationTargetObserver)? = nil,
         dictationOutputController: DictationOutputController? = nil,
         dictationHistoryStore: DictationHistoryStore? = nil,
         managedDictationCleanupClient: (any ManagedDictationCleanupClient)? = nil,
         spokenResponseController: SpokenResponseController? = nil,
         controlHistoryStore: ControlHistoryStore? = nil,
         structuredControlExecutor: StructuredControlExecutor? = nil) {
        self.preferences = preferences
        let recoveryStore = ExternalEffectRecoveryStore(defaults: preferences ?? .standard)
        self.externalEffectRecoveryStore = recoveryStore
        self.unresolvedExternalEffectRecoveries = recoveryStore.list()
        self.accessibilityGranted = accessibilityGranted
        self.frontmostApplication = frontmostApplication
        self.speechCoordinator = speechCoordinator
        self.desktopController = desktopController
        let sharedDictationObserver = dictationTargetObserver ?? AXDesktopDriver()
        self.dictationTargetObserver = sharedDictationObserver
        self.dictationOutputController = dictationOutputController ?? DictationOutputController(observer: sharedDictationObserver)
        let configuredDictationRetention = Self.retentionDays(defaults: preferences, key: "FlowState.dictationRetentionDays")
        let configuredControlRetention = Self.retentionDays(defaults: preferences, key: "FlowState.controlRetentionDays")
        self.dictationHistoryStore = dictationHistoryStore ?? DictationHistoryStore(
            defaults: preferences ?? .standard,
            retention: configuredDictationRetention * 24 * 60 * 60
        )
        self.managedDictationCleanupClient = managedDictationCleanupClient
        self.spokenResponseController = spokenResponseController ?? SpokenResponseController()
        self.controlHistoryStore = controlHistoryStore ?? ControlHistoryStore(
            defaults: preferences ?? .standard,
            retention: configuredControlRetention * 24 * 60 * 60
        )
        self.structuredControlExecutor = structuredControlExecutor ?? .system()
        self.spokenVoiceIdentifier = preferences?.string(forKey: "FlowState.spokenVoiceIdentifier")
        self.spokenResponsesMuted = preferences?.bool(forKey: "FlowState.spokenResponsesMuted") ?? false
        self.dictationCleanupEnabled = preferences?.object(forKey: "FlowState.dictationCleanupEnabled") as? Bool ?? true
        self.dictationCleanupInstructions = preferences?.string(forKey: "FlowState.dictationCleanupInstructions") ?? ""
        self.dictationRetentionDays = Self.retentionDays(defaults: preferences, key: "FlowState.dictationRetentionDays")
        self.controlRetentionDays = Self.retentionDays(defaults: preferences, key: "FlowState.controlRetentionDays")
        controller = ScreenCaptureController()
        self.spokenResponseController.voiceIdentifier = self.spokenVoiceIdentifier
        self.spokenResponseController.isMuted = self.spokenResponsesMuted
        allowCloudScreenContext = preferences?.bool(forKey: "FlowState.allowCloudScreenContext") ?? false
        if let stored = preferences?.stringArray(forKey: "FlowState.allowedInputActions") {
            allowedInputActions = Set(stored.compactMap(DesktopActionKind.init(rawValue:)))
        }
        speechSettings = SpeechSettingsStore.load(defaults: preferences ?? .standard)
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
        Task { await refreshDictationHistory() }
        Task { await refreshControlHistory() }
        if let url = Bundle.main.object(forInfoDictionaryKey: "FlowStateConvexURL") as? String,
           let key = Bundle.main.object(forInfoDictionaryKey: "FlowStateClerkPublishableKey") as? String,
           let configuration = try? CloudConfiguration(deploymentURL: url, publishableKey: key) {
            connectCloud(configuration)
        }
    }

    private static func retentionDays(defaults: UserDefaults?, key: String) -> Double {
        guard let defaults, let value = defaults.object(forKey: key) as? NSNumber else { return 30 }
        return min(3650, max(1, value.doubleValue))
    }

    func refreshPermissionStatus() {
        permissionSnapshot = MacPermissionManager.snapshot()
        permissionStatus = permissionSnapshot.screenRecording.isGranted
            ? "Screen Recording permission granted"
            : "Screen Recording permission required"
        registerSpeechShortcuts()
    }

    private func registerSpeechShortcuts() {
        dictationShortcutMonitor.stop()
        controlShortcutMonitor.stop()
        guard SpeechSettings.validateShortcuts(
            dictation: speechSettings.dictationShortcut,
            control: speechSettings.controlShortcut
        ) == nil else {
            shortcutError = SpeechShortcutValidationError.duplicate.localizedDescription
            return
        }
        let controlRegistered = controlShortcutMonitor.start(
            shortcut: speechSettings.controlShortcut,
            onKeyDown: { [weak self] in self?.handleShortcutDown(purpose: .control) },
            onKeyUp: { [weak self] in self?.handleShortcutUp(purpose: .control) }
        )
        guard controlRegistered else {
            shortcutError = "Mac Control shortcut is in use or unavailable. Choose another shortcut."
            controlShortcutMonitor.stop()
            return
        }
        let dictationRegistered = dictationShortcutMonitor.start(
            shortcut: speechSettings.dictationShortcut,
            onKeyDown: { [weak self] in self?.handleShortcutDown(purpose: .dictation) },
            onKeyUp: { [weak self] in self?.handleShortcutUp(purpose: .dictation) }
        )
        guard dictationRegistered else {
            // Do not leave the first monitor active if the pair cannot be
            // installed as one coherent configuration.
            controlShortcutMonitor.stop()
            dictationShortcutMonitor.stop()
            shortcutError = "Dictation shortcut is in use or unavailable. Choose another shortcut."
            return
        }
        shortcutError = nil
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
                if activeControlConversationToken != nil {
                    controlConversation.bindExecution(targetBundleIdentifier: bundle, grantExpiresAt: inputGrant.expiresAt)
                }
                desktopState = readyState
                desktopStatus = L10n.format("Control allowed for %@. Your input remains available while Flow State rechecks each step.", L10n.appName(bundle))
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
        cloudPreparationTask?.cancel()
        cloudPreparationTask = nil
        cloudPreparationGeneration &+= 1
        voiceGeneration &+= 1
        utteranceGeneration &+= 1
        dictationGeneration &+= 1
        dictationInsertionTask?.cancel()
        dictationInsertionTask = nil
        structuredControlGeneration.invalidate()
        cloudPlanTarget = nil
        cloudPlanRegistrySnapshot.removeAll()
        cloudExecutionStartedPlanID = nil
        cloudNextPlanStep = 0
        pendingCloudApprovalStep = nil
        preservePendingExternalEffect()
        pendingExternalEffect = nil
        pendingExternalEffectRecovery = nil
        pendingIntent = nil; pendingIntentSummary = nil
        currentPlanStep = nil
        controlConversation.clear()
        activeControlConversationToken = nil
        spokenResponseController.stop()
        intentTask?.cancel()
        controlProcessingTask?.cancel()
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
        // Physical input is allowed to continue. The desktop executor
        // reobserves before every step and fails closed only if the target or
        // preconditions changed; X remains the explicit cancellation path.
        desktopStatus = L10n.text("User input detected — rechecking the target before the next step")
        voiceStatus = desktopStatus
        Task { @MainActor [weak self] in
            guard let self else { return }
            desktopState = await desktopController.state
        }
    }

    private func installTakeoverMonitor(for epoch: UInt64) {
        takeoverMonitor.start(shortcut: speechSettings.controlShortcut) { [weak self] in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self, self.inputEpoch.isCurrent(epoch) else { return }
                self.handlePhysicalTakeover(for: epoch)
            }
        }
    }

    private func invalidateLocalInputForSessionLoss() {
        structuredControlGeneration.invalidate()
        cloudPlanTarget = nil
        cloudPlanRegistrySnapshot.removeAll()
        cloudExecutionStartedPlanID = nil
        cloudNextPlanStep = 0
        pendingCloudApprovalStep = nil
        preservePendingExternalEffect()
        pendingExternalEffect = nil
        pendingExternalEffectRecovery = nil
        pendingIntent = nil; pendingIntentSummary = nil
        currentPlanStep = nil
        controlConversation.signOut()
        activeControlConversationToken = nil
        intentTask?.cancel()
        controlProcessingTask?.cancel()
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
        if managedDictationCleanupClient == nil {
            managedDictationCleanupClient = session
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
        cloudPreparationTask?.cancel()
        cloudPreparationTask = nil
        cloudPreparationGeneration &+= 1
        let preparationGeneration = cloudPreparationGeneration
        structuredControlGeneration.invalidate()
        cloudSession.cancelIntent()
        cloudStatus = "Preparing a plan for review"
        cloudPlanTarget = nil
        cloudPlanRegistrySnapshot.removeAll()
        cloudExecutionStartedPlanID = nil
        cloudNextPlanStep = 0
        pendingCloudApprovalStep = nil
        preservePendingExternalEffect()
        pendingExternalEffect = nil
        pendingExternalEffectRecovery = nil
        if controlConversation.taskID == nil {
            let token = controlConversation.beginTask(request: command)
            activeControlConversationToken = token
            voiceSessionID = token.taskID.uuidString
        } else {
            controlConversation.recordOriginalRequest(command)
        }
        let active = activeCommandApplication
        cloudPreparationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.cloudPreparationGeneration == preparationGeneration {
                    self.cloudPreparationTask = nil
                }
            }
            do {
                let prepared = try await prepareAutomaticTarget(for: VoiceCommandRouter.resolve(command, mode: .auto), activeBundleIdentifier: active)
                guard !Task.isCancelled, cloudPreparationGeneration == preparationGeneration else { return }
                let observation: DesktopObservation
                if let prepared { observation = prepared } else { observation = try await desktopController.observeCurrent() }
                guard !Task.isCancelled, cloudPreparationGeneration == preparationGeneration else { return }
                let target = inputBundleIdentifier
                let epoch = inputEpoch.current
                let registry = ApplicationRegistry.installed(defaults: preferences ?? .standard)
                let candidates = cloudApplicationCandidates(for: registry, command: command, targetBundleIdentifier: target)
                cloudPlanRegistrySnapshot = Set(candidates.map(\.bundleIdentifier))
                let integrations = StructuredControlExecutor.availableIntegrations(registry: registry).sorted()
                var supportedTools = [NativePlanRoute.nativeAccessibility.rawValue]
                if !integrations.isEmpty {
                    supportedTools.append(NativePlanRoute.structuredIntegration.rawValue)
                }
                contextRevision += 1
                try await cloudSession.preparePlan(
                    command: command,
                    targetBundleIdentifier: target,
                    locale: "en",
                    contextRevision: contextRevision,
                    supportedTools: supportedTools,
                    integrations: integrations,
                    applicationCandidates: candidates
                )
                guard !Task.isCancelled, cloudPreparationGeneration == preparationGeneration else { return }
                guard inputEpoch.isCurrent(epoch), let proposal = cloudSession.proposal else { return }
                guard proposal.actions.compactMap(\.targetBundleIdentifier).allSatisfy({ cloudPlanRegistrySnapshot.contains($0) }) else {
                    throw CloudSessionError.reviewChanged
                }
                try await expandCloudGrant(for: proposal, epoch: epoch, registry: registry)
                cloudPlanTarget = (proposal.id, observation, epoch)
                cloudStatus = automaticPlanPrefixCount(proposal.actions) > 0
                    ? "Running reversible reviewed steps"
                    : "Review the proposed actions in Cloud account"
                // Starting is safe for a consequential-first plan: the
                // executor pauses before claiming ordinal zero and publishes
                // the exact step for confirmation. Reversible prefixes run
                // automatically and stop at their first approval boundary.
                executeCloudPlan(proposal)
            }
            catch {
                guard !Task.isCancelled, cloudPreparationGeneration == preparationGeneration else { return }
                cloudStatus = "This request needs clarification or could not be planned."
            }
        }
    }

    private func expandCloudGrant(for plan: CloudProposal, epoch: UInt64, registry: ApplicationRegistry) async throws {
        guard let baseGrant = currentInputGrant, baseGrant.expiresAt > Date() else {
            throw DesktopExecutionError.staleGeneration
        }
        let entries = Dictionary(uniqueKeysWithValues: registry.entries.map { ($0.bundleIdentifier, $0) })
        let nativeActions = plan.actions.filter { $0.route == .nativeAccessibility }
        let structuredActions = plan.actions.filter { $0.route == .structuredIntegration }
        guard !plan.actions.isEmpty,
              structuredActions.allSatisfy({
                  isSupportedNativePlanAction($0)
                      && StructuredControlExecutor.supportsTarget($0.targetBundleIdentifier, registry: registry)
              }),
              nativeActions.allSatisfy({ action in
                  guard let target = action.targetBundleIdentifier,
                        let entry = entries[target],
                        let desktopAction = action.desktopAction else { return false }
                  return entry.supports(desktopAction.kind)
              }),
              plan.actions.allSatisfy({ $0.route != .visualComputerUse }) else {
            throw CloudSessionError.reviewChanged
        }
        let targets = Set(plan.actions.compactMap(\.targetBundleIdentifier))
        let grant = DesktopExecutionGrant(
            allowedBundleIdentifiers: targets,
            allowedActions: baseGrant.allowedActions,
            generation: baseGrant.generation,
            expiresAt: baseGrant.expiresAt
        )
        if !nativeActions.isEmpty {
            try await desktopController.begin(grant: grant, lifecycleEpoch: epoch)
            guard inputEpoch.isCurrent(epoch), grant.expiresAt > Date() else {
                await desktopController.cancel(lifecycleEpoch: epoch)
                throw DesktopExecutionError.staleGeneration
            }
        }
        currentInputGrant = grant
        desktopState = .ready
    }

    func executeCloudPlan(_ plan: CloudProposal) {
        startCloudPlan(plan, requestedApproval: pendingCloudApprovalStep)
    }

    private func confirmPendingCloudStep() {
        guard let session = cloudSession,
              let plan = session.proposal,
              let ordinal = pendingCloudApprovalStep else {
            return
        }
        startCloudPlan(plan, requestedApproval: ordinal)
    }

    private func startCloudPlan(_ plan: CloudProposal, requestedApproval: Int?) {
        guard !executingPlan, let session = cloudSession, let grant = currentInputGrant, grant.expiresAt > Date() else { cloudStatus = "Repeat your command to start a new control session."; return }
        guard let prepared = cloudPlanTarget, prepared.id == plan.id, inputEpoch.isCurrent(prepared.epoch) else {
            cloudStatus = "The prepared target is no longer current. Please make a new request."
            return
        }
        if planHasUnresolvedExternalEffect(plan) {
            cloudStatus = "Resolve the previous reviewed handoff before trying it again."
            speakQuestion("A previous handoff needs reconciliation before I try that operation again.")
            return
        }
        let targets = Set(plan.actions.compactMap(\.targetBundleIdentifier))
        guard (targets.isEmpty && plan.actions.allSatisfy { $0.route == .structuredIntegration })
                || targets.isSubset(of: grant.allowedBundleIdentifiers) else {
            cloudStatus = "The reviewed plan includes an unapproved application. Please make a new request."
            return
        }
        executingPlan = true
        let epoch = inputEpoch.current
        let generation = structuredControlGeneration.begin()
        pendingCloudApprovalStep = nil
        Task {
            var reserved: Int?
            var structuredReservation: CloudSession.ExternalEffectReservation?
            var structuredReservationOrdinal: Int?
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
                if cloudExecutionStartedPlanID != plan.id {
                    try await session.beginExecution(plan,allowedActions:grant.allowedActions,targetBundleIdentifiers:targets,expiresAt:grant.expiresAt)
                    cloudExecutionStartedPlanID = plan.id
                }
                guard inputEpoch.isCurrent(epoch), session.isCurrent(plan) else { throw CancellationError() }
                var approvalForStep = requestedApproval
                for index in cloudNextPlanStep..<plan.actions.count {
                    let action = plan.actions[index]
                    guard inputEpoch.isCurrent(epoch), session.isCurrent(plan) else { throw CancellationError() }
                    guard action.isCurrent(), action.route != .freshVisual else { throw CloudSessionError.reviewChanged }
                    currentPlanStep = L10n.planSummary(action.parameters, appName: action.targetBundleIdentifier.map(L10n.appName) ?? "Selected app")
                    voiceStatus = currentPlanStep ?? "Running the reviewed step"
                    if action.requiresApproval, approvalForStep != index {
                        pendingCloudApprovalStep = index
                        cloudStatus = "Confirm the current reviewed step before continuing"
                        speakQuestion("Confirm the current reviewed step, or cancel the task.")
                        return
                    }
                    if action.requiresApproval {
                        try await session.approveStep(plan, ordinal: index)
                        approvalForStep = nil
                    }
                    if index > 0 { speakMilestone("Continuing the reviewed task") }
                    try await session.claimStep(plan,ordinal:index)
                    reserved = index
                    guard inputEpoch.isCurrent(epoch), session.isCurrent(plan) else { throw CancellationError() }
                    if action.route == .structuredIntegration {
                        let target = try structuredTarget(for: action)
                        let before = try await desktopController.observeCurrent()
                        guard structuredControlPreconditionMatches(before, expected: expectedObservation) else {
                            throw DesktopExecutionError.targetChanged
                        }
                        expectedObservation = before
                        structuredReservation = try await session.beginExternalEffect(plan, ordinal: index)
                        structuredReservationOrdinal = index
                        let redactedRecovery = persistExternalEffectRecoveryBeforeLaunch(
                            plan: plan,
                            ordinal: index,
                            reservation: structuredReservation!,
                            summary: redactedPlanSummary(action),
                            store: externalEffectRecoveryStore
                        )
                        unresolvedExternalEffectRecoveries = externalEffectRecoveryStore.list()
                        if structuredReservation?.needsReconciliation == true {
                            let recovery = PendingExternalEffect(
                                plan: plan,
                                ordinal: index,
                                reservation: structuredReservation!,
                                epoch: epoch
                            )
                            pendingExternalEffect = recovery
                            pendingExternalEffectRecovery = redactedRecovery
                            cloudStatus = "The reviewed handoff may have completed. Confirm its result before continuing."
                            speakQuestion("The reviewed handoff may already be complete. Say completed or failed.")
                            return
                        }
                        do {
                            if structuredReservation?.alreadySucceeded != true {
                                let beforeLaunch = try await desktopController.observeCurrent()
                                guard structuredControlPreconditionMatches(beforeLaunch, expected: expectedObservation) else {
                                    throw DesktopExecutionError.targetChanged
                                }
                                expectedObservation = beforeLaunch
                                _ = try await executeStructuredPlanStep(action, targetBundleIdentifier: target, generation: generation)
                                let after = try await desktopController.observeCurrent()
                                guard StructuredControlExecutor.targetMatches(
                                    expected: target,
                                    observed: after.bundleIdentifier
                                ) else { throw DesktopExecutionError.targetChanged }
                                expectedObservation = after
                                if let structuredReservation {
                                    let authoritativeOutcome = try await session.reconcileExternalEffect(
                                        structuredReservation,
                                        outcome: .succeeded,
                                        requestFingerprint: externalEffectOperationFingerprint(action: action)
                                    )
                                    if authoritativeOutcome.isTerminal {
                                        removeUnresolvedExternalEffect(receiptID: structuredReservation.receiptID)
                                    }
                                    guard authoritativeOutcome == .succeeded else {
                                        throw CloudSessionError.reviewChanged
                                    }
                                }
                            } else {
                                let after = try await desktopController.observeCurrent()
                                guard StructuredControlExecutor.targetMatches(
                                    expected: target,
                                    observed: after.bundleIdentifier
                                ) else { throw DesktopExecutionError.targetChanged }
                                expectedObservation = after
                                removeUnresolvedExternalEffect(receiptID: structuredReservation!.receiptID)
                            }
                            structuredReservation = nil
                        } catch { throw error }
                    } else {
                        let (result, nextObservation) = try await executePlanStep(action, expectedObservation: expectedObservation)
                        expectedObservation = nextObservation
                        lastVerifiedAction = result.undoSupport == .restoreText ? result : nil
                    }
                    guard inputEpoch.isCurrent(epoch), session.isCurrent(plan) else { throw CancellationError() }
                    try await session.finishStep(plan,ordinal:index,verified:true)
                    cloudNextPlanStep = index + 1
                    appendControlHistory(outcome: "Verified step \(index + 1): \(redactedPlanSummary(action))")
                    reserved = nil
                }
                currentPlanStep = nil
                cloudExecutionStartedPlanID = nil
                cloudNextPlanStep = 0
                session.dismissCompletedPlan()
                cloudPlanTarget = nil
                cloudStatus = "Plan completed"
                speakCompletion("Plan completed")
                appendControlHistory(
                    plan: plan.actions.map(redactedPlanSummary).joined(separator: " → "),
                    confirmation: "approved",
                    outcome: "Plan completed"
                )
            } catch {
                var authoritativeOutcome: CloudSession.ExternalEffectOutcome?
                if let structuredReservation, let ordinal = structuredReservationOrdinal {
                    retainUnresolvedExternalEffect(plan: plan, ordinal: ordinal, reservation: structuredReservation)
                    authoritativeOutcome = try? await session.reconcileExternalEffect(
                            structuredReservation,
                            outcome: .uncertain,
                            requestFingerprint: externalEffectOperationFingerprint(action: plan.actions[ordinal])
                        )
                    if let authoritativeOutcome, authoritativeOutcome.isTerminal {
                        removeUnresolvedExternalEffect(receiptID: structuredReservation.receiptID)
                    }
                }
                if let reserved { try? await session.finishStep(plan,ordinal:reserved,verified:false) }
                if session.isCurrent(plan) {
                    await session.cancelPlan()
                }
                cloudExecutionStartedPlanID = nil
                cloudNextPlanStep = 0
                pendingCloudApprovalStep = nil
                pendingExternalEffect = nil
                pendingExternalEffectRecovery = nil
                currentPlanStep = nil
                if authoritativeOutcome == .succeeded {
                    cloudStatus = "The handoff was confirmed completed. The plan stopped safely."
                    speakMilestone("The handoff was confirmed completed. The plan stopped safely.")
                } else if authoritativeOutcome == .failed {
                    cloudStatus = "The handoff was confirmed failed. The plan stopped safely."
                    speakFailure("The handoff was confirmed failed. The plan stopped safely.")
                } else if case DesktopExecutionError.targetChanged = error {
                    cloudStatus = "Plan stopped. Check the last action before trying again."
                    speakQuestion("The target changed. Please repeat the command.")
                } else {
                    cloudStatus = "Plan stopped. Check the last action before trying again."
                    speakFailure(error.localizedDescription)
                }
                appendControlHistory(failure: error.localizedDescription)
            }
            desktopState = await desktopController.state
        }
    }

    func confirmPendingExternalEffect() {
        guard let recovery = externalEffectRecovery else { return }
        confirmExternalEffect(recovery)
    }

    func rejectPendingExternalEffect() {
        guard let recovery = externalEffectRecovery else { return }
        rejectExternalEffect(recovery)
    }

    func confirmExternalEffect(_ recovery: ExternalEffectRecovery) {
        reconcileExternalEffect(recovery, outcome: .succeeded)
    }

    func rejectExternalEffect(_ recovery: ExternalEffectRecovery) {
        reconcileExternalEffect(recovery, outcome: .failed)
    }

    private func reconcileExternalEffect(_ recovery: ExternalEffectRecovery, outcome: CloudSession.ExternalEffectOutcome) {
        if let pending = pendingExternalEffect, pending.reservation.receiptID == recovery.receiptID {
            reconcilePendingExternalEffect(outcome: outcome)
        } else {
            reconcileUnresolvedExternalEffect(recovery: recovery, outcome: outcome)
        }
    }

    private func reconcilePendingExternalEffect(outcome: CloudSession.ExternalEffectOutcome) {
        guard let pending = pendingExternalEffect else { return }
        guard let session = cloudSession,
              inputEpoch.isCurrent(pending.epoch),
              session.isCurrent(pending.plan) else {
            preservePendingExternalEffect()
            pendingExternalEffect = nil
            pendingExternalEffectRecovery = nil
            cloudStatus = "The reviewed task expired. Start a new request."
            return
        }
        executingPlan = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                guard inputEpoch.isCurrent(pending.epoch), session.isCurrent(pending.plan) else { throw CancellationError() }
                let authoritativeOutcome = try await session.reconcileExternalEffect(
                    pending.reservation,
                    outcome: outcome,
                    requestFingerprint: externalEffectOperationFingerprint(action: pending.plan.actions[pending.ordinal])
                )
                guard authoritativeOutcome.isTerminal else {
                    executingPlan = false
                    cloudStatus = "The reviewed handoff is still unresolved. Say completed or failed after checking it."
                    speakQuestion("The reviewed handoff is still unresolved. Say completed or failed after checking it.")
                    return
                }
                removeUnresolvedExternalEffect(receiptID: pending.reservation.receiptID)
                guard inputEpoch.isCurrent(pending.epoch), session.isCurrent(pending.plan) else {
                    executingPlan = false
                    return
                }
                if authoritativeOutcome == .succeeded {
                    try await session.finishStep(pending.plan, ordinal: pending.ordinal, verified: true)
                    cloudNextPlanStep = pending.ordinal + 1
                    appendControlHistory(outcome: "Verified step \(pending.ordinal + 1): \(redactedPlanSummary(pending.plan.actions[pending.ordinal]))")
                    pendingExternalEffect = nil
                    pendingExternalEffectRecovery = nil
                    pendingCloudApprovalStep = nil
                    executingPlan = false
                    cloudStatus = "Continuing the reviewed task"
                    startCloudPlan(pending.plan, requestedApproval: nil)
                } else {
                    await session.cancelPlan()
                    pendingExternalEffect = nil
                    pendingExternalEffectRecovery = nil
                    cloudExecutionStartedPlanID = nil
                    cloudNextPlanStep = 0
                    pendingCloudApprovalStep = nil
                    currentPlanStep = nil
                    executingPlan = false
                    cloudStatus = "The handoff was marked failed and the plan stopped."
                    speakFailure("The reviewed handoff was marked failed. The task stopped.")
                    appendControlHistory(failure: "Reviewed handoff was marked failed")
                }
            } catch is CancellationError {
                executingPlan = false
            } catch {
                executingPlan = false
                cloudStatus = "Choose whether the reviewed handoff completed or failed."
                speakQuestion("I could not record that choice. Say completed or failed.")
            }
        }
    }

    private func reconcileUnresolvedExternalEffect(recovery: ExternalEffectRecovery, outcome: CloudSession.ExternalEffectOutcome) {
        guard unresolvedExternalEffectRecoveries.contains(where: { $0.receiptID == recovery.receiptID }),
              let session = cloudSession else {
            cloudStatus = "Sign in to reconcile the selected reviewed handoff."
            return
        }
        let reservation = CloudSession.ExternalEffectReservation(
            receiptID: recovery.receiptID,
            requestFingerprint: recovery.operationFingerprint
        )
        executingPlan = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { executingPlan = false }
            do {
                let authoritativeOutcome = try await session.reconcileExternalEffect(
                    reservation,
                    outcome: outcome,
                    requestFingerprint: recovery.operationFingerprint
                )
                guard authoritativeOutcome.isTerminal else {
                    cloudStatus = "The selected handoff is still unresolved. Say completed or failed after checking it."
                    speakQuestion("The selected handoff is still unresolved. Say completed or failed after checking it.")
                    return
                }
                guard unresolvedExternalEffectRecoveries.contains(where: { $0.receiptID == recovery.receiptID }) else { return }
                removeUnresolvedExternalEffect(receiptID: recovery.receiptID)
                if authoritativeOutcome == .succeeded {
                    cloudStatus = "The selected handoff was confirmed completed. Start a new request."
                    speakMilestone("The selected handoff was confirmed completed. Start a new request.")
                } else {
                    cloudStatus = "The selected handoff was confirmed failed. Start a new request."
                    speakFailure("The selected handoff was confirmed failed. Start a new request.")
                }
            } catch is CancellationError {
                // Keep the recovery record until the receipt is explicitly reconciled.
            } catch {
                cloudStatus = "Choose whether the previous reviewed handoff completed or failed."
                speakQuestion("I could not record that choice. Say completed or failed.")
            }
        }
    }

    private func preservePendingExternalEffect() {
        guard let pending = pendingExternalEffect else { return }
        let recovery = externalEffectRecovery(for: pending.plan, ordinal: pending.ordinal, reservation: pending.reservation)
        retainUnresolvedExternalEffect(recovery)
    }

    private func retainUnresolvedExternalEffect(plan: CloudProposal, ordinal: Int, reservation: CloudSession.ExternalEffectReservation) {
        retainUnresolvedExternalEffect(externalEffectRecovery(for: plan, ordinal: ordinal, reservation: reservation))
    }

    private func retainUnresolvedExternalEffect(_ recovery: ExternalEffectRecovery?) {
        guard let recovery else { return }
        externalEffectRecoveryStore.upsert(recovery)
        unresolvedExternalEffectRecoveries = externalEffectRecoveryStore.list()
    }

    private func removeUnresolvedExternalEffect(receiptID: String) {
        externalEffectRecoveryStore.remove(receiptID: receiptID)
        unresolvedExternalEffectRecoveries = externalEffectRecoveryStore.list()
    }

    private func externalEffectRecovery(for plan: CloudProposal, ordinal: Int, reservation: CloudSession.ExternalEffectReservation) -> ExternalEffectRecovery {
        makeExternalEffectRecovery(
            plan: plan,
            ordinal: ordinal,
            reservation: reservation,
            summary: redactedPlanSummary(plan.actions[ordinal])
        )
    }

    private func planHasUnresolvedExternalEffect(_ plan: CloudProposal) -> Bool {
        return plan.actions.enumerated().contains { index, action in
            guard action.route == .structuredIntegration else { return false }
            let fingerprint = externalEffectOperationFingerprint(action: action)
            return unresolvedExternalEffectRecoveries.contains { $0.operationFingerprint == fingerprint }
        }
    }

    private func structuredTarget(for action: NativePlanAction) throws -> String {
        guard let target = action.targetBundleIdentifier else {
            throw DesktopExecutionError.actionNotGranted
        }
        let registry = ApplicationRegistry.installed(defaults: preferences ?? .standard)
        guard StructuredControlExecutor.supportsTarget(target, registry: registry) else {
            throw DesktopExecutionError.actionNotGranted
        }
        return target
    }

    private func executeStructuredPlanStep(
        _ action: NativePlanAction,
        targetBundleIdentifier: String?,
        generation: UInt64
    ) async throws -> StructuredControlResult {
        try await structuredControlExecutor.execute(action, targetBundleIdentifier: targetBundleIdentifier, isCurrent: { [structuredControlGeneration] in
            structuredControlGeneration.isCurrent(generation)
        })
    }

    private func redactedPlanSummary(_ action: NativePlanAction) -> String {
        switch action.parameters {
        case .openURL:
            return "Opened the reviewed URL handoff"
        case .draftMessage:
            return "Opened the Gmail compose handoff"
        case .attachFile:
            return "Attached an approved file"
        case .sendEmail:
            return "Sent an email"
        default:
            return action.summary
        }
    }

    func executePlanStep(_ action: NativePlanAction, expectedObservation: DesktopObservation) async throws -> (VerifiedDesktopAction, DesktopObservation) {
        guard action.isCurrent(), action.route == .nativeAccessibility,
              let target = action.targetBundleIdentifier, let desktopAction = action.desktopAction else { throw DesktopExecutionError.staleGeneration }
        let current = try await desktopController.observeCurrent()
        if action.kind != .openApplication, current.bundleIdentifier != target {
            throw DesktopExecutionError.targetChanged
        }
        let result = try await desktopController.execute(desktopAction,
            expectedBundleIdentifier: target,
            expectedObservation: action.kind == .openApplication ? nil : expectedObservation)
        let nextObservation = try await desktopController.observeCurrent()
        return (result, nextObservation)
    }

    private func updateVoiceHUD() {
        guard showsVoiceHUD else { return }
        voiceHUD.show(status: voiceStatus, transcript: latestTranscript, isListening: isListening,
            purpose: listeningPurpose,
            onStop: { [weak self] in self?.stopVoiceSession() },
            onConfirm: pendingIntent == nil && pendingCloudApprovalStep == nil && externalEffectRecovery == nil ? nil : { [weak self] in
                if self?.pendingIntent != nil {
                    self?.confirmPendingIntent()
                } else if self?.pendingCloudApprovalStep != nil {
                    self?.confirmPendingCloudStep()
                } else {
                    self?.confirmPendingExternalEffect()
                }
            },
            isMuted: spokenResponsesMuted,
            lastResponse: lastSpokenResponse,
            currentStep: currentPlanStep,
            onReplay: { [weak self] in self?.replayLastSpokenResponse() },
            onMute: { [weak self] in self?.setSpokenResponsesMuted(!(self?.spokenResponsesMuted ?? false)) },
            onSettings: { [weak self] in
                guard let self else { return }
                self.settingsSection = self.accessibilityGranted() ? .tasks : .permissions
            })
    }

    func startVoiceSession() {
        startVoiceSession(purpose: .control)
    }

    func startVoiceSession(purpose: SpeechSessionPurpose) {
        guard !isFinishingVoice else { return }
        guard !isListening else { return }
        showsVoiceHUD = true
        latestTranscript = ""
        dictationRecovery = nil
        refreshPermissionStatus()
        guard permissionSnapshot.microphone.isGranted else {
            voiceStatus = "Microphone permission is required"
            return
        }
        if purpose == .dictation, !accessibilityGranted() {
            voiceStatus = "Allow Accessibility to select the focused text field before dictating."
            return
        }
        voiceGeneration &+= 1
        let voiceToken = voiceGeneration
        if purpose == .control {
            let conversationToken = controlConversation.beginHoldIfCurrent(
                targetBundleIdentifier: currentInputGrant?.allowedBundleIdentifiers.first,
                grantExpiresAt: currentInputGrant?.expiresAt
            ) ?? controlConversation.beginHoldIfCurrent()!
            activeControlConversationToken = conversationToken
            voiceSessionID = conversationToken.taskID.uuidString
        } else {
            voiceSessionID = UUID().uuidString
            dictationGeneration &+= 1
            dictationPendingText = ""
            dictationInsertionTask?.cancel()
        }
        activeSpeechPurpose = purpose
        listeningPurpose = purpose
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
            if purpose == .dictation {
                do {
                    let observation = try await dictationTargetObserver.observe()
                    guard voiceToken == voiceGeneration else { return }
                    let clipboardChangeCount = await MainActor.run { NSPasteboard.general.changeCount }
                    guard voiceToken == voiceGeneration else { return }
                    let target = DictationTarget(
                        observation: observation,
                        clipboardChangeCount: clipboardChangeCount
                    )
                    guard target.validationError == nil else {
                        voiceStatus = target.validationError?.localizedDescription ?? "Select an editable text field first."
                        preparingVoice = false
                        activeSpeechPurpose = nil
                        listeningPurpose = nil
                        isListening = false
                        return
                    }
                    dictationTarget = target
                } catch {
                    voiceStatus = "Select an editable text field before dictating."
                    preparingVoice = false
                    activeSpeechPurpose = nil
                    listeningPurpose = nil
                    isListening = false
                    return
                }
            }
            await speechCoordinator.update(settings: currentSettings, purpose: purpose)
            guard voiceToken == voiceGeneration else { return }
            _ = await speechCoordinator.pushToTalkDown(purpose: purpose)
            guard voiceToken == voiceGeneration else {
                await speechCoordinator.localStop()
                return
            }
            do {
                try await startSpeechCapture(language: currentSettings.language, purpose: purpose)
                guard voiceToken == voiceGeneration else {
                    speechCapture.stop()
                    await speechCoordinator.localStop()
                    return
                }
                preparingVoice = false
                isListening = true
                voiceStatus = purpose == .dictation
                    ? "Listening for Dictation — release to paste"
                    : "Listening for Mac Control — release to finish"
            } catch {
                guard voiceToken == voiceGeneration else {
                    speechCapture.stop()
                    await speechCoordinator.localStop()
                    return
                }
                preparingVoice = false; isListening = false
                await speechCoordinator.localStop()
                activeSpeechPurpose = nil
                listeningPurpose = nil
                voiceStatus = error.localizedDescription
            }
        }
    }

    func finishVoiceSession(purpose: SpeechSessionPurpose? = nil) {
        guard isListening else { return }
        guard purpose == nil || purpose == activeSpeechPurpose else { return }
        isListening = false
        if preparingVoice {
            preparingVoice = false; voiceGeneration &+= 1; speechCapture.stop()
            Task { await speechCoordinator.localStop() }
            activeSpeechPurpose = nil
            listeningPurpose = nil
            voiceStatus = "Released before speech was ready. Hold again."
            return
        }
        isFinishingVoice = true
        speechCapture.finish()
        let endingPurpose = activeSpeechPurpose
        Task { await speechCoordinator.finish(purpose: endingPurpose) }
        voiceStatus = "Finishing transcription"
    }

    func stopVoiceSession() {
        showsVoiceHUD = false
        isFinishingVoice = false
        voiceHUD.hide()
        voiceGeneration &+= 1
        preparingVoice = false
        isListening = false
        isFinishingVoice = false
        activeSpeechPurpose = nil
        listeningPurpose = nil
        controlConversation.clear()
        activeControlConversationToken = nil
        currentPlanStep = nil
        spokenResponseController.stop()
        dictationGeneration &+= 1
        dictationPendingText = ""
        dictationInsertionTask?.cancel()
        dictationInsertionTask = nil
        dictationTarget = nil
        dictationRecoveryExpiryTask?.cancel()
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
        if let conflict = SpeechSettings.validateShortcuts(
            dictation: settings.dictationShortcut,
            control: settings.controlShortcut
        ) {
            shortcutError = conflict.localizedDescription
            return
        }
        stopVoiceSession()
        speechSettings = settings
        SpeechSettingsStore.save(settings, defaults: preferences ?? .standard)
        registerSpeechShortcuts()
        if currentInputGrant != nil {
            let epoch = inputEpoch.current
            installTakeoverMonitor(for: epoch)
        }
        Task { await speechCoordinator.update(settings: settings, purpose: activeSpeechPurpose) }
    }

    func refreshMemory() async {
        memorySnapshot = await memoryStore.snapshot()
    }

    func refreshDictationHistory() async {
        dictationHistory = await dictationHistoryStore.list()
    }

    func refreshControlHistory() async {
        controlHistory = await controlHistoryStore.list()
    }

    func setSpokenVoice(_ identifier: String?) {
        spokenVoiceIdentifier = identifier
        spokenResponseController.voiceIdentifier = identifier
        preferences?.set(identifier, forKey: "FlowState.spokenVoiceIdentifier")
    }

    func setSpokenResponsesMuted(_ muted: Bool) {
        spokenResponsesMuted = muted
        spokenResponseController.isMuted = muted
        preferences?.set(muted, forKey: "FlowState.spokenResponsesMuted")
    }

    func setDictationCleanup(enabled: Bool, instructions: String? = nil) {
        dictationCleanupEnabled = enabled
        if let instructions { dictationCleanupInstructions = String(instructions.prefix(1_000)) }
        preferences?.set(dictationCleanupEnabled, forKey: "FlowState.dictationCleanupEnabled")
        preferences?.set(dictationCleanupInstructions, forKey: "FlowState.dictationCleanupInstructions")
    }

    func setDictationCleanupInstructions(_ instructions: String) {
        setDictationCleanup(enabled: dictationCleanupEnabled, instructions: instructions)
    }

    func setDictationRetentionDays(_ days: Double) {
        dictationRetentionDays = min(3650, max(1, days.rounded()))
        preferences?.set(dictationRetentionDays, forKey: "FlowState.dictationRetentionDays")
        Task { await dictationHistoryStore.setRetention(dictationRetentionDays * 24 * 60 * 60) }
    }

    func setControlRetentionDays(_ days: Double) {
        controlRetentionDays = min(3650, max(1, days.rounded()))
        preferences?.set(controlRetentionDays, forKey: "FlowState.controlRetentionDays")
        Task { await controlHistoryStore.setRetention(controlRetentionDays * 24 * 60 * 60) }
    }

    func replayLastSpokenResponse() {
        spokenResponseController.replayLastResponse()
        lastSpokenResponse = spokenResponseController.lastResponse
    }

    func startNewControlTask() {
        cloudPreparationTask?.cancel()
        cloudPreparationTask = nil
        cloudPreparationGeneration &+= 1
        voiceGeneration &+= 1
        utteranceGeneration &+= 1
        dictationGeneration &+= 1
        dictationInsertionTask?.cancel()
        dictationInsertionTask = nil
        structuredControlGeneration.invalidate()
        intentTask?.cancel()
        controlProcessingTask?.cancel()
        cloudSession?.cancelIntent()
        let session = cloudSession
        if let session {
            Task { await session.cancelPlan() }
        } else {
            onCancelCloud?()
        }
        spokenResponseController.stop()
        speechCapture.stop()
        preparingVoice = false
        isListening = false
        isFinishingVoice = false
        activeSpeechPurpose = nil
        listeningPurpose = nil
        currentInputGrant = nil
        lastVerifiedAction = nil
        takeoverMonitor.stop()
        executingPlan = false
        desktopState = .cancelled
        revokeTask()
        let epoch = inputEpoch.advance()
        Task { @MainActor [weak self] in
            guard let self else { return }
            await desktopController.cancel(lifecycleEpoch: epoch)
            guard inputEpoch.isCurrent(epoch) else { return }
            desktopState = await desktopController.state
        }
        controlConversation.newTask()
        activeControlConversationToken = controlConversation.beginHold()
        voiceSessionID = activeControlConversationToken?.taskID.uuidString ?? UUID().uuidString
        pendingIntent = nil
        pendingIntentSummary = nil
        currentPlanStep = nil
        cloudPlanTarget = nil
        cloudExecutionStartedPlanID = nil
        cloudNextPlanStep = 0
        pendingCloudApprovalStep = nil
        preservePendingExternalEffect()
        pendingExternalEffect = nil
        pendingExternalEffectRecovery = nil
        voiceStatus = "New Mac Control task ready"
    }

    func signOutCloud() async {
        controlConversation.signOut()
        activeControlConversationToken = nil
        if let cloudSession { await cloudSession.signOut() }
    }

    private func speakQuestion(_ text: String) {
        spokenResponseController.speakQuestion(text)
        lastSpokenResponse = spokenResponseController.lastResponse
    }

    private func speakMilestone(_ text: String, meaningful: Bool = true) {
        spokenResponseController.speakMilestone(text, meaningful: meaningful)
        lastSpokenResponse = spokenResponseController.lastResponse
    }

    private func speakFailure(_ text: String) {
        spokenResponseController.speakFailure(text)
        lastSpokenResponse = spokenResponseController.lastResponse
    }

    private func speakCompletion(_ text: String) {
        spokenResponseController.speakCompletion(text)
        lastSpokenResponse = spokenResponseController.lastResponse
    }

    private func appendControlHistory(
        request: String? = nil,
        plan: String? = nil,
        confirmation: String? = nil,
        outcome: String? = nil,
        failure: String? = nil
    ) {
        let resolvedRequest = request ?? controlConversation.originalRequest
        guard let resolvedRequest, let taskID = controlConversation.taskID else { return }
        let confirmations = confirmation.map { [$0] } ?? []
        let outcomes = outcome.map { [$0] } ?? []
        Task { [weak self] in
            guard let self else { return }
            _ = await controlHistoryStore.append(
                taskID: taskID,
                request: resolvedRequest,
                approvedPlan: plan,
                confirmations: confirmations,
                stepOutcomes: outcomes,
                failureReason: failure
            )
            await refreshControlHistory()
        }
    }

    func deleteControlHistory(id: UUID) {
        Task {
            await controlHistoryStore.delete(id: id)
            await refreshControlHistory()
        }
    }

    func deleteAllControlHistory() {
        Task {
            await controlHistoryStore.deleteAll()
            await refreshControlHistory()
        }
    }

    func copyDictationHistory(_ entry: DictationHistoryEntry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.text, forType: .string)
    }

    func deleteDictationHistory(id: UUID) {
        Task {
            await dictationHistoryStore.delete(id: id)
            await refreshDictationHistory()
        }
    }

    func deleteAllDictationHistory() {
        Task {
            await dictationHistoryStore.deleteAll()
            await refreshDictationHistory()
        }
    }

    func copyDictationRecovery() {
        guard let recovery = dictationRecovery, recovery.expiresAt > Date() else {
            dictationRecovery = nil
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(recovery.text, forType: .string)
        voiceStatus = "Dictation copied to the clipboard"
    }

    func retryDictationRecovery() {
        guard let recovery = dictationRecovery, recovery.expiresAt > Date() else {
            dictationRecovery = nil
            return
        }
        dictationInsertionTask?.cancel()
        dictationGeneration &+= 1
        let insertionGeneration = dictationGeneration
        let voiceGenerationAtInsertion = voiceGeneration
        dictationInsertionTask = Task { [weak self] in
            guard let self else { return }
            let cleanupSettings = DictationCleanupSettings(
                enabled: dictationCleanupEnabled,
                instructions: dictationCleanupInstructions
            )
            do {
                let output = try await dictationOutputController.insert(
                    transcript: recovery.text,
                    into: recovery.target,
                    cleanupSettings: cleanupSettings,
                    managedCleanupClient: managedDictationCleanupClient,
                    isInsertionCurrent: { [weak self] in
                        guard let self else { return false }
                        return self.dictationGeneration == insertionGeneration &&
                            self.voiceGeneration == voiceGenerationAtInsertion
                    }
                )
                guard dictationGeneration == insertionGeneration,
                      voiceGeneration == voiceGenerationAtInsertion else { return }
                _ = await dictationHistoryStore.append(text: output.text)
                await refreshDictationHistory()
                dictationRecovery = nil
                voiceStatus = "Dictation inserted"
            } catch {
                guard dictationGeneration == insertionGeneration,
                      voiceGeneration == voiceGenerationAtInsertion else { return }
                voiceStatus = error.localizedDescription
            }
            if dictationGeneration == insertionGeneration {
                dictationInsertionTask = nil
            }
        }
    }

    func dismissDictationRecovery() {
        dictationRecovery = nil
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

    private func consumeDictation(_ result: SpeechRecognitionResult, token: UInt64) -> Bool {
        guard activeSpeechPurpose == .dictation || result.purpose == .dictation else { return false }
        guard token == voiceGeneration else { return true }
        if !result.transcript.isEmpty || !result.sessionEnded { latestTranscript = result.transcript }
        guard result.isFinal else { return true }

        let segment = result.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.sessionEnded else {
            if !segment.isEmpty {
                dictationPendingText = [dictationPendingText, segment]
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
            }
            voiceStatus = "Dictation ready — release to paste"
            return true
        }

        if let id = result.utteranceID, !consumedUtterances.insert(id).inserted { return true }
        isFinishingVoice = false
        isListening = false
        activeSpeechPurpose = nil
        listeningPurpose = nil
        let dictationVoiceToken = voiceGeneration
        Task { @MainActor [weak self] in
            guard let self, self.voiceGeneration == dictationVoiceToken else { return }
            let coordinatorGeneration = await self.speechCoordinator.generation
            await self.speechCoordinator.localStop(ifGeneration: coordinatorGeneration)
        }
        let target = dictationTarget
        dictationTarget = nil
        let text = [dictationPendingText, segment]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        dictationPendingText = ""
        guard !text.isEmpty, let target else {
            voiceStatus = "No speech detected. Try again."
            return true
        }

        dictationInsertionTask?.cancel()
        let insertionGeneration = dictationGeneration
        let voiceGenerationAtInsertion = voiceGeneration
        dictationInsertionTask = Task { [weak self] in
            guard let self else { return }
            let memory = await memoryStore.snapshot()
            let vocabulary = Dictionary(
                uniqueKeysWithValues: memory.preferences
                    .filter { $0.category == .vocabulary && $0.source == .explicit }
                    .map { ($0.trigger, $0.value) }
            )
            let cleanupSettings = DictationCleanupSettings(
                enabled: dictationCleanupEnabled,
                instructions: dictationCleanupInstructions
            )
            let fallbackText = cleanupSettings.enabled
                ? DictationTextCleaner.clean(text, vocabulary: vocabulary)
                : text.trimmingCharacters(in: .whitespacesAndNewlines)
            do {
                let output = try await dictationOutputController.insert(
                    transcript: text,
                    into: target,
                    cleanupSettings: cleanupSettings,
                    managedCleanupClient: managedDictationCleanupClient,
                    isInsertionCurrent: { [weak self] in
                        guard let self else { return false }
                        return self.dictationGeneration == insertionGeneration &&
                            self.voiceGeneration == voiceGenerationAtInsertion
                    }
                )
                guard dictationGeneration == insertionGeneration,
                      voiceGeneration == voiceGenerationAtInsertion else { return }
                _ = await dictationHistoryStore.append(text: output.text)
                await refreshDictationHistory()
                voiceStatus = "Dictation inserted"
            } catch {
                guard dictationGeneration == insertionGeneration,
                      voiceGeneration == voiceGenerationAtInsertion else { return }
                let reason = error.localizedDescription
                _ = await dictationHistoryStore.append(text: fallbackText, failureReason: reason)
                await refreshDictationHistory()
                let card = DictationRecoveryCard(
                    text: fallbackText,
                    reason: reason,
                    target: target,
                    expiresAt: Date().addingTimeInterval(30)
                )
                dictationRecovery = card
                voiceStatus = reason
                dictationRecoveryExpiryTask?.cancel()
                dictationRecoveryExpiryTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(30))
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        guard self?.dictationRecovery?.id == card.id else { return }
                        self?.dictationRecovery = nil
                    }
                }
            }
            if dictationGeneration == insertionGeneration {
                dictationInsertionTask = nil
            }
        }

        return true
    }

    func consume(_ result: SpeechRecognitionResult, token: UInt64) {
        guard token == voiceGeneration else { return }
        if consumeDictation(result, token: token) { return }
        if result.sessionEnded && result.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Analyzer shutdown can emit an empty terminal result after a
            // finalized control utterance. Do not cancel or replace that
            // command; let its task publish the verified outcome first.
            let previousTask = controlProcessingTask ?? intentTask
            Task { @MainActor [weak self] in
                await previousTask?.value
                guard let self, token == self.voiceGeneration else { return }
                await self.speechCoordinator.localStop()
                self.isFinishingVoice = false
                self.isListening = false
                self.activeSpeechPurpose = nil
                self.listeningPurpose = nil
                if self.latestTranscript.isEmpty {
                    self.voiceStatus = "No speech detected. Try again."
                }
            }
            return
        }
        if !result.transcript.isEmpty || !result.sessionEnded { latestTranscript = result.transcript }
        if result.sessionEnded {
            isFinishingVoice = false
            isListening = false
            voiceStatus = latestTranscript.isEmpty ? "No speech detected. Try again." : "Voice session finished"
        }
        if result.isFinal, result.purpose == .control {
            let request = result.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            if !request.isEmpty {
                controlConversation.recordOriginalRequest(request)
                controlConversation.appendTurn(role: .user, text: request)
            }
        }
        if result.isFinal, let id = result.utteranceID, !consumedUtterances.insert(id).inserted { return }
        if result.isFinal, externalEffectRecovery != nil {
            let reply = result.transcript
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
                .lowercased()
            switch reply {
            case "confirm", "yes", "completed", "complete", "it completed", "it succeeded":
                confirmPendingExternalEffect()
            case "no", "failed", "failure", "it failed", "cancel", "stop":
                rejectPendingExternalEffect()
            default:
                speakQuestion("Say completed or failed, or press X to cancel.")
            }
            return
        }
        if result.isFinal, pendingCloudApprovalStep != nil {
            let reply = result.transcript
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
                .lowercased()
            if reply == "confirm" || reply == "yes" || reply == "continue" {
                confirmPendingCloudStep()
            } else if reply == "cancel" || reply == "stop" || reply == "no" {
                cancelInputTask()
            } else {
                speakQuestion("Say confirm to run this reviewed step, or press X to cancel.")
            }
            return
        }
        if result.isFinal, pendingIntent != nil,
           result.transcript.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).lowercased() == "confirm" {
            controlConversation.appendTurn(role: .user, text: "confirm")
            confirmPendingIntent()
            return
        }
        if result.isFinal { utteranceGeneration &+= 1 }
        let utteranceToken = utteranceGeneration
        let activeAtArrival = activeCommandApplication
        if result.isFinal {
            intentTask?.cancel(); cloudSession?.cancelIntent()
            controlProcessingTask?.cancel()
            pendingIntent = nil; pendingIntentSummary = nil
        }
        let processingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard token == voiceGeneration, utteranceToken == utteranceGeneration else { return }
            if result.isFinal, let message = VoiceCommandRouter.controlTextInputMessage(for: result.transcript) {
                voiceStatus = message
                return
            }
            var arrivalObservation: DesktopObservation?
            if result.isFinal, !result.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                do {
                    let rawCommand = VoiceCommandRouter.resolve(result.transcript, mode: .command)
                    if case .unknown = rawCommand {
                        let registry = ApplicationRegistry.installed(defaults: preferences ?? .standard)
                        switch registry.resolveApplicationCommand(result.transcript) {
                        case let .resolved(entry):
                            _ = try await prepareAutomaticTarget(
                                for: .openApp(entry.bundleIdentifier),
                                activeBundleIdentifier: activeAtArrival,
                                utteranceToken: utteranceToken
                            )
                            guard token == voiceGeneration, utteranceToken == utteranceGeneration else { return }
                            if let actionTask = executeDesktopAction(.openApplication(bundleIdentifier: entry.bundleIdentifier)) {
                                await actionTask.value
                            }
                            return
                        case .ambiguous, .unknown:
                            voiceStatus = "Please clarify which installed app you want to open."
                            speakQuestion("Please clarify which installed app you want to open.")
                            return
                        case .notAnApplicationCommand:
                            break
                        }
                    }
                    arrivalObservation = try await prepareAutomaticTarget(for: rawCommand, activeBundleIdentifier: activeAtArrival, utteranceToken: utteranceToken)
                } catch {
                    guard token == voiceGeneration, utteranceToken == utteranceGeneration else { return }
                    voiceStatus = error.localizedDescription
                    return
                }
            }
            let personalized = await memoryStore.personalize(result.transcript, mode: .command)
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
            case .dictate:
                voiceStatus = VoiceCommandRouter.controlTextInputMessage
            case let .scroll(lines):
                if let actionTask = executeDesktopAction(.scroll(lines: lines), expectedObservation: arrivalObservation) {
                    await actionTask.value
                }
            case let .openApp(bundle):
                if inputBundleIdentifier != bundle {
                    do { _ = try await prepareAutomaticTarget(for: command, activeBundleIdentifier: activeAtArrival, utteranceToken: utteranceToken) }
                    catch { voiceStatus = error.localizedDescription; return }
                }
                guard token == voiceGeneration, utteranceToken == utteranceGeneration else { return }
                if let actionTask = executeDesktopAction(.openApplication(bundleIdentifier: bundle)) {
                    await actionTask.value
                }
            case let .focus(role, label):
                if let actionTask = executeDesktopAction(.focus(role: role, label: label), expectedObservation: arrivalObservation) {
                    await actionTask.value
                }
            case let .select(label):
                if let actionTask = executeDesktopAction(.select(label: label), expectedObservation: arrivalObservation) {
                    await actionTask.value
                }
            case let .press(key, modifiers):
                if key == "Enter" || modifiers != nil {
                    prepareLocalKeyConfirmation(key: key, modifiers: modifiers, expectedObservation: arrivalObservation)
                } else {
                    if let actionTask = executeDesktopAction(.press(key: key, modifiers: modifiers), expectedObservation: arrivalObservation) {
                        await actionTask.value
                    }
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
        controlProcessingTask = processingTask
    }

    func shouldInterpret(_ command: VoiceCommand) -> Bool {
        useManagedCommands && command == .unknown
    }

    private func isCompoundControlRequest(_ transcript: String) -> Bool {
        let normalized = transcript.lowercased()
        return normalized.contains(" then ") || normalized.contains("and then") || normalized.contains(";")
    }

    private func resolveManagedUtterance(_ transcript: String, utteranceID: UUID, token: UInt64, originalObservation: DesktopObservation?) {
        if isCompoundControlRequest(transcript) {
            prepareCloudCommand(transcript)
            return
        }
        guard let session = cloudSession, session.signedIn else {
            voiceStatus = "Sign in to use Auto interpretation, or choose Commands only for local controls."
            return
        }
        pendingIntent = nil; pendingIntentSummary = nil
        let previous = intentTask
        let sessionID = voiceSessionID
        let epoch = inputEpoch.current
        let conversationToken = activeControlConversationToken
        intentTask = Task { [weak self] in
            guard let self, !Task.isCancelled, token == voiceGeneration, inputEpoch.isCurrent(epoch) else { return }
            guard let conversationToken, controlConversation.accepts(conversationToken) else { return }
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
                let registry = ApplicationRegistry.installed(defaults: preferences ?? .standard)
                let integrations = StructuredControlExecutor.availableIntegrations(registry: registry)
                var supportedTools = [NativePlanRoute.nativeAccessibility.rawValue]
                if !integrations.isEmpty {
                    supportedTools.append(NativePlanRoute.structuredIntegration.rawValue)
                }
                let prefiltered = registry.candidates(for: transcript)
                let apps = (prefiltered.isEmpty ? Array(registry.entries.prefix(ApplicationRegistry.defaultCandidateLimit)) : prefiltered).sorted {
                    let left = inputGrant.allowedBundleIdentifiers.contains($0.bundleIdentifier) || $0.bundleIdentifier == observation.bundleIdentifier
                    let right = inputGrant.allowedBundleIdentifiers.contains($1.bundleIdentifier) || $1.bundleIdentifier == observation.bundleIdentifier
                    return left != right ? left : $0.bundleIdentifier.localizedStandardCompare($1.bundleIdentifier) == .orderedAscending
                }
                var candidates = apps.prefix(99).map {
                    CloudIntentCandidate(
                        id: "app:" + $0.bundleIdentifier,
                        label: $0.displayName,
                        bundleIdentifier: $0.bundleIdentifier,
                        kind: "app",
                        normalizedNames: $0.normalizedNames,
                        isRunning: $0.isRunning,
                        supportedActions: $0.supportedActions.map(\.rawValue).sorted(),
                        integrations: $0.integrations.sorted()
                    )
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
                    focusedRole: observation.focusedRole, editable: observation.isEditable, targetCandidates: candidates,
                    recentInteraction: controlConversation.recentInteraction)
                voiceStatus = "Understanding your request…"
                let captureGrant = await prepareAutomaticObservation(bundle: observation.bundleIdentifier)
                var screenObservation: CaptureObservation?
                var decision = try await session.routeIntent(utterance: transcript, sessionID: sessionID,
                    utteranceID: utteranceID.uuidString, contextRevision: revision,
                    mode: "control",
                    context: context, grant: currentInputGrant, observationAllowedUntil: captureGrant?.expiresAt,
                    supportedTools: supportedTools)
                guard !Task.isCancelled, token == voiceGeneration, inputEpoch.isCurrent(epoch),
                      controlConversation.accepts(conversationToken),
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
                          controlConversation.accepts(conversationToken),
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
                        mode: "control",
                        context: context, grant: currentInputGrant, observation: cloudImage,
                        observationAllowedUntil: captureGrant.expiresAt, supportedTools: supportedTools)
                    guard !Task.isCancelled, token == voiceGeneration, inputEpoch.isCurrent(epoch),
                          controlConversation.accepts(conversationToken),
                          sessionID == voiceSessionID, revision == contextRevision else { throw CancellationError() }
                    try await revalidateScreen(frame.observation)

                }
                guard decision.decision == .execute || decision.decision == .dictation,
                      let action = decision.action?.nativePlanAction else {
                    let clarification = decision.clarification ?? "Please clarify what you want Flow State to do."
                    controlConversation.setPendingClarification(clarification)
                    controlConversation.appendTurn(role: .assistant, text: clarification)
                    speakQuestion(clarification)
                    voiceStatus = clarification
                    return
                }
                if action.requiresApproval {
                    pendingIntent = (action, observation, epoch, screenObservation)
                    pendingIntentSummary = action.route == .structuredIntegration
                        ? redactedPlanSummary(action)
                        : L10n.planSummary(action.parameters, appName: action.targetBundleIdentifier.map(L10n.appName) ?? "Selected app")
                    currentPlanStep = pendingIntentSummary
                    _ = controlConversation.requireApproval()
                    controlConversation.setPendingClarification("Confirm: " + (pendingIntentSummary ?? "this action"))
                    voiceStatus = "Confirm: " + (pendingIntentSummary ?? "this action") + ". Say confirm or cancel."
                    speakQuestion(voiceStatus)
                    return
                }
                try await executeResolvedIntent(action, observation: observation, epoch: epoch, screen: screenObservation)
            } catch is CancellationError {
                // A newer session, Stop, or physical takeover owns the UI now.
            } catch {
                guard !Task.isCancelled, token == voiceGeneration, inputEpoch.isCurrent(epoch),
                      controlConversation.accepts(conversationToken) else { return }
                desktopState = await desktopController.state
                let message = (error as? DesktopExecutionError)?.localizedDescription
                    ?? (error as? CaptureError)?.localizedDescription
                    ?? "This request could not be completed. Check your connection, permissions, and target app."
                voiceStatus = message
                controlConversation.setPendingClarification(nil)
                controlConversation.appendTurn(role: .assistant, text: message)
                speakFailure(message)
                appendControlHistory(failure: message)
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
                currentPlanStep = pendingIntentSummary
                _ = controlConversation.requireApproval()
                controlConversation.setPendingClarification("Confirm: " + (pendingIntentSummary ?? "this action"))
                voiceStatus = "Confirm this keyboard shortcut. Say confirm or cancel."
                speakQuestion(voiceStatus)
            } catch {
                guard !Task.isCancelled, inputEpoch.isCurrent(epoch) else { return }
                voiceStatus = error.localizedDescription
            }
        }
    }

    func confirmPendingIntent() {
        guard let pending = pendingIntent else { return }
        pendingIntent = nil; pendingIntentSummary = nil
        currentPlanStep = nil
        controlConversation.setPendingClarification(nil)
        intentTask = Task {
            do { try await executeResolvedIntent(pending.action, observation: pending.observation, epoch: pending.epoch, screen: pending.screen, approved: true) }
            catch {
                if inputEpoch.isCurrent(pending.epoch) {
                    desktopState = await desktopController.state
                    voiceStatus = error.localizedDescription
                    speakFailure(error.localizedDescription)
                    appendControlHistory(failure: error.localizedDescription)
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
        guard !action.requiresApproval || approved, action.isCurrent(),
              !Task.isCancelled, inputEpoch.isCurrent(epoch),
              let grant = currentInputGrant, grant.expiresAt > Date(), desktopState == .ready else {
            throw DesktopExecutionError.actionNotGranted
        }
        if action.route == .structuredIntegration {
            let registry = ApplicationRegistry.installed(defaults: preferences ?? .standard)
            guard let target = action.targetBundleIdentifier else {
                throw DesktopExecutionError.targetChanged
            }
            guard isSupportedNativePlanAction(action),
                  StructuredControlExecutor.supportsTarget(target, registry: registry) else {
                throw DesktopExecutionError.actionNotGranted
            }
            let generation = structuredControlGeneration.begin()
            currentPlanStep = redactedPlanSummary(action)
            voiceStatus = currentPlanStep ?? "Running the reviewed step"
            let current = try await desktopController.observeCurrent()
            guard structuredControlPreconditionMatches(current, expected: observation) else {
                throw DesktopExecutionError.targetChanged
            }
            _ = try await structuredControlExecutor.execute(action, targetBundleIdentifier: target, isCurrent: { [structuredControlGeneration] in
                structuredControlGeneration.isCurrent(generation)
            })
            let verified = try await desktopController.observeCurrent()
            guard StructuredControlExecutor.targetMatches(expected: target, observed: verified.bundleIdentifier) else {
                throw DesktopExecutionError.targetChanged
            }
            guard !Task.isCancelled, inputEpoch.isCurrent(epoch) else { throw CancellationError() }
            desktopStatus = action.kind == .draftMessage ? "Gmail compose handoff opened" : "Reviewed URL handoff completed"
            voiceStatus = desktopStatus
            currentPlanStep = nil
            controlConversation.setPendingClarification(nil)
            controlConversation.recordVerifiedResult(desktopStatus)
            controlConversation.appendTurn(role: .assistant, text: desktopStatus)
            speakCompletion(desktopStatus)
            appendControlHistory(
                plan: redactedPlanSummary(action),
                confirmation: approved ? "approved" : nil,
                outcome: desktopStatus
            )
            return
        }
        guard action.route == .nativeAccessibility,
              let target = action.targetBundleIdentifier,
              let desktopAction = action.desktopAction else { throw DesktopExecutionError.actionNotGranted }
        if let screen { try await revalidateScreen(screen) }
        guard grant.allows(desktopAction, bundleIdentifier: target),
              desktopState == .ready else { throw DesktopExecutionError.actionNotGranted }
        voiceStatus = L10n.planSummary(action.parameters, appName: L10n.appName(target))
        let verified = try await desktopController.execute(desktopAction,
            expectedBundleIdentifier: target,
            expectedObservation: action.kind == .openApplication ? nil : observation)
        guard !Task.isCancelled, inputEpoch.isCurrent(epoch) else { throw CancellationError() }
        lastVerifiedAction = verified.undoSupport == .restoreText ? verified : nil
        desktopState = await desktopController.state
        desktopStatus = "Completed: " + L10n.actionName(desktopAction.kind)
        voiceStatus = desktopStatus
        currentPlanStep = nil
        controlConversation.setPendingClarification(nil)
        controlConversation.recordVerifiedResult(desktopStatus)
        controlConversation.appendTurn(role: .assistant, text: desktopStatus)
        speakCompletion(desktopStatus)
        appendControlHistory(
            plan: L10n.planSummary(action.parameters, appName: L10n.appName(target)),
            confirmation: approved ? "approved" : nil,
            outcome: desktopStatus
        )
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

    @discardableResult
    func executeDesktopAction(_ action: DesktopAction, expectedObservation: DesktopObservation? = nil) -> Task<Void, Never>? {
        let bundle = inputBundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bundle.isEmpty, let grant = currentInputGrant, grant.expiresAt > Date(), desktopState == .ready else {
            desktopStatus = blockedControlMessage
            voiceStatus = desktopStatus
            return nil
        }
        if action.kind == .insertText, expectedObservation == nil {
            voiceStatus = "The original text field is unavailable. Focus it and repeat your dictation."
            return nil
        }
        let epoch = inputEpoch.current
        let task = Task {
            do {
                guard inputEpoch.isCurrent(epoch), currentInputGrant != nil,
                      grant.expiresAt > Date(), desktopState == .ready else { return }
                let verified = try await desktopController.execute(action, expectedBundleIdentifier: bundle, expectedObservation: expectedObservation)
                guard inputEpoch.isCurrent(epoch), currentInputGrant != nil else { return }
                lastVerifiedAction = verified.undoSupport == .restoreText ? verified : nil
                desktopState = await desktopController.state
                desktopStatus = L10n.format("Completed %@ in %@.", L10n.actionName(action.kind), L10n.appName(bundle))
                voiceStatus = L10n.format("Completed: %@", L10n.actionName(action.kind))
                controlConversation.recordVerifiedResult(desktopStatus)
                controlConversation.appendTurn(role: .assistant, text: desktopStatus)
                speakCompletion(desktopStatus)
                appendControlHistory(
                    plan: L10n.actionName(action.kind),
                    outcome: desktopStatus
                )
            } catch {
                guard inputEpoch.isCurrent(epoch) else { return }
                desktopState = await desktopController.state
                desktopStatus = error.localizedDescription
                voiceStatus = desktopStatus
                speakFailure(desktopStatus)
                appendControlHistory(failure: desktopStatus)
            }
        }
        return task
    }

    private func startSpeechCapture(language: SpeechLanguage, purpose: SpeechSessionPurpose) async throws {
        let token = voiceGeneration
        try await speechCapture.start(language: language, purpose: purpose, onResult: { [weak self] result in
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

    private func handleShortcutDown(purpose: SpeechSessionPurpose) {
        startVoiceSession(purpose: purpose)
    }

    private func handleShortcutUp(purpose: SpeechSessionPurpose) {
        finishVoiceSession(purpose: purpose)
    }
}

func automaticPlanPrefixCount(_ actions: [NativePlanAction]) -> Int {
    actions.prefix { !$0.requiresApproval && $0.riskClass == .reversible }.count
}

func externalEffectOperationFingerprint(action: NativePlanAction) -> String {
    externalEffectRequestFingerprint(action: action)
}

func externalEffectRecoveryBlocks(_ recovery: ExternalEffectRecovery, operationFingerprint: String) -> Bool {
    recovery.operationFingerprint == operationFingerprint
}

func structuredControlPreconditionMatches(_ current: DesktopObservation, expected: DesktopObservation) -> Bool {
    guard current.bundleIdentifier == expected.bundleIdentifier else { return false }
    if let expectedElementID = expected.focusedElementID,
       current.focusedElementID != expectedElementID {
        return false
    }
    if let expectedRole = expected.focusedRole, current.focusedRole != expectedRole { return false }
    if let expectedLabel = expected.focusedLabel, current.focusedLabel != expectedLabel { return false }
    return true
}

func cloudApplicationCandidates(
    for registry: ApplicationRegistry,
    command: String,
    targetBundleIdentifier: String?
) -> [CloudApplicationCandidate] {
    var entries = registry.candidates(for: command)
    if entries.isEmpty { entries = Array(registry.entries.prefix(ApplicationRegistry.defaultCandidateLimit)) }
    if case let .resolved(namedTarget) = registry.resolveApplicationCommand(command) {
        entries.removeAll { $0.bundleIdentifier == namedTarget.bundleIdentifier }
        entries.insert(namedTarget, at: 0)
    }
    if let targetBundleIdentifier,
       let target = registry.entries.first(where: { $0.bundleIdentifier == targetBundleIdentifier }),
       !entries.contains(where: { $0.bundleIdentifier == target.bundleIdentifier }) {
        if entries.count >= ApplicationRegistry.defaultCandidateLimit { entries.removeLast() }
        entries.append(target)
    }
    return entries.prefix(ApplicationRegistry.defaultCandidateLimit).map {
        var supportedActions = $0.supportedActions.map(\.rawValue)
        if $0.integrations.contains("browser") {
            supportedActions.append(contentsOf: [
                NativePlanActionKind.openURL.rawValue,
                NativePlanActionKind.draftMessage.rawValue,
            ])
        }
        return CloudApplicationCandidate(
            bundleIdentifier: $0.bundleIdentifier,
            displayName: $0.displayName,
            normalizedNames: $0.normalizedNames,
            supportedActions: Array(Set(supportedActions)).sorted(),
            integrations: $0.integrations.sorted()
        )
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
