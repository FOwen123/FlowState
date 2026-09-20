import Foundation

public enum VoiceMode: String, CaseIterable, Sendable {
    case command
    case dictation
}

public enum VoiceCommand: Equatable, Sendable {
    case stop
    case scroll(Int32)
    case openApp(String)
    case dictate(String)
    case unknown
}

/// Exact local commands only. Ambiguous or negated requests never become input events.
public enum VoiceCommandRouter {
    public static func resolve(_ transcript: String, mode: VoiceMode) -> VoiceCommand {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .unknown }
        guard mode == .command else { return .dictate(text) }
        let command = text.lowercased().trimmingCharacters(in: .punctuationCharacters)
        switch command {
        case "stop", "cancel", "停止", "取消": return .stop
        case "scroll down", "往下捲動", "向下滾動", "往下滾動": return .scroll(-3)
        case "scroll up", "往上捲動", "向上滾動", "往上滾動": return .scroll(3)
        case "open brave", "開啟 brave", "打開 brave": return .openApp("com.brave.Browser")
        case "open safari", "開啟 safari", "打開 safari": return .openApp("com.apple.Safari")
        case "open finder", "開啟 finder", "打開 finder": return .openApp("com.apple.finder")
        case "open spotify", "開啟 spotify", "打開 spotify": return .openApp("com.spotify.client")
        default: return .unknown
        }
    }
}
