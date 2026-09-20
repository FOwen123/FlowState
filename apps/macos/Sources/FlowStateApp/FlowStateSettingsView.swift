import AppKit
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
        case .cloud: "Account"
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
    @ObservedObject private var localization = UILocalization.shared

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().overlay(PaperStyle.divider)
            content
        }
        .frame(minWidth: 820, minHeight: 560)
        .background(PaperStyle.canvas)
        .foregroundStyle(PaperStyle.text)
        .preferredColorScheme(.dark)
        .environment(\.locale, Locale(identifier: InterfaceLanguage.resolve(localization.language).rawValue))
        .navigationTitle(L10n.text("Flow State Settings"))
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                WaveMark()
                    .frame(width: 30, height: 30)
                Text(L10n.text("Flow State"))
                    .font(.custom("Space Grotesk", size: 20))
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
                    .padding(.horizontal, 12)
                    .frame(height: 44)
                    .background(model.settingsSection == item ? PaperStyle.raised : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
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
        .frame(width: 204)
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private var content: some View {
        switch model.settingsSection {
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

private struct VoiceSettingsView: View {
    @ObservedObject private var localization = UILocalization.shared
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
                    subtitle: "Choose whether to dictate text or control apps.",
                    selection: Binding(
                        get: { model.speechSettings.mode },
                        set: { updateMode($0) }
                    ),
                    options: VoiceMode.allCases
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
                    title: "Keyboard shortcut",
                    subtitle: "Hold to speak. Choose a shortcut unused by your other apps.",
                    selection: Binding(
                        get: { model.speechSettings.shortcut },
                        set: { updateShortcut($0) }
                    ),
                    options: VoiceShortcut.allCases
                )
                if let error = model.shortcutError {
                    Text(L10n.text(error)).font(.caption).foregroundStyle(.orange)
                }
            }

            settingsPanel {
                Text(L10n.text(model.voiceStatus)).font(.headline)
                    .accessibilityLabel(L10n.format("Voice status: %@", L10n.text(model.voiceStatus)))
                Text(model.latestTranscript.isEmpty ? L10n.text("Your transcript will appear here.") : model.latestTranscript)
                    .textSelection(.enabled)
                    .accessibilityLabel(L10n.format("Latest transcript: %@", model.latestTranscript))
                HStack {
                    Button(L10n.text("Start listening")) { model.startVoiceSession() }
                    Button(L10n.text("Finish")) { model.finishVoiceSession() }
                    Button(L10n.text("Stop")) { model.stopVoiceSession() }
                }
            }

            settingsPanel {
                Button(L10n.text("Install selected language model")) { model.installSpeechLanguage() }
                Text(L10n.text("Speech stays on this Mac. A one-time model download may be needed."))
                    .font(.caption).foregroundStyle(PaperStyle.muted)
                SettingRow(
                    title: "Microphone",
                    subtitle: "Use the Mac's selected audio input.",
                    trailing: { permissionBadge(model.permissionSnapshot.microphone) }
                )
                SettingRow(
                    title: "Speech & output",
                    subtitle: "Your speech is processed on this Mac.",
                    trailing: { Text(L10n.text("On-device")).foregroundStyle(PaperStyle.muted) }
                )
            }

            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "info.circle")
                Text(L10n.text("Flow State listens only when you start a session. Stop ends listening and cancels current actions."))
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
    @ObservedObject private var localization = UILocalization.shared
    @ObservedObject var model: FlowStateAppModel

    var body: some View {
        settingsColumn {
            pageHeading(title: "Tasks & history", subtitle: "Review what Flow State is doing before it acts.")
            settingsPanel {
                ApplicationTargetPicker(title: "App to control", selection: $model.inputBundleIdentifier)
                    .padding(.vertical, 20)
                ForEach(DesktopActionKind.allCases, id: \.rawValue) { action in
                    ToggleRow(
                        title: L10n.actionName(action),
                        subtitle: "Allow this action only for the selected target app.",
                        isOn: Binding(
                            get: { model.allowedInputActions.contains(action) },
                            set: { model.setInputAction(action, enabled: $0) }
                        )
                    )
                }
                HStack(spacing: 12) {
                    Button(model.desktopState == .reconciliationRequired ? "I've checked the result" : L10n.text("Grant desktop control")) { model.beginInputTask() }
                        .buttonStyle(PaperBorderButtonStyle())
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
            Text(L10n.text("Sensitive apps such as Passwords, Keychain and password managers remain excluded from screen capture. Full-window capture is disclosed before it is used."))
                .font(.system(size: 13))
                .foregroundStyle(PaperStyle.muted)
                .padding(16)
        }
    }

    private func explanation(for permission: MacPermission) -> String {
        switch permission {
        case .microphone: "Required only for an active speech session."
        case .speechRecognition: "Required only for an active speech session."
        case .accessibility: "Allow Flow State to control the apps you approve."
        case .screenRecording: "Allow screenshots of windows you approve during a task."
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
                Text(L10n.text(title)).font(.system(size: 16, weight: .medium))
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
                Text(L10n.text(title)).font(.system(size: 16, weight: .medium))
                Text(L10n.text(subtitle)).font(.system(size: 14)).foregroundStyle(PaperStyle.muted)
            }
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
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
                Text(L10n.text(title)).font(.system(size: 16, weight: .medium))
                Text(L10n.text(subtitle)).font(.system(size: 14)).foregroundStyle(PaperStyle.muted)
            }
            Spacer()
            Picker(L10n.text(title), selection: $selection) {
                ForEach(options, id: \.self) { option in
                    Text(L10n.text(displayName(option))).tag(option)
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
    @ObservedObject private var localization = UILocalization.shared
    let title: String
    let subtitle: String
    @Binding var text: String

    var body: some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.text(title)).font(.system(size: 16, weight: .medium))
                Text(L10n.text(subtitle)).font(.system(size: 14)).foregroundStyle(PaperStyle.muted)
            }
            Spacer()
            TextField(L10n.text(title), text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
        }
        .padding(.vertical, 20)
    }
}

private func settingsColumn(@ViewBuilder content: () -> some View) -> some View {
    ScrollView {
        VStack(alignment: .leading, spacing: 26, content: content)
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.horizontal, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 40)
    }
}

private func pageHeading(title: String, subtitle: String) -> some View {
    VStack(alignment: .leading, spacing: 8) {
        Text(L10n.text(title))
            .font(.system(size: 26, weight: .semibold))
        Text(L10n.text(subtitle))
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
        Text(L10n.text(status.isGranted ? "Ready" : status.rawValue.replacingOccurrences(of: "notDetermined", with: "Not set")))
            .font(.system(size: 12))
            .foregroundStyle(status.isGranted ? PaperStyle.secondary : PaperStyle.muted)
    }
}

struct PaperBorderButtonStyle: ButtonStyle {
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


struct ApplicationTargetPicker: View {
    let title: String
    @Binding var selection: String
    @ObservedObject private var localization = UILocalization.shared
    @State private var applications: [InstalledApplication] = []

    var body: some View {
        HStack(spacing: 12) {
            Picker(L10n.text(title), selection: $selection) {
                Text(L10n.text("Choose an app")).tag("")
                ForEach(applications) { app in
                    Text(app.name).tag(app.bundleIdentifier)
                }
                if !selection.isEmpty && !applications.contains(where: { $0.bundleIdentifier == selection }) {
                    Text(L10n.text("Previously selected app")).tag(selection)
                }
            }
            Button { refresh() } label: { Image(systemName: "arrow.clockwise") }
                .accessibilityLabel(L10n.text("Refresh app list"))
                .help("Refresh installed applications")
        }
        .onAppear { refresh() }
    }
    private func refresh() {
        applications = ApplicationCatalog.installed()
    }
}
