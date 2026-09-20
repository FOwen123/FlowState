import Foundation

public enum SpeechLanguage: String, CaseIterable, Codable, Sendable {
    case english = "en-US"
    case traditionalChinese = "zh-TW"

    public var locale: Locale { Locale(identifier: rawValue) }

    public var displayName: String {
        switch self {
        case .english: "English"
        case .traditionalChinese: "繁體中文"
        }
    }
}

public enum ActivationMode: String, CaseIterable, Codable, Sendable {
    case pushToTalk
    case toggle
    case wakePhrase

    public var displayName: String {
        switch self {
        case .pushToTalk: "Push to talk"
        case .toggle: "Toggle"
        case .wakePhrase: "Wake phrase"
        }
    }
}

public enum VoiceShortcut: String, CaseIterable, Codable, Sendable {
    case controlOptionSpace
    case controlShiftSpace
    case optionSpace

    public var displayName: String {
        switch self {
        case .controlOptionSpace: "⌃⌥ Space (may conflict)"
        case .controlShiftSpace: "⌃⇧ Space"
        case .optionSpace: "⌥ Space (legacy)"
        }
    }

    public var legacyDisplayName: String {
        switch self {
        case .controlOptionSpace: "⌃⌥ Space"
        case .controlShiftSpace: "⌃⇧ Space"
        case .optionSpace: "⌥ Space"
        }
    }

    public init?(legacyDisplayName: String) {
        switch legacyDisplayName.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "⌃⌥ Space", "Control-Option-Space": self = .controlOptionSpace
        case "⌃⇧ Space", "Control-Shift-Space": self = .controlShiftSpace
        case "⌥ Space", "Option-Space": self = .optionSpace
        default: return nil
        }
    }
}

public struct SpeechSettings: Codable, Equatable, Sendable {
    public var language: SpeechLanguage
    public var mode: VoiceMode
    public var activation: ActivationMode
    public var wakePhrase: String
    public var shortcut: VoiceShortcut

    /// Kept as a source-compatible bridge for older settings UI and persisted
    /// files. New code should read and write `shortcut`.
    public var pushToTalkKey: String {
        get { shortcut.legacyDisplayName }
        set { shortcut = VoiceShortcut(legacyDisplayName: newValue) ?? .controlShiftSpace }
    }

    public init(
        language: SpeechLanguage = .english,
        mode: VoiceMode = .command,
        activation: ActivationMode = .pushToTalk,
        wakePhrase: String = "Hey Flow State",
        pushToTalkKey: String? = nil,
        shortcut: VoiceShortcut = .controlShiftSpace
    ) {
        self.language = language
        self.mode = mode
        self.activation = activation
        self.wakePhrase = wakePhrase
        self.shortcut = pushToTalkKey.flatMap(VoiceShortcut.init(legacyDisplayName:)) ?? shortcut
    }

    private enum CodingKeys: String, CodingKey {
        case language
        case mode
        case activation
        case wakePhrase
        case shortcut
        case pushToTalkKey
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        language = try values.decodeIfPresent(SpeechLanguage.self, forKey: .language) ?? .english
        mode = try values.decodeIfPresent(VoiceMode.self, forKey: .mode) ?? .command
        activation = try values.decodeIfPresent(ActivationMode.self, forKey: .activation) ?? .pushToTalk
        wakePhrase = try values.decodeIfPresent(String.self, forKey: .wakePhrase) ?? "Hey Flow State"
        // Older files stored the conflicting Option-Space label in
        // `pushToTalkKey`; migrate those files to the safe default. An
        // explicitly encoded new `shortcut` choice remains authoritative.
        self.shortcut = try values.decodeIfPresent(VoiceShortcut.self, forKey: .shortcut)
            ?? .controlShiftSpace
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(language, forKey: .language)
        try values.encode(mode, forKey: .mode)
        try values.encode(activation, forKey: .activation)
        try values.encode(wakePhrase, forKey: .wakePhrase)
        try values.encode(shortcut, forKey: .shortcut)
        try values.encode(pushToTalkKey, forKey: .pushToTalkKey)
    }
}

public enum SpeechSettingsStore {
    private static let key = "flowstate.speech-settings.v1"

    public static func load(defaults: UserDefaults = .standard) -> SpeechSettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(SpeechSettings.self, from: data)
        else { return SpeechSettings() }
        return settings
    }

    public static func save(_ settings: SpeechSettings, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }
}

public enum SpeechSessionPhase: String, Codable, Equatable, Sendable {
    case idle
    case listening
    case stopping
    case pausedForUser
}

public struct SpeechRecognitionResult: Equatable, Sendable {
    public let transcript: String
    public let language: SpeechLanguage
    public let isFinal: Bool

    public init(transcript: String, language: SpeechLanguage, isFinal: Bool) {
        self.transcript = transcript
        self.language = language
        self.isFinal = isFinal
    }
}

public enum SpeechCaptureError: Error, Equatable, LocalizedError, Sendable {
    case unavailable
    case modelNotInstalled
    case speechPermissionDenied
    case microphonePermissionDenied
    case noInputDevice
    case alreadyRunning

    public var errorDescription: String? {
        switch self {
        case .modelNotInstalled: "Install the selected on-device language model in Voice settings first."
        case .unavailable: "Speech recognition is unavailable for this language on this Mac."
        case .speechPermissionDenied: "Speech Recognition permission is required."
        case .microphonePermissionDenied: "Microphone permission is required."
        case .noInputDevice: "No microphone input is available."
        case .alreadyRunning: "A speech session is already listening."
        }
    }
}

/// Coordinates local activation and stop behavior. It has no network dependency;
/// late provider work cannot keep a cancelled local session alive.
public actor SpeechSessionCoordinator {
    public private(set) var phase: SpeechSessionPhase = .idle
    public private(set) var settings: SpeechSettings
    public private(set) var generation: UInt64 = 0

    public init(settings: SpeechSettings = SpeechSettings()) {
        self.settings = settings
    }

    public func update(settings: SpeechSettings) {
        self.settings = settings
    }

    @discardableResult
    public func pushToTalkDown() -> UInt64 {
        guard settings.activation == .pushToTalk, phase == .idle else { return generation }
        return beginListening()
    }

    public func pushToTalkUp() {
        guard settings.activation == .pushToTalk else { return }
        if phase == .listening { phase = .stopping }
    }

    @discardableResult
    public func toggle() -> UInt64 {
        guard settings.activation == .toggle else { return generation }
        if phase == .listening {
            phase = .stopping
            return generation
        }
        return beginListening()
    }

    public func detectWakePhrase(_ transcript: String) -> Bool {
        guard settings.activation == .wakePhrase,
              phase == .idle,
              normalized(transcript) == normalized(settings.wakePhrase)
        else { return false }
        _ = beginListening()
        return true
    }

    public func consume(transcript: String, isFinal: Bool) -> VoiceCommand? {
        guard phase == .listening || phase == .stopping else { return nil }
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let command = VoiceCommandRouter.resolve(transcript, mode: settings.mode)
        if settings.mode == .command, command == .stop {
            stopLocally()
            return .stop
        }
        if isFinal { phase = .idle }
        // Partial command words are never executed. Dictation can be surfaced as a
        // partial result but callers should insert only final text.
        return isFinal || settings.mode == .dictation ? command : nil
    }

    public func localStop() {
        stopLocally()
    }

    public func pauseForUser() {
        guard phase == .listening else { return }
        phase = .pausedForUser
        generation &+= 1
    }

    public func resumeAfterUser() {
        guard phase == .pausedForUser else { return }
        generation &+= 1
        phase = .listening
    }

    private func beginListening() -> UInt64 {
        generation &+= 1
        phase = .listening
        return generation
    }

    private func stopLocally() {
        guard phase != .idle else { return }
        generation &+= 1
        phase = .idle
    }

    private func normalized(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .lowercased()
    }
}
