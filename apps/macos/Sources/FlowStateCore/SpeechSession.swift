import Foundation

public enum SpeechLanguage: String, CaseIterable, Codable, Sendable {
    case english = "en-US"
    /// Source-compatible legacy case. Decoding and persisted settings migrate
    /// it to English; it is excluded from the active picker.
    @available(*, deprecated, message: "Traditional Chinese speech is no longer supported; use English.")
    case traditionalChinese = "zh-TW"

    public static var allCases: [SpeechLanguage] { [.english] }

    public var locale: Locale { .init(identifier: rawValue == "zh-TW" ? Self.english.rawValue : rawValue) }

    public var displayName: String {
        switch self {
        case .english: "English"
        case .traditionalChinese: "English"
        }
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = raw == Self.english.rawValue ? .english : .english
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(Self.english.rawValue)
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
        set { shortcut = Self.migrateLegacyShortcut(newValue) }
    }

    public init(
        language: SpeechLanguage = .english,
        mode: VoiceMode = .auto,
        activation: ActivationMode = .pushToTalk,
        wakePhrase: String = "Hey Flow State",
        pushToTalkKey: String? = nil,
        shortcut: VoiceShortcut = .controlShiftSpace
    ) {
        self.language = language.rawValue == "zh-TW" ? .english : language
        self.mode = mode
        self.activation = activation
        self.wakePhrase = wakePhrase
        self.shortcut = pushToTalkKey.map(Self.migrateLegacyShortcut) ?? shortcut
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
        mode = try values.decodeIfPresent(VoiceMode.self, forKey: .mode) ?? .auto
        activation = try values.decodeIfPresent(ActivationMode.self, forKey: .activation) ?? .pushToTalk
        wakePhrase = try values.decodeIfPresent(String.self, forKey: .wakePhrase) ?? "Hey Flow State"
        // Older files stored the conflicting Option-Space label in
        // `pushToTalkKey`; migrate those files to the safe default. An
        // explicitly encoded new `shortcut` choice remains authoritative.
        self.shortcut = try values.decodeIfPresent(VoiceShortcut.self, forKey: .shortcut)
            ?? values.decodeIfPresent(String.self, forKey: .pushToTalkKey)
                .map(Self.migrateLegacyShortcut)
            ?? .controlShiftSpace
    }

    private static func migrateLegacyShortcut(_ value: String) -> VoiceShortcut {
        // Option-Space was the old default and can conflict with system input
        // sources. Keep explicit modern `shortcut` values intact, but migrate
        // the legacy field to the safe default.
        guard let shortcut = VoiceShortcut(legacyDisplayName: value) else { return .controlShiftSpace }
        return shortcut == .optionSpace ? .controlShiftSpace : shortcut
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
    public let utteranceID: UUID?
    public let sessionEnded: Bool

    public init(
        transcript: String,
        language: SpeechLanguage,
        isFinal: Bool,
        utteranceID: UUID? = nil,
        sessionEnded: Bool? = nil
    ) {
        self.transcript = transcript
        self.language = language.rawValue == "zh-TW" ? .english : language
        self.isFinal = isFinal
        self.utteranceID = utteranceID
        self.sessionEnded = sessionEnded ?? isFinal
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
        case .modelNotInstalled: "Download Apple’s English speech model in Voice & activation → Download English speech model."
        case .unavailable: "Speech recognition is unavailable for this language on this Mac."
        case .speechPermissionDenied: "Speech Recognition permission is required."
        case .microphonePermissionDenied: "Microphone permission is required."
        case .noInputDevice: "No microphone input is available."
        case .alreadyRunning: "A speech session is already listening."
        }
    }
}

public struct UtteranceEndpoint: Equatable, Sendable {
    public let utteranceID: UUID
    public let transcript: String
    public let sessionEnded: Bool

    public init(utteranceID: UUID, transcript: String, sessionEnded: Bool) {
        self.utteranceID = utteranceID
        self.transcript = transcript
        self.sessionEnded = sessionEnded
    }
}

/// Pure endpoint state. Audio and transcript callbacks feed it timestamps;
/// production capture may use a real clock while tests pass a fake clock.
public struct UtteranceEndpointDetector: Sendable {
    public let silenceDuration: TimeInterval
    private var transcript = ""
    private var transcriptIsFinal = false
    private var transcriptChangedAt: Date?
    private var silenceBeganAt: Date?
    private var speechActive = false
    private var finished = false
    private var awaitingNewSpeech = false
    private var sessionEnded = false

    public init(silenceDuration: TimeInterval = 0.75) {
        self.silenceDuration = max(0.05, silenceDuration)
    }

    @discardableResult
    public mutating func updateTranscript(_ value: String, isFinal: Bool = false, at now: Date) -> Bool {
        guard !sessionEnded, !finished else { return false }
        guard !awaitingNewSpeech || speechActive else { return false }
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return false }
        if awaitingNewSpeech {
            transcript = ""
            transcriptChangedAt = nil
            silenceBeganAt = nil
            awaitingNewSpeech = false
        }
        transcriptIsFinal = isFinal
        if transcript != value {
            transcript = value
            transcriptChangedAt = now
        }
        if isFinal { silenceBeganAt = silenceBeganAt ?? now }
        return true
    }

    public mutating func updateSpeechActivity(_ active: Bool, at now: Date) {
        guard !sessionEnded else { return }
        speechActive = active
        if active {
            if awaitingNewSpeech {
                transcript = ""
                transcriptIsFinal = false
                transcriptChangedAt = nil
                silenceBeganAt = nil
                awaitingNewSpeech = false
                finished = false
            }
            silenceBeganAt = nil
        } else if !transcript.isEmpty {
            silenceBeganAt = silenceBeganAt ?? now
        }
    }

    public mutating func poll(at now: Date) -> UtteranceEndpoint? {
        guard !finished,
              transcriptIsFinal,
              !speechActive,
              !transcript.isEmpty,
              let changedAt = transcriptChangedAt,
              let silenceBeganAt,
              now.timeIntervalSince(max(changedAt, silenceBeganAt)) >= silenceDuration
        else { return nil }
        return emit(sessionEnded: false)
    }

    public mutating func finish(at now: Date) -> UtteranceEndpoint? {
        _ = now
        guard !finished, !transcript.isEmpty else { return nil }
        return emit(sessionEnded: true)
    }

    public mutating func reset() {
        transcript = ""
        transcriptIsFinal = false
        transcriptChangedAt = nil
        silenceBeganAt = nil
        speechActive = false
        finished = false
        awaitingNewSpeech = false
        sessionEnded = false
    }

    private mutating func emit(sessionEnded: Bool) -> UtteranceEndpoint {
        let endpoint = UtteranceEndpoint(
            utteranceID: UUID(),
            transcript: transcript,
            sessionEnded: sessionEnded
        )
        transcript = ""
        transcriptIsFinal = false
        transcriptChangedAt = nil
        silenceBeganAt = nil
        finished = true
        awaitingNewSpeech = !sessionEnded
        self.sessionEnded = sessionEnded
        return endpoint
    }
}

/// Coordinates local activation and stop behavior. It has no network dependency;
/// late provider work cannot keep a cancelled local session alive.
public actor SpeechSessionCoordinator {
    public private(set) var phase: SpeechSessionPhase = .idle
    public private(set) var settings: SpeechSettings
    public private(set) var generation: UInt64 = 0
    private var consumedUtteranceIDs: Set<UUID> = []

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
        finish()
    }

    public func finish() {
        if phase == .listening { phase = .stopping }
    }

    @discardableResult
    public func toggle() -> UInt64 {
        guard settings.activation == .toggle, phase != .stopping else { return generation }
        if phase == .listening {
            finish()
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

    public func consume(
        transcript: String,
        isFinal: Bool,
        sessionEnded: Bool = true,
        utteranceID: UUID? = nil
    ) -> VoiceCommand? {
        guard phase == .listening || phase == .stopping else { return nil }
        if sessionEnded { phase = .idle }
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if isFinal, let utteranceID, !consumedUtteranceIDs.insert(utteranceID).inserted { return nil }
        let command = VoiceCommandRouter.resolve(transcript, mode: settings.mode)
        if command == .stop {
            stopLocally()
            return .stop
        }
        if isFinal, sessionEnded { phase = .idle }
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
        consumedUtteranceIDs.removeAll()
        phase = .listening
        return generation
    }

    private func stopLocally() {
        guard phase != .idle else { return }
        generation &+= 1
        consumedUtteranceIDs.removeAll()
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
