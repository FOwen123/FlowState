import Foundation

public enum VoiceMode: String, CaseIterable, Codable, Sendable {
    case auto
    case command
    case dictation
}

public enum VoiceCommand: Equatable, Sendable {
    case stop
    case scroll(Int32)
    case openApp(String)
    case research(String)
    case resume
    case undo
    case focus(role: String?, label: String?)
    case select(label: String)
    case press(key: String, modifiers: String?)
    case dictate(String)
    case unknown
}

/// Exact local commands only. Ambiguous or negated requests never become input events.
public enum VoiceCommandRouter {
    public static func resolve(_ transcript: String, mode: VoiceMode) -> VoiceCommand {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .unknown }
        let command = normalized(text)
        // Stop is a local safety control even while literal dictation is
        // selected. A user must always be able to end capture without cloud
        // interpretation or a mode change.
        if command == "stop" || command == "cancel" { return .stop }
        if mode == .dictation { return .dictate(text) }
        let literalPrefixes = ["type ", "dictate ", "write "]
        for prefix in literalPrefixes where command.hasPrefix(prefix) {
            let literal = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return literal.isEmpty ? .unknown : .dictate(literal)
        }
        for prefix in ["research "] where command.hasPrefix(prefix) {
            let query = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return query.isEmpty ? .unknown : .research(query)
        }
        switch command {
        case "stop", "cancel": return .stop
        case "resume", "continue": return .resume
        case "undo": return .undo
        case "scroll down": return .scroll(-3)
        case "scroll up": return .scroll(3)
        case "open brave", "switch to brave", "switch brave", "open browser", "switch to browser":
            return .openApp("com.brave.Browser")
        case "open safari", "switch to safari", "switch safari":
            return .openApp("com.apple.Safari")
        case "open finder", "switch to finder", "switch finder":
            return .openApp("com.apple.finder")
        case "open spotify", "switch to spotify", "switch spotify":
            return .openApp("com.spotify.client")
        case "focus text field": return .focus(role: "AXTextField", label: nil)
        case "focus text area": return .focus(role: "AXTextArea", label: nil)
        case "focus button": return .focus(role: "AXButton", label: nil)
        case "focus link": return .focus(role: "AXLink", label: nil)
        case "select all": return .press(key: "A", modifiers: "Command")
        case "copy": return .press(key: "C", modifiers: "Command")
        case "paste": return .press(key: "V", modifiers: "Command")
        case "press tab": return .press(key: "Tab", modifiers: nil)
        case "press shift tab": return .press(key: "Tab", modifiers: "Shift")
        case "press escape", "press esc": return .press(key: "Escape", modifiers: nil)
        case "press enter", "press return": return .press(key: "Enter", modifiers: nil)
        case "press arrow up": return .press(key: "ArrowUp", modifiers: nil)
        case "press arrow down": return .press(key: "ArrowDown", modifiers: nil)
        case "press arrow left": return .press(key: "ArrowLeft", modifiers: nil)
        case "press arrow right": return .press(key: "ArrowRight", modifiers: nil)
        case "press page up": return .press(key: "PageUp", modifiers: nil)
        case "press page down": return .press(key: "PageDown", modifiers: nil)
        case "press home": return .press(key: "Home", modifiers: nil)
        case "press end": return .press(key: "End", modifiers: nil)
        default:
            let selectPrefix = "select "
            if command.hasPrefix(selectPrefix) {
                let label = String(text.dropFirst(selectPrefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                return label.isEmpty ? .unknown : .select(label: label)
            }
            return .unknown
        }
    }

    private static func normalized(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .lowercased()
    }
}
