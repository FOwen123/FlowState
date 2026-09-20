import Foundation

extension ExplicitMemoryStore {
    /// User-saved vocabulary is literal data, never a command or permission grant.
    public func personalize(_ transcript: String, mode: VoiceMode) -> String {
        let state = snapshot()
        let preferences = state.preferences.filter { $0.source == .explicit || state.learningEnabled }
            .sorted { a,b in a.source == b.source ? a.updatedAt > b.updatedAt : a.source == .explicit }
        if mode == .command {
            let text = transcript.trimmingCharacters(in:.whitespacesAndNewlines)
            for prefix in ["open "] where text.lowercased().hasPrefix(prefix) {
                let phrase = String(text.dropFirst(prefix.count)).trimmingCharacters(in:.punctuationCharacters).lowercased()
                if let alias = preferences.first(where:{ $0.category == .appAlias && $0.trigger.lowercased() == phrase }) {
                    return prefix + alias.value
                }
            }
            return transcript
        }
        var replacements: [String:String] = [:]
        for preference in preferences where preference.category == .vocabulary && !preference.trigger.isEmpty {
            let phrase = preference.trigger.lowercased()
            if replacements[phrase] == nil { replacements[phrase] = preference.value }
        }
        let phrases = replacements.keys.sorted { $0.count > $1.count }
        let patterns = phrases.map { phrase in
            let literal = NSRegularExpression.escapedPattern(for:phrase)
            let containsHan = phrase.range(of:#"\p{Han}"#,options:.regularExpression) != nil
            return containsHan ? literal : #"(?<![\p{L}\p{N}_])"# + literal + #"(?![\p{L}\p{N}_])"#
        }
        guard !patterns.isEmpty, let expression = try? NSRegularExpression(pattern:patterns.joined(separator:"|"),options:.caseInsensitive) else { return transcript }
        let original = transcript as NSString
        let output = NSMutableString(string:transcript)
        // Match original text once; replacements cannot recursively rewrite one another.
        for match in expression.matches(in:transcript,range:NSRange(location:0,length:original.length)).reversed() {
            if let replacement = replacements[original.substring(with:match.range).lowercased()] { output.replaceCharacters(in:match.range,with:replacement) }
        }
        return output as String
    }
}
