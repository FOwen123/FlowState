import Foundation
import Testing
@testable import FlowStateCore

@Test("Gmail drafts use an HTTPS compose URL and preserve encoded fields")
func gmailDraftBuildsComposeURL() throws {
    let draft = try GmailDraft(
        recipient: "reviewer@example.com",
        subject: "Review & approve",
        body: "Line one\nLine two + more"
    )

    let url = try draft.composeURL()
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    let items: [URLQueryItem] = components.queryItems ?? []
    let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })

    #expect(url.scheme == "https")
    #expect(url.host == "mail.google.com")
    #expect(url.path == "/mail")
    #expect(url.absoluteString.hasPrefix("https://mail.google.com/mail/?"))
    #expect(values["view"] == "cm")
    #expect(values["fs"] == "1")
    #expect(values["to"] == "reviewer@example.com")
    #expect(values["su"] == "Review & approve")
    #expect(values["body"] == "Line one\nLine two + more")
    #expect(!url.absoluteString.contains("Review & approve"))
}

@Test("Gmail drafts reject malformed recipients")
func gmailDraftRejectsMalformedRecipients() {
    let overlongDomain = "person@" + String(repeating: "a", count: 256) + ".com"
    for recipient in ["", "missing-at", "@example.com", "person@", "person example.com", "person@example..com", overlongDomain] {
        #expect(throws: GmailDraftError.invalidRecipient) {
            _ = try GmailDraft(recipient: recipient, subject: "Subject", body: "Body")
        }
    }
}

@Test("Gmail drafts reject control characters in headers and unsafe body characters")
func gmailDraftRejectsControlCharacters() {
    #expect(throws: GmailDraftError.controlCharacter(field: .recipient)) {
        _ = try GmailDraft(recipient: "person\n@example.com", subject: "Subject", body: "Body")
    }
    #expect(throws: GmailDraftError.controlCharacter(field: .subject)) {
        _ = try GmailDraft(recipient: "person@example.com", subject: "Subject\r\nInjected", body: "Body")
    }
    #expect(throws: GmailDraftError.controlCharacter(field: .body)) {
        _ = try GmailDraft(recipient: "person@example.com", subject: "Subject", body: "Body\u{0000}")
    }
}

@Test("Gmail drafts reject a compose URL that exceeds the explicit limit")
func gmailDraftRejectsOversizedComposeURL() throws {
    let draft = try GmailDraft(
        recipient: "person@example.com",
        subject: "Subject",
        body: String(repeating: "x", count: GmailDraft.maxComposeURLLength)
    )

    #expect(throws: GmailDraftError.urlTooLong(maximum: GmailDraft.maxComposeURLLength)) {
        _ = try draft.composeURL()
    }
}

@Test("Gmail form-style query parsing preserves plus addresses and body text")
func gmailDraftEscapesLiteralPlus() throws {
    let url = try GmailDraft(recipient: "person+tag@example.com", subject: "A+B", body: "繁體中文 + English").composeURL()
    #expect(!url.absoluteString.contains("+"))
    #expect(url.absoluteString.contains("person%2Btag"))
    #expect(url.absoluteString.contains("A%2BB"))
}
