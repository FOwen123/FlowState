import AVFoundation
import FlowStateCore

enum SpokenResponseKind: Sendable {
    case question
    case milestone
    case failure
    case completion
}

struct SpokenSpeechRequest: Equatable, Sendable {
    let text: String
    let voiceIdentifier: String?
    let localeIdentifier: String
}

@MainActor
protocol SpokenSpeechEngine: AnyObject {
    func speak(_ request: SpokenSpeechRequest)
    func stop()
}

@MainActor
private final class AVSpeechEngine: SpokenSpeechEngine {
    private let synthesizer = AVSpeechSynthesizer()

    func speak(_ request: SpokenSpeechRequest) {
        let utterance = AVSpeechUtterance(string: request.text)
        utterance.voice = request.voiceIdentifier.flatMap(AVSpeechSynthesisVoice.init(identifier:))
            ?? AVSpeechSynthesisVoice(language: request.localeIdentifier)
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }
}

@MainActor
final class SpokenResponseController {
    private let engine: any SpokenSpeechEngine
    private(set) var lastResponse: String?
    var voiceIdentifier: String?
    var localeIdentifier: String
    var isMuted = false

    init(
        engine: any SpokenSpeechEngine = AVSpeechEngine(),
        voiceIdentifier: String? = nil,
        localeIdentifier: String = "en-US"
    ) {
        self.engine = engine
        self.voiceIdentifier = voiceIdentifier
        self.localeIdentifier = localeIdentifier
    }

    func speakQuestion(_ text: String) {
        speak(text, kind: .question, meaningful: true)
    }

    func speakMilestone(_ text: String, meaningful: Bool = true) {
        speak(text, kind: .milestone, meaningful: meaningful)
    }

    func speakFailure(_ text: String) {
        speak(text, kind: .failure, meaningful: true)
    }

    func speakCompletion(_ text: String) {
        speak(text, kind: .completion, meaningful: true)
    }

    func replayLastResponse() {
        guard let lastResponse else { return }
        speak(lastResponse, kind: .completion, meaningful: true)
    }

    func stop() {
        engine.stop()
    }

    static func availableVoices() -> [(id: String, name: String, locale: String)] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
            .sorted { lhs, rhs in
                lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            .map { (id: $0.identifier, name: $0.name, locale: $0.language) }
    }

    private func speak(_ text: String, kind: SpokenResponseKind, meaningful: Bool) {
        guard meaningful else { return }
        let value = Self.approvedText(for: text, kind: kind)
        guard !value.isEmpty else { return }
        lastResponse = value
        guard !isMuted else { return }
        engine.speak(SpokenSpeechRequest(
            text: value,
            voiceIdentifier: voiceIdentifier,
            localeIdentifier: localeIdentifier
        ))
    }

    /// Provider wording is display-only. Speech uses a bounded local template
    /// so arbitrary clarification, account, or field contents never become
    /// audible. Local UI may still show the full redacted provider text.
    private static func approvedText(for text: String, kind: SpokenResponseKind) -> String {
        let safe = ControlConversationSession.redactSensitive(text)
        let normalized = safe
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        switch kind {
        case .question:
            if normalized.contains("confirm") || normalized.contains("approve") {
                return "Please confirm the proposed action."
            }
            if normalized.contains("which") || normalized.contains("clarif") || normalized.contains("app") {
                return "Please clarify your request."
            }
            return "Please answer the question to continue."
        case .milestone:
            if normalized.contains("look") || normalized.contains("observ") {
                return "I am checking the current app."
            }
            return "I am continuing the task."
        case .failure:
            return "The task could not be completed."
        case .completion:
            if normalized.contains("open") || normalized.contains("launch") {
                return "The selected app is open."
            }
            if normalized.contains("scroll") {
                return "The page is scrolled."
            }
            return "The task is complete."
        }
    }
}
