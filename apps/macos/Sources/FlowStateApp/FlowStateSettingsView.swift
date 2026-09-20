import FlowStateCore
import SwiftUI

enum FlowStateSettingsSection: String, CaseIterable, Identifiable {
    case voice
    case cloud
    case personalMail
    case tasks
    case memory
    case permissions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .personalMail: "Gmail in Brave"
        case .cloud: "Cloud account / 雲端帳戶"
        case .voice: "Voice & activation"
        case .tasks: "Tasks & history"
        case .memory: "Memory"
        case .permissions: "Permissions"
        }
    }

    var icon: String {
        switch self {
        case .personalMail: "envelope"
        case .cloud: "cloud"
        case .voice: "gearshape"
        case .tasks: "waveform"
        case .memory: "rectangle.and.pencil.and.ellipsis"
        case .permissions: "checkmark.shield"
        }
    }
}

enum PaperStyle {
    static let canvas = Color(red: 0, green: 0, blue: 0)
    static let raised = Color(red: 11 / 255, green: 14 / 255, blue: 20 / 255)
    static let text = Color.white
    static let secondary = Color(red: 240 / 255, green: 240 / 255, blue: 240 / 255)
    static let muted = Color(red: 161 / 255, green: 164 / 255, blue: 165 / 255)
    static let divider = Color(red: 41 / 255, green: 45 / 255, blue: 48 / 255)
    static let iron = Color(red: 110 / 255, green: 114 / 255, blue: 122 / 255)
}

struct FlowStateSettingsView: View {
    @ObservedObject var model: FlowStateAppModel
    @State private var section: FlowStateSettingsSection = .voice

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().overlay(PaperStyle.divider)
            content
        }
        .frame(minWidth: 960, minHeight: 700)
        .background(PaperStyle.canvas)
        .foregroundStyle(PaperStyle.text)
        .preferredColorScheme(.dark)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                WaveMark()
                    .frame(width: 30, height: 30)
                Text("Flow State")
                    .font(.custom("Space Grotesk", size: 20))
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 18)

            ForEach(FlowStateSettingsSection.allCases) { item in
                Button {
                    section = item
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: item.icon)
                            .frame(width: 20)
                        Text(item.title)
                            .font(.system(size: 14))
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 44)
                    .background(section == item ? PaperStyle.raised : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.title)
                .accessibilityAddTraits(section == item ? .isSelected : [])
            }

            Spacer()
            VStack(alignment: .leading, spacing: 14) {
                Text("Help & feedback ↗")
                Text("Flow State · Development preview")
            }
            .font(.system(size: 13))
            .foregroundStyle(PaperStyle.muted)
            .padding(.horizontal, 12)
            .padding(.vertical, 16)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 28)
        .frame(width: 224)
    }

    @ViewBuilder
    private var content: some View {
        switch section {
        case .personalMail:
            PersonalMailView()
        case .cloud:
            ScrollView { CloudAccountView(model: model) }
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

private struct VoiceSettingsView: View {
    @ObservedObject var model: FlowStateAppModel

    var body: some View {
        settingsColumn {
            pageHeading(
                title: "Voice & activation",
                subtitle: "Speak naturally. Decide when Flow State listens."
            )

            settingsPanel {
                PickerRow(
                    title: "Activation",
                    subtitle: "Push to talk keeps every session explicit.",
                    selection: Binding(
                        get: { model.speechSettings.activation },
                        set: { updateActivation($0) }
                    ),
                    options: ActivationMode.allCases
                )
                PickerRow(
                    title: "Voice mode",
                    subtitle: "Command words execute only in command mode.",
                    selection: Binding(
                        get: { model.speechSettings.mode },
                        set: { updateMode($0) }
                    ),
                    options: VoiceMode.allCases
                )
                PickerRow(
                    title: "Language",
                    subtitle: "English and Traditional Chinese are explicit launch languages.",
                    selection: Binding(
                        get: { model.speechSettings.language },
                        set: { updateLanguage($0) }
                    ),
                    options: SpeechLanguage.allCases
                )
                if model.speechSettings.activation == .wakePhrase {
                    TextFieldRow(
                        title: "Wake phrase",
                        subtitle: "Wake phrase detection is local and configurable.",
                        text: Binding(
                            get: { model.speechSettings.wakePhrase },
                            set: { updateWakePhrase($0) }
                        )
                    )
                }
                PickerRow(
                    title: "Keyboard shortcut / 鍵盤快捷鍵",
                    subtitle: "Hold to speak. Choose a shortcut unused by your other apps.",
                    selection: Binding(
                        get: { model.speechSettings.shortcut },
                        set: { updateShortcut($0) }
                    ),
                    options: VoiceShortcut.allCases
                )
                if let error = model.shortcutError {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
            }

            settingsPanel {
                Text(model.voiceStatus).font(.headline)
                    .accessibilityLabel("Voice status: \(model.voiceStatus)")
                Text(model.latestTranscript.isEmpty ? "Your transcript will appear here. / 辨識文字將顯示在此。" : model.latestTranscript)
                    .textSelection(.enabled)
                    .accessibilityLabel("Latest transcript: \(model.latestTranscript)")
                HStack {
                    Button("Start listening / 開始聆聽") { model.startVoiceSession() }
                    Button("Finish / 完成") { model.finishVoiceSession() }
                    Button("Stop / 停止") { model.stopVoiceSession() }
                }
            }

            settingsPanel {
                Button("Install selected language model / 安裝所選語言模型") { model.installSpeechLanguage() }
                Text("Speech stays on this Mac. A one-time model download may be needed. / 語音只在本機處理。")
                    .font(.caption).foregroundStyle(PaperStyle.muted)
                SettingRow(
                    title: "Microphone",
                    subtitle: "Use the Mac's selected audio input.",
                    trailing: { permissionBadge(model.permissionSnapshot.microphone) }
                )
                SettingRow(
                    title: "Speech & output",
                    subtitle: "SpeechAnalyzer processes active-session audio on this Mac.",
                    trailing: { Text("On-device").foregroundStyle(PaperStyle.muted) }
                )
            }

            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "info.circle")
                Text("Flow State does not listen while idle. Stop is handled on this Mac before any cloud workflow can continue.")
                    .font(.system(size: 13))
                    .foregroundStyle(PaperStyle.muted)
            }
            .padding(16)
            .background(PaperStyle.raised.opacity(0.65))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private func updateActivation(_ value: ActivationMode) {
        var settings = model.speechSettings
        settings.activation = value
        model.updateSpeechSettings(settings)
    }

    private func updateMode(_ value: VoiceMode) {
        var settings = model.speechSettings
        settings.mode = value
        model.updateSpeechSettings(settings)
    }

    private func updateLanguage(_ value: SpeechLanguage) {
        var settings = model.speechSettings
        settings.language = value
        model.updateSpeechSettings(settings)
    }

    private func updateWakePhrase(_ value: String) {
        var settings = model.speechSettings
        settings.wakePhrase = value
        model.updateSpeechSettings(settings)
    }

    private func updateShortcut(_ value: VoiceShortcut) {
        var settings = model.speechSettings
        settings.shortcut = value
        model.updateSpeechSettings(settings)
    }
}

private struct TasksSettingsView: View {
    @ObservedObject var model: FlowStateAppModel

    var body: some View {
        settingsColumn {
            pageHeading(title: "Tasks & history", subtitle: "Review what Flow State is doing before it acts.")
            settingsPanel {
                TextFieldRow(
                    title: "Input grant target",
                    subtitle: "This app is separate from screen capture and must be approved explicitly.",
                    text: $model.inputBundleIdentifier
                )
                ForEach(DesktopActionKind.allCases, id: \.rawValue) { action in
                    ToggleRow(
                        title: action.rawValue.capitalized,
                        subtitle: "Allow this action only for the selected target app.",
                        isOn: Binding(
                            get: { model.allowedInputActions.contains(action) },
                            set: { model.setInputAction(action, enabled: $0) }
                        )
                    )
                }
                HStack(spacing: 12) {
                    Button("Grant desktop control") { model.beginInputTask() }
                        .buttonStyle(PaperBorderButtonStyle())
                    Button("Cancel") { model.cancelInputTask() }
                        .buttonStyle(PaperBorderButtonStyle())
                    Button("Resume") { model.resumeInputTask() }
                        .buttonStyle(PaperBorderButtonStyle())
                    Button("Undo last edit") { model.undoLastDesktopAction() }
                        .buttonStyle(PaperBorderButtonStyle())
                }
                Text(model.desktopStatus)
                    .font(.system(size: 13))
                    .foregroundStyle(model.desktopState == .pausedForUser ? .orange : PaperStyle.muted)
                    .padding(.vertical, 12)
            }
            settingsPanel {
                SettingRow(title: "Current voice session", subtitle: model.voiceStatus, trailing: { Image(systemName: "waveform") })
                SettingRow(title: "Current desktop task", subtitle: model.taskStatus, trailing: { Image(systemName: "rectangle.on.rectangle") })
            }
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "clock.arrow.circlepath")
                Text("Task history is read-only until a managed Convex session is connected. A reconnect never replays a native action.")
                    .font(.system(size: 13))
                    .foregroundStyle(PaperStyle.muted)
            }
        }
    }
}

private struct MemorySettingsView: View {
    @ObservedObject var model: FlowStateAppModel
    @State private var trigger = ""
    @State private var value = ""
    @State private var category: MemoryCategory = .vocabulary

    var body: some View {
        settingsColumn {
            HStack(alignment: .top) {
                pageHeading(title: "Memory", subtitle: "Your words. Your preferences. Always editable.")
                Spacer()
                Button("Add preference") { addPreference() }
                    .buttonStyle(PaperBorderButtonStyle())
                    .disabled(trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            settingsPanel {
                TextFieldRow(title: "When I say", subtitle: "A phrase you want Flow State to remember.", text: $trigger)
                TextFieldRow(title: "Use", subtitle: "The preferred word, app or style.", text: $value)
                PickerRow(title: "Category", subtitle: "Explicit entries always take precedence.", selection: $category, options: MemoryCategory.allCases)
            }

            settingsPanel {
                ForEach(model.memorySnapshot.preferences) { preference in
                    HStack(spacing: 16) {
                        Text(preference.trigger)
                            .frame(width: 160, alignment: .leading)
                        Text(preference.value)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(preference.source == .explicit ? "You told me" : "Learned")
                            .font(.system(size: 12))
                            .foregroundStyle(PaperStyle.muted)
                        Button("Delete") { model.deleteMemory(id: preference.id) }
                            .buttonStyle(PaperBorderButtonStyle())
                    }
                    .font(.system(size: 14))
                    .padding(.vertical, 12)
                    Divider().overlay(PaperStyle.divider)
                }
                if model.memorySnapshot.preferences.isEmpty {
                    Text("No preferences saved yet.")
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
                    subtitle: "Opt-in only. Automatic learning is not connected yet; explicit entries take precedence.",
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
    @ObservedObject var model: FlowStateAppModel

    var body: some View {
        settingsColumn {
            pageHeading(title: "Permissions", subtitle: "Grant access per capability. Flow State asks only when you choose.")
            settingsPanel {
                ForEach(MacPermission.allCases.filter { $0 != .speechRecognition }, id: \.rawValue) { permission in
                    SettingRow(
                        title: permission.displayName,
                        subtitle: explanation(for: permission),
                        trailing: { HStack(spacing: 10) {
                            permissionBadge(model.permissionSnapshot[permission])
                            Button("Manage") { model.requestPermission(permission) }
                                .buttonStyle(PaperBorderButtonStyle())
                        } }
                    )
                }
            }
            Text("Sensitive apps such as Passwords, Keychain and password managers remain excluded from screen capture. Full-window capture is disclosed before it is used.")
                .font(.system(size: 13))
                .foregroundStyle(PaperStyle.muted)
                .padding(16)
        }
    }

    private func explanation(for permission: MacPermission) -> String {
        switch permission {
        case .microphone: "Required only for an active speech session."
        case .speechRecognition: "Legacy server-recognition permission; not used by SpeechAnalyzer."
        case .accessibility: "Required for approved focus, press, scroll and text actions."
        case .screenRecording: "Required only for an approved task's selected window."
        }
    }
}

private struct SettingRow<Trailing: View>: View {
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
                Text(title).font(.system(size: 16, weight: .medium))
                Text(subtitle).font(.system(size: 14)).foregroundStyle(PaperStyle.muted)
            }
            Spacer()
            trailing
        }
        .padding(.vertical, 20)
    }
}

private struct ToggleRow: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 16, weight: .medium))
                Text(subtitle).font(.system(size: 14)).foregroundStyle(PaperStyle.muted)
            }
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel(title)
        }
        .padding(.vertical, 20)
    }
}

private struct PickerRow<Value: Hashable & CaseIterable & RawRepresentable>: View where Value.RawValue: StringProtocol {
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
                Text(title).font(.system(size: 16, weight: .medium))
                Text(subtitle).font(.system(size: 14)).foregroundStyle(PaperStyle.muted)
            }
            Spacer()
            Picker(title, selection: $selection) {
                ForEach(options, id: \.self) { option in
                    Text(displayName(option)).tag(option)
                }
            }
            .pickerStyle(.menu)
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
    let title: String
    let subtitle: String
    @Binding var text: String

    var body: some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 16, weight: .medium))
                Text(subtitle).font(.system(size: 14)).foregroundStyle(PaperStyle.muted)
            }
            Spacer()
            TextField(title, text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
        }
        .padding(.vertical, 20)
    }
}

private func settingsColumn(@ViewBuilder content: () -> some View) -> some View {
    ScrollView {
        VStack(alignment: .leading, spacing: 26, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 48)
            .padding(.vertical, 40)
    }
}

private func pageHeading(title: String, subtitle: String) -> some View {
    VStack(alignment: .leading, spacing: 8) {
        Text(title)
            .font(.custom("Space Grotesk", size: 32))
        Text(subtitle)
            .font(.system(size: 15))
            .foregroundStyle(PaperStyle.muted)
    }
}

private func settingsPanel<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 0, content: content)
        .padding(.horizontal, 24)
        .background(PaperStyle.canvas)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(PaperStyle.divider))
        .clipShape(RoundedRectangle(cornerRadius: 16))
}

private func permissionBadge(_ status: MacPermissionStatus) -> some View {
    HStack(spacing: 6) {
        Circle()
            .fill(status.isGranted ? Color.green : PaperStyle.iron)
            .frame(width: 7, height: 7)
        Text(status.isGranted ? "Ready" : status.rawValue.replacingOccurrences(of: "notDetermined", with: "Not set"))
            .font(.system(size: 12))
            .foregroundStyle(status.isGranted ? PaperStyle.secondary : PaperStyle.muted)
    }
}

private struct PaperBorderButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .foregroundStyle(PaperStyle.text)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(PaperStyle.iron))
            .opacity(configuration.isPressed ? 0.65 : 1)
    }
}

private struct WaveMark: View {
    var body: some View {
        HStack(spacing: 3) {
            ForEach([12.0, 22.0, 30.0, 22.0, 12.0], id: \.self) { height in
                Capsule()
                    .fill(PaperStyle.secondary)
                    .frame(width: 3, height: height)
            }
        }
        .accessibilityHidden(true)
    }
}
