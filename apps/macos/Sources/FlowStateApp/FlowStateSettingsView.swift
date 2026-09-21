import FlowStateCore
import SwiftUI

enum FlowStateSettingsSection: String, CaseIterable, Identifiable {
    case voice
    case models
    case cloud
    case personalMail
    case tasks
    case memory
    case permissions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .models: "Models"
        case .personalMail: "Gmail in Brave"
        case .cloud: "Account"
        case .voice: "Voice & activation"
        case .tasks: "Tasks & history"
        case .memory: "Memory"
        case .permissions: "Permissions"
        }
    }

    var icon: String {
        switch self {
        case .models: "cpu"
        case .personalMail: "envelope"
        case .cloud: "cloud"
        case .voice: "gearshape"
        case .tasks: "waveform"
        case .memory: "rectangle.and.pencil.and.ellipsis"
        case .permissions: "checkmark.shield"
        }
    }
}

enum SettingsSpeechModel: String, CaseIterable, Identifiable {
    case appleSpeech
    case parakeet

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appleSpeech: "Apple Speech"
        case .parakeet: "Parakeet Unified English"
        }
    }

    var summary: String {
        switch self {
        case .appleSpeech: "Built into macOS and managed by Apple."
        case .parakeet: "A 731 MB English model that runs locally after download."
        }
    }

    var source: String {
        switch self {
        case .appleSpeech: "Apple"
        case .parakeet: "Hugging Face"
        }
    }

    var symbol: String {
        switch self {
        case .appleSpeech: "waveform"
        case .parakeet: "arrow.down.circle"
        }
    }

    var status: String {
        switch self {
        case .appleSpeech: "Selected"
        case .parakeet: "Coming soon"
        }
    }

    var isSelected: Bool { self == .appleSpeech }
}

enum PaperStyle {
    static let text = Color.white
    static let secondary = Color(red: 240 / 255, green: 240 / 255, blue: 240 / 255)
    static let muted = Color(red: 161 / 255, green: 164 / 255, blue: 165 / 255)
    static let divider = Color(red: 41 / 255, green: 45 / 255, blue: 48 / 255)
    static let iron = Color(red: 110 / 255, green: 114 / 255, blue: 122 / 255)

    // Native settings palette from the current Paper app screens.
    static let appCanvas = Color(red: 0x10 / 255, green: 0x11 / 255, blue: 0x13 / 255)
    static let surface = Color(red: 0x19 / 255, green: 0x1A / 255, blue: 0x1D / 255)
    static let hud = Color(red: 0x19 / 255, green: 0x22 / 255, blue: 0x1F / 255)
    static let accent = Color(red: 0x05 / 255, green: 0x96 / 255, blue: 0x69 / 255)
    static let selected = Color(red: 0x07 / 255, green: 0x1D / 255, blue: 0x17 / 255)
    static let controlBorder = Color(red: 0x53 / 255, green: 0x61 / 255, blue: 0x5A / 255)
    static let panelBorder = Color(red: 0x2C / 255, green: 0x2E / 255, blue: 0x32 / 255)
    static let input = Color(red: 0x09 / 255, green: 0x0E / 255, blue: 0x15 / 255)

    static let panelRadius: CGFloat = 20
    static let selectionRadius: CGFloat = 8
    static let controlRadius: CGFloat = 8
    static let controlFontSize: CGFloat = 14
    static let headingFontSize: CGFloat = 26

    static func textFont(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font.custom("Helvetica Neue", size: size).weight(weight)
    }
}

struct FlowStateSettingsView: View {
    @ObservedObject var model: FlowStateAppModel
    @ObservedObject private var localization = UILocalization.shared

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                sidebar
                content
            }
        }
        .padding(12)
        .frame(minWidth: 960, idealWidth: 960, minHeight: 680, idealHeight: 680)
        .background(PaperStyle.appCanvas)
        .foregroundStyle(PaperStyle.text)
        .preferredColorScheme(.dark)
        .environment(\.locale, Locale(identifier: InterfaceLanguage.resolve(localization.language).rawValue))
        .navigationTitle(L10n.text("Flow State Settings"))
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                FlowStateBrandMark(size: 30)
                    .foregroundStyle(PaperStyle.text)
                Text(L10n.text("Flow State"))
                    .font(PaperStyle.textFont(size: 20))
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 18)

            ForEach(FlowStateSettingsSection.allCases) { item in
                Button {
                    model.settingsSection = item
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: item.icon)
                            .frame(width: 20)
                        Text(L10n.text(item.title))
                            .lineLimit(1)
                            .font(.system(size: 14))
                        Spacer()
                    }
                }
                .buttonStyle(FlowStateNavigationRowStyle(isSelected: model.settingsSection == item, height: 44))
                .accessibilityLabel(L10n.text(item.title))
                .accessibilityAddTraits(model.settingsSection == item ? .isSelected : [])
            }

            Spacer()
            VStack(alignment: .leading, spacing: 8) {
                Text("Flow State 0.1")
            }
            .font(.system(size: 13))
            .foregroundStyle(PaperStyle.muted)
            .padding(.horizontal, 12)
            .padding(.vertical, 16)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 28)
        .frame(width: 220)
        .frame(maxHeight: .infinity)
        .flowStateGlassSurface(cornerRadius: 16)
    }

    @ViewBuilder
    private var content: some View {
        switch model.settingsSection {
        case .models:
            ModelsSettingsView(model: model)
        case .personalMail:
            PersonalMailView()
        case .cloud:
            CloudAccountView(model: model)
        case .voice:
            VoiceSettingsView(model: model)
        case .tasks:
            TasksSettingsView(model: model)
        case .memory:
            MemorySettingsView(model: model)
        case .permissions:
            PermissionsSettingsView(model: model)
        }
    }
}

private struct ModelsSettingsView: View {
    @ObservedObject var model: FlowStateAppModel

    var body: some View {
        settingsColumn {
            pageHeading(title: "Speech models", subtitle: "Choose how Flow State recognizes your voice.")
            settingsPanel {
                PickerRow(
                    title: "Language",
                    subtitle: "Choose the language you speak.",
                    selection: Binding(
                        get: { model.speechSettings.language },
                        set: {
                            var settings = model.speechSettings
                            settings.language = $0
                            model.updateSpeechSettings(settings)
                        }
                    ),
                    options: SpeechLanguage.allCases
                )
            }
            settingsPanel {
                ForEach(Array(SettingsSpeechModel.allCases.enumerated()), id: \.element.id) { index, option in
                    SpeechModelRow(option: option, model: model)
                    if index < SettingsSpeechModel.allCases.count - 1 {
                        Divider().overlay(PaperStyle.divider)
                    }
                }
            }
            Text(L10n.text(model.speechModelStatus))
                .font(.system(size: 13))
                .foregroundStyle(PaperStyle.muted)
            settingsPanel {
                SettingRow(
                    title: "Microphone",
                    subtitle: "Use the Mac's selected audio input.",
                    trailing: { permissionBadge(model.permissionSnapshot.microphone) }
                )
                SettingRow(
                    title: "Speech processing",
                    subtitle: "The selected model processes audio on this Mac.",
                    trailing: { Text(L10n.text("On-device")).foregroundStyle(PaperStyle.muted) }
                )
            }

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "lock.shield")
                Text(L10n.text("Audio stays on this Mac during transcription. Downloading a local model contacts its model host once for the model file."))
            }
            .font(.system(size: 13))
            .foregroundStyle(PaperStyle.muted)
        }
    }
}

private struct SpeechModelRow: View {
    let option: SettingsSpeechModel
    @ObservedObject var model: FlowStateAppModel

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: option.symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(option.isSelected ? PaperStyle.accent : PaperStyle.secondary)
                .frame(width: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(L10n.text(option.title))
                        .font(PaperStyle.textFont(size: 16, weight: .medium))
                    modelStatusBadge(option.status, emphasized: option.isSelected)
                }
                Text(L10n.text(option.summary))
                    .font(.system(size: 14))
                    .foregroundStyle(PaperStyle.muted)
                Text(L10n.format("Source: %@", option.source))
                    .font(.system(size: 12))
                    .foregroundStyle(PaperStyle.muted)
            }

            Spacer(minLength: 20)

            if option == .appleSpeech {
                Button(L10n.text("Install language asset")) { model.installSpeechLanguage() }
                    .buttonStyle(PaperBorderButtonStyle())
                    .accessibilityLabel(L10n.text("Install Apple Speech language asset"))
                    .accessibilityHint(L10n.text("Downloads Apple’s English speech asset if it is not already installed."))
            } else {
                Button(L10n.text("Download model")) { }
                    .buttonStyle(PaperBorderButtonStyle())
                    .disabled(true)
                    .help(L10n.text("Download support is coming next."))
                    .accessibilityLabel(L10n.text("Download Parakeet Unified English model"))
                    .accessibilityHint(L10n.text("Download support is coming next."))
            }
        }
        .padding(.vertical, 14)
    }
}

private func modelStatusBadge(_ text: String, emphasized: Bool) -> some View {
    Text(L10n.text(text))
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(emphasized ? PaperStyle.accent : PaperStyle.muted)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(emphasized ? PaperStyle.selected : PaperStyle.appCanvas, in: Capsule())
        .overlay(Capsule().stroke(emphasized ? PaperStyle.accent.opacity(0.35) : PaperStyle.panelBorder))
}

private struct VoiceSettingsView: View {
    @ObservedObject private var localization = UILocalization.shared
    @ObservedObject var model: FlowStateAppModel

    var body: some View {
        settingsColumn {
            pageHeading(
                title: "Voice & activation",
                subtitle: "Hold one shortcut to dictate and another to control your Mac."
            )

            settingsPanel {
                PickerRow(
                    title: "Dictation shortcut",
                    subtitle: "Hold to paste cleaned speech into the focused text field.",
                    selection: Binding(
                        get: { model.speechSettings.dictationShortcut },
                        set: { updateDictationShortcut($0) }
                    ),
                    options: VoiceShortcut.allCases
                )
                PickerRow(
                    title: "Mac Control shortcut",
                    subtitle: "Hold to control apps with a verified voice command.",
                    selection: Binding(
                        get: { model.speechSettings.controlShortcut },
                        set: { updateControlShortcut($0) }
                    ),
                    options: VoiceShortcut.allCases
                )
                if let error = model.shortcutError {
                    Text(L10n.text(error)).font(.caption).foregroundStyle(.orange)
                }
            }

            settingsPanel {
                Text(L10n.text("Spoken responses"))
                    .font(.headline)
                Picker("Voice", selection: Binding(
                    get: { model.spokenVoiceIdentifier ?? "" },
                    set: { model.setSpokenVoice($0.isEmpty ? nil : $0) }
                )) {
                    Text(L10n.text("System default")).tag("")
                    ForEach(SpokenResponseController.availableVoices(), id: \.id) { voice in
                        Text("\(voice.name) (\(voice.locale))").tag(voice.id)
                    }
                }
                .pickerStyle(.menu)
                ToggleRow(
                    title: "Spoken task updates",
                    subtitle: "Speak questions, meaningful milestones, failures, and verified completion.",
                    isOn: Binding(
                        get: { !model.spokenResponsesMuted },
                        set: { model.setSpokenResponsesMuted(!$0) }
                    )
                )
                Button(L10n.text("Replay last response")) { model.replayLastSpokenResponse() }
                    .buttonStyle(PaperBorderButtonStyle())
                    .disabled(model.lastSpokenResponse == nil)
            }

            settingsPanel {
                ToggleRow(
                    title: "Dictation cleanup",
                    subtitle: "Apply conservative local cleanup before pasting. Managed cleanup, when configured, is text-only and time-bounded.",
                    isOn: Binding(
                        get: { model.dictationCleanupEnabled },
                        set: { model.setDictationCleanup(enabled: $0) }
                    )
                )
                TextFieldRow(
                    title: "Cleanup instructions",
                    subtitle: "Optional guidance for formatting only; it cannot authorize actions.",
                    text: Binding(
                        get: { model.dictationCleanupInstructions },
                        set: { model.setDictationCleanupInstructions($0) }
                    )
                )
            }

            settingsPanel {
                Text(L10n.text(model.voiceStatus)).font(.headline)
                    .accessibilityLabel(L10n.format("Voice status: %@", L10n.text(model.voiceStatus)))
                Text(model.latestTranscript.isEmpty ? L10n.text("Your transcript will appear here.") : model.latestTranscript)
                    .textSelection(.enabled)
                    .accessibilityLabel(L10n.format("Latest transcript: %@", model.latestTranscript))
                HStack {
                    Button(L10n.text("Start listening")) { model.startVoiceSession() }
                        .disabled(model.isListening || model.isFinishingVoice)
                    Button(L10n.text("Stop")) { model.stopVoiceSession() }
                }
            }

            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "info.circle")
                Text(L10n.text("Hold Dictation to enter text. Hold Mac Control to control your Mac. Release either shortcut to finish."))
                    .font(.system(size: 13))
                    .foregroundStyle(PaperStyle.muted)
            }
            .padding(16)
            .background(PaperStyle.surface)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(PaperStyle.panelBorder))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private func updateDictationShortcut(_ value: VoiceShortcut) {
        var settings = model.speechSettings
        settings.dictationShortcut = value
        model.updateSpeechSettings(settings)
    }

    private func updateControlShortcut(_ value: VoiceShortcut) {
        var settings = model.speechSettings
        settings.controlShortcut = value
        model.updateSpeechSettings(settings)
    }
}

private struct TasksSettingsView: View {
    @ObservedObject private var localization = UILocalization.shared
    @ObservedObject var model: FlowStateAppModel

    var body: some View {
        settingsColumn {
            pageHeading(title: "Tasks & history", subtitle: "Review what Flow State is doing before it acts.")
            settingsPanel {
                SettingRow(
                    title: "Desktop control",
                    subtitle: "Uses the active app or the app named in your command.",
                    trailing: { Image(systemName: "rectangle.on.rectangle") }
                )
                ForEach(DesktopActionKind.allCases, id: \.rawValue) { action in
                    ToggleRow(
                        title: L10n.actionName(action),
                        subtitle: "Allow this desktop action during an active task.",
                        isOn: Binding(
                            get: { model.allowedInputActions.contains(action) },
                            set: { model.setInputAction(action, enabled: $0) }
                        )
                    )
                }
                ToggleRow(
                    title: "Allow cloud screen context",
                    subtitle: "When needed, a permitted window may be sent to the cloud for interpretation. This is separate from Screen Recording permission.",
                    isOn: $model.allowCloudScreenContext
                )
                HStack(spacing: 12) {
                    Button(L10n.text("New task")) { model.startNewControlTask() }
                        .buttonStyle(PaperBorderButtonStyle())
                    if model.desktopState == .reconciliationRequired {
                        Button("I've checked the result") { model.beginInputTask() }
                            .buttonStyle(PaperBorderButtonStyle())
                    }
                    Button(L10n.text("Cancel")) { model.cancelInputTask() }
                        .buttonStyle(PaperBorderButtonStyle())
                    Button(L10n.text("Resume")) { model.resumeInputTask() }
                        .disabled(model.desktopState != .pausedForUser)
                        .buttonStyle(PaperBorderButtonStyle())
                    Button(L10n.text("Undo last edit")) { model.undoLastDesktopAction() }
                        .buttonStyle(PaperBorderButtonStyle())
                }
                Text(L10n.text(model.desktopStatus))
                    .font(.system(size: 13))
                    .foregroundStyle(model.desktopState == .pausedForUser ? .orange : PaperStyle.muted)
                    .padding(.vertical, 12)
            }
            settingsPanel {
                SettingRow(title: "Current voice session", subtitle: model.voiceStatus, trailing: { Image(systemName: "waveform") })
                SettingRow(title: "Current desktop task", subtitle: model.taskStatus, trailing: { Image(systemName: "rectangle.on.rectangle") })
            }
            settingsPanel {
                Text(L10n.text("History retention")).font(.headline)
                Stepper(
                    L10n.format("Dictation: %.0f days", model.dictationRetentionDays),
                    value: Binding(
                        get: { model.dictationRetentionDays },
                        set: { model.setDictationRetentionDays($0) }
                    ),
                    in: 1...3650,
                    step: 1
                )
                Stepper(
                    L10n.format("Mac Control: %.0f days", model.controlRetentionDays),
                    value: Binding(
                        get: { model.controlRetentionDays },
                        set: { model.setControlRetentionDays($0) }
                    ),
                    in: 1...3650,
                    step: 1
                )
            }
            if let recovery = model.dictationRecovery {
                settingsPanel {
                    Text(L10n.text("Dictation needs attention")).font(.headline)
                    Text(recovery.text).textSelection(.enabled)
                    Text(recovery.reason)
                        .font(.caption)
                        .foregroundStyle(.orange)
                    HStack(spacing: 12) {
                        Button(L10n.text("Copy")) { model.copyDictationRecovery() }
                            .buttonStyle(PaperBorderButtonStyle())
                        Button(L10n.text("Retry original field")) { model.retryDictationRecovery() }
                            .buttonStyle(PaperBorderButtonStyle())
                        Button(L10n.text("Dismiss")) { model.dismissDictationRecovery() }
                            .buttonStyle(PaperBorderButtonStyle())
                    }
                    Text(L10n.format("Available for %@", recovery.expiresAt.formatted(date: .omitted, time: .shortened)))
                        .font(.caption)
                        .foregroundStyle(PaperStyle.muted)
                }
            }
            settingsPanel {
                HStack {
                    Text(L10n.text("Control history"))
                        .font(.headline)
                    Spacer()
                    Button(L10n.text("Delete all")) { model.deleteAllControlHistory() }
                        .buttonStyle(PaperBorderButtonStyle())
                        .disabled(model.controlHistory.isEmpty)
                }
                ForEach(model.controlHistory) { entry in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(entry.request).textSelection(.enabled)
                        if let plan = entry.approvedPlan {
                            Text(plan).foregroundStyle(PaperStyle.muted)
                        }
                        ForEach(entry.stepOutcomes, id: \.self) { outcome in
                            Text(outcome).font(.caption).foregroundStyle(PaperStyle.muted)
                        }
                        if let failure = entry.failureReason {
                            Text(failure).font(.caption).foregroundStyle(.orange)
                        }
                        Button(L10n.text("Delete")) { model.deleteControlHistory(id: entry.id) }
                            .buttonStyle(PaperBorderButtonStyle())
                    }
                    .padding(.vertical, 10)
                    Divider().overlay(PaperStyle.divider)
                }
                if model.controlHistory.isEmpty {
                    Text(L10n.text("No control tasks yet.")).foregroundStyle(PaperStyle.muted)
                }
            }
            settingsPanel {
                HStack {
                    Text(L10n.text("Dictation history"))
                        .font(.headline)
                    Spacer()
                    Button(L10n.text("Delete all")) { model.deleteAllDictationHistory() }
                        .buttonStyle(PaperBorderButtonStyle())
                        .disabled(model.dictationHistory.isEmpty)
                }
                ForEach(model.dictationHistory) { entry in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(entry.text)
                            .textSelection(.enabled)
                        if let failureReason = entry.failureReason {
                            Text(L10n.format("Not inserted: %@", failureReason))
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        HStack {
                            Button(L10n.text("Copy")) { model.copyDictationHistory(entry) }
                                .buttonStyle(PaperBorderButtonStyle())
                            Button(L10n.text("Delete")) { model.deleteDictationHistory(id: entry.id) }
                                .buttonStyle(PaperBorderButtonStyle())
                        }
                    }
                    .padding(.vertical, 10)
                    Divider().overlay(PaperStyle.divider)
                }
                if model.dictationHistory.isEmpty {
                    Text(L10n.text("No dictations yet."))
                        .foregroundStyle(PaperStyle.muted)
                }
            }
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "clock.arrow.circlepath")
                Text(L10n.text("Sign in to view cloud tasks. Reconnecting will not repeat completed actions."))
                    .font(.system(size: 13))
                    .foregroundStyle(PaperStyle.muted)
            }
        }
    }
}

private struct MemorySettingsView: View {
    @ObservedObject private var localization = UILocalization.shared
    @ObservedObject var model: FlowStateAppModel
    @State private var trigger = ""
    @State private var value = ""
    @State private var category: MemoryCategory = .vocabulary

    var body: some View {
        settingsColumn {
            HStack(alignment: .top) {
                pageHeading(title: "Memory", subtitle: "Your words. Your preferences. Always editable.")
                Spacer()
                Button(L10n.text("Add preference")) { addPreference() }
                    .buttonStyle(PaperBorderButtonStyle())
                    .disabled(trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            settingsPanel {
                TextFieldRow(title: "When I say", subtitle: "A phrase you want Flow State to remember.", text: $trigger)
                TextFieldRow(title: "Use", subtitle: "The preferred word, app or style.", text: $value)
                PickerRow(title: "Category", subtitle: "Your saved preferences take priority.", selection: $category, options: MemoryCategory.allCases)
            }

            settingsPanel {
                ForEach(model.memorySnapshot.preferences) { preference in
                    HStack(spacing: 16) {
                        Text(preference.trigger)
                            .frame(width: 160, alignment: .leading)
                        Text(preference.value)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(L10n.text(preference.source == .explicit ? "Saved by you" : "Suggested"))
                            .font(.system(size: 12))
                            .foregroundStyle(PaperStyle.muted)
                        Button(L10n.text("Delete")) { model.deleteMemory(id: preference.id) }
                            .buttonStyle(PaperBorderButtonStyle())
                    }
                    .font(.system(size: 14))
                    .padding(.vertical, 12)
                    Divider().overlay(PaperStyle.divider)
                }
                if model.memorySnapshot.preferences.isEmpty {
                    Text(L10n.text("No preferences saved yet."))
                        .foregroundStyle(PaperStyle.muted)
                        .padding(.vertical, 16)
                }
            }

            settingsPanel {
                ToggleRow(
                    title: "Sync preferences",
                    subtitle: "Not available yet. Preferences currently stay on this Mac.",
                    isOn: Binding(
                        get: { false },
                        set: { _ in }
                    )
                )
                ToggleRow(
                    title: "Allow learned preferences",
                    subtitle: "Automatic suggestions are not available yet. Your saved preferences take priority.",
                    isOn: Binding(
                        get: { model.memorySnapshot.learningEnabled },
                        set: { model.setMemoryLearning($0) }
                    )
                )
            }
        }
    }

    private func addPreference() {
        model.addMemory(trigger: trigger, value: value, category: category)
        trigger = ""
        value = ""
    }
}

private struct PermissionsSettingsView: View {
    @ObservedObject private var localization = UILocalization.shared
    @ObservedObject var model: FlowStateAppModel

    var body: some View {
        settingsColumn {
            pageHeading(title: "Permissions", subtitle: "Choose what Flow State can access on your Mac.")
            settingsPanel {
                ForEach(MacPermission.allCases.filter { $0 != .speechRecognition }, id: \.rawValue) { permission in
                    SettingRow(
                        title: permission.displayName,
                        subtitle: explanation(for: permission),
                        trailing: { HStack(spacing: 10) {
                            permissionBadge(model.permissionSnapshot[permission])
                            Button(L10n.text("Manage")) { model.requestPermission(permission) }
                                .buttonStyle(PaperBorderButtonStyle())
                        } }
                    )
                }
            }
            Text(L10n.text("Screen Recording lets Flow State observe permitted windows on this Mac. The separate cloud screen context setting controls whether a captured window may be uploaded for interpretation. Sensitive apps such as Passwords, Keychain and password managers remain excluded from screen capture."))
                .font(.system(size: 13))
                .foregroundStyle(PaperStyle.muted)
                .padding(16)
        }
    }

    private func explanation(for permission: MacPermission) -> String {
        switch permission {
        case .microphone: "Required only for an active speech session."
        case .speechRecognition: "Required only for an active speech session."
        case .accessibility: "Allow Flow State to control the active app or an app named in your command."
        case .screenRecording: "Allow Flow State to observe the active app or an app named in your command."
        }
    }
}

private struct SettingRow<Trailing: View>: View {
    @ObservedObject private var localization = UILocalization.shared
    let title: String
    let subtitle: String
    let trailing: Trailing

    init(title: String, subtitle: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.text(title)).font(.custom("Helvetica Neue", size: 16).weight(.medium))
                Text(L10n.text(subtitle)).font(.system(size: 14)).foregroundStyle(PaperStyle.muted)
            }
            Spacer()
            trailing
        }
        .padding(.vertical, 20)
    }
}

private struct ToggleRow: View {
    @ObservedObject private var localization = UILocalization.shared
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.text(title)).font(PaperStyle.textFont(size: 16, weight: .medium))
                Text(L10n.text(subtitle)).font(.system(size: 14)).foregroundStyle(PaperStyle.muted)
            }
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(PaperStyle.accent)
                .accessibilityLabel(L10n.text(title))
        }
        .padding(.vertical, 20)
    }
}

private struct PickerRow<Value: Hashable & CaseIterable & RawRepresentable>: View where Value.RawValue: StringProtocol {
    @ObservedObject private var localization = UILocalization.shared
    let title: String
    let subtitle: String
    @Binding var selection: Value
    let options: [Value]

    init(title: String, subtitle: String, selection: Binding<Value>, options: [Value]) {
        self.title = title
        self.subtitle = subtitle
        _selection = selection
        self.options = options
    }

    var body: some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.text(title)).font(PaperStyle.textFont(size: 16, weight: .medium))
                Text(L10n.text(subtitle)).font(.system(size: 14)).foregroundStyle(PaperStyle.muted)
            }
            Spacer()
            Picker(L10n.text(title), selection: $selection) {
                ForEach(options, id: \.self) { option in
                    Text(L10n.text(displayName(option))).tag(option)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .font(PaperStyle.textFont(size: PaperStyle.controlFontSize))
            .frame(width: 180)
        }
        .padding(.vertical, 20)
    }

    private func displayName(_ option: Value) -> String {
        if let value = option as? VoiceShortcut { return value.displayName }
        if let value = option as? ActivationMode { return value.displayName }
        if let value = option as? SpeechLanguage { return value.displayName }
        if let value = option as? MemoryCategory { return value.displayName }
        if let value = option as? VoiceMode { return value.rawValue.capitalized }
        return String(option.rawValue)
    }
}

private struct TextFieldRow: View {
    @ObservedObject private var localization = UILocalization.shared
    let title: String
    let subtitle: String
    @Binding var text: String

    var body: some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.text(title)).font(.custom("Helvetica Neue", size: 16).weight(.medium))
                Text(L10n.text(subtitle)).font(.system(size: 14)).foregroundStyle(PaperStyle.muted)
            }
            Spacer()
            TextField(L10n.text(title), text: $text)
                .textFieldStyle(.plain)
                .modifier(PaperInputStyle())
                .frame(width: 220)
        }
        .padding(.vertical, 20)
    }
}

private func settingsColumn(@ViewBuilder content: () -> some View) -> some View {
    ScrollView {
        VStack(alignment: .leading, spacing: 26, content: content)
            .frame(maxWidth: 756, alignment: .leading)
            .padding(.horizontal, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 40)
    }
    .background(PaperStyle.appCanvas)
}

private func pageHeading(title: String, subtitle: String) -> some View {
    VStack(alignment: .leading, spacing: 8) {
        Text(L10n.text(title))
            .font(PaperStyle.textFont(size: PaperStyle.headingFontSize, weight: .medium))
        Text(L10n.text(subtitle))
            .font(.system(size: 15))
            .foregroundStyle(PaperStyle.muted)
    }
}

private func settingsPanel<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 0, content: content)
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PaperStyle.surface)
        .overlay(RoundedRectangle(cornerRadius: PaperStyle.panelRadius).stroke(PaperStyle.panelBorder))
        .clipShape(RoundedRectangle(cornerRadius: PaperStyle.panelRadius))
}

private func permissionBadge(_ status: MacPermissionStatus) -> some View {
    HStack(spacing: 6) {
        Circle()
            .fill(status.isGranted ? PaperStyle.accent : PaperStyle.iron)
            .frame(width: 7, height: 7)
        Text(L10n.text(status.isGranted ? "Ready" : status.rawValue.replacingOccurrences(of: "notDetermined", with: "Not set")))
            .font(.system(size: 12))
            .foregroundStyle(status.isGranted ? PaperStyle.secondary : PaperStyle.muted)
    }
}

struct PaperBorderButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(PaperStyle.textFont(size: PaperStyle.controlFontSize))
            .foregroundStyle(PaperStyle.text)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .contentShape(RoundedRectangle(cornerRadius: PaperStyle.controlRadius))
            .overlay(RoundedRectangle(cornerRadius: PaperStyle.controlRadius).stroke(PaperStyle.controlBorder))
            .glassEffect(
                .regular
                    .tint(configuration.isPressed ? PaperStyle.selected : PaperStyle.surface)
                    .interactive(),
                in: RoundedRectangle(cornerRadius: PaperStyle.controlRadius)
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.65 : 1) : 0.4)
    }
}

struct FlowStateNavigationRowStyle: ButtonStyle {
    let isSelected: Bool
    let height: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration, isSelected: isSelected, height: height)
    }

    private struct Row: View {
        let configuration: ButtonStyleConfiguration
        let isSelected: Bool
        let height: CGFloat
        @State private var isHovering = false

        private var isHighlighted: Bool { isSelected || isHovering || configuration.isPressed }

        var body: some View {
            configuration.label
                .font(PaperStyle.textFont(size: PaperStyle.controlFontSize, weight: .medium))
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .leading)
                .foregroundStyle(isHighlighted ? PaperStyle.accent : PaperStyle.text)
                .background(isHighlighted ? PaperStyle.selected : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
                .onHover { isHovering = $0 }
        }
    }
}

private struct FlowStateGlassSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let cornerRadius: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        if reduceTransparency {
            content
                .background(PaperStyle.hud, in: shape)
                .overlay(shape.stroke(PaperStyle.controlBorder.opacity(0.7)))
        } else {
            content
                .background(PaperStyle.hud.opacity(0.5), in: shape)
                .overlay(shape.stroke(PaperStyle.controlBorder.opacity(0.55)))
                .glassEffect(.regular.tint(PaperStyle.hud), in: shape)
        }
    }
}

extension View {
    func flowStateGlassSurface(cornerRadius: CGFloat) -> some View {
        modifier(FlowStateGlassSurface(cornerRadius: cornerRadius))
    }
}

struct PaperInputStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(PaperStyle.textFont(size: PaperStyle.controlFontSize))
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(PaperStyle.input)
            .overlay(RoundedRectangle(cornerRadius: PaperStyle.controlRadius).stroke(PaperStyle.controlBorder.opacity(0.55)))
            .clipShape(RoundedRectangle(cornerRadius: PaperStyle.controlRadius))
    }
}
