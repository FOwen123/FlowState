import Foundation

public enum GmailDraftField: String, Equatable, Sendable {
    case recipient
    case subject
    case body
}

public enum GmailDraftError: Error, Equatable, LocalizedError, Sendable {
    case invalidRecipient
    case controlCharacter(field: GmailDraftField)
    case urlTooLong(maximum: Int)
    case invalidComposeURL

    public var errorDescription: String? {
        switch self {
        case .invalidRecipient:
            "The Gmail recipient is not a valid single email address."
        case let .controlCharacter(field):
            "The Gmail \(field.rawValue) contains an unsafe control character."
        case let .urlTooLong(maximum):
            "The Gmail compose URL exceeds the \(maximum)-byte safety limit."
        case .invalidComposeURL:
            "The Gmail compose URL could not be constructed safely."
        }
    }
}

/// A reviewed personal-mail draft for Gmail's web composer.
///
/// This value has no sender and no send operation. The compose URL intentionally
/// omits Gmail's account selector and `from` parameter, so Gmail uses the
/// account currently signed in to the browser. The caller must require the user to verify Gmail’s sender
/// and recipient after opening the draft and before sending it.
public struct GmailDraft: Equatable, Sendable {
    /// A conservative URL-size limit. The draft is rejected instead of truncated.
    public static let maxComposeURLLength = 8_192

    public let recipient: String
    public let subject: String
    public let body: String

    public init(recipient: String, subject: String, body: String) throws {
        if Self.hasUnsafeControlCharacters(recipient, allowingBodyFormatting: false) {
            throw GmailDraftError.controlCharacter(field: .recipient)
        }
        guard Self.isValidRecipient(recipient) else {
            throw GmailDraftError.invalidRecipient
        }
        if Self.hasUnsafeControlCharacters(subject, allowingBodyFormatting: false) {
            throw GmailDraftError.controlCharacter(field: .subject)
        }
        if Self.hasUnsafeControlCharacters(body, allowingBodyFormatting: true) {
            throw GmailDraftError.controlCharacter(field: .body)
        }
        self.recipient = recipient
        self.subject = subject
        self.body = body
    }

    /// Builds the commonly supported Gmail web-composer URL shape.
    ///
    /// `view=cm` and the `to`/`su`/`body` query items are a compatibility
    /// convention, not a documented Gmail API contract. This method only
    /// prepares a URL; it does not navigate or send.
    public func composeURL() throws -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "mail.google.com"
        components.path = "/mail/"
        components.queryItems = [
            URLQueryItem(name: "view", value: "cm"),
            URLQueryItem(name: "fs", value: "1"),
            URLQueryItem(name: "to", value: recipient),
            URLQueryItem(name: "su", value: subject),
            URLQueryItem(name: "body", value: body),
        ]
        // Gmail query parsing treats + as a space unless explicitly percent-encoded.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else {
            throw GmailDraftError.invalidComposeURL
        }
        guard url.absoluteString.utf8.count <= Self.maxComposeURLLength else {
            throw GmailDraftError.urlTooLong(maximum: Self.maxComposeURLLength)
        }
        return url
    }

    private static func isValidRecipient(_ value: String) -> Bool {
        guard value.utf8.count <= 320 else { return false }
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let local = String(parts[0])
        let domain = String(parts[1])
        guard !local.isEmpty,
              local.utf8.count <= 64,
              domain.utf8.count <= 255,
              local.first != ".",
              local.last != ".",
              !local.contains(".."),
              !domain.isEmpty else { return false }

        let localCharacters = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.!#$%&'*+-/=?^_`{|}~"
        )
        guard local.unicodeScalars.allSatisfy(localCharacters.contains) else { return false }

        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }
        let domainCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        return labels.allSatisfy { label in
            guard !label.isEmpty,
                  label.first != "-",
                  label.last != "-" else { return false }
            return label.unicodeScalars.allSatisfy(domainCharacters.contains)
        }
    }

    private static func hasUnsafeControlCharacters(
        _ value: String,
        allowingBodyFormatting: Bool
    ) -> Bool {
        value.unicodeScalars.contains { scalar in
            guard CharacterSet.controlCharacters.contains(scalar) else { return false }
            if allowingBodyFormatting {
                return ![9, 10, 13].contains(scalar.value)
            }
            return true
        }
    }
}
