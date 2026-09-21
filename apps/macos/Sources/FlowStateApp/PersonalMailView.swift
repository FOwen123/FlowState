import AppKit
import FlowStateCore
import SwiftUI

struct PersonalMailView: View {
    @ObservedObject private var localization = UILocalization.shared
    @State private var recipient = ""
    @State private var subject = ""
    @State private var bodyText = ""
    @State private var reviewed: GmailDraft?
    @State private var status = ""
    @State private var statusIsFailure = false
    @State private var opening = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(text("mail.title"))
                        .font(PaperStyle.textFont(size: PaperStyle.headingFontSize, weight: .bold))
                    Text(text("mail.subtitle"))
                        .font(.system(size: 15))
                        .foregroundStyle(PaperStyle.muted)
                }

                Text(text("mail.notice"))
                    .font(.system(size: 13))
                    .foregroundStyle(PaperStyle.muted)

                VStack(alignment: .leading, spacing: 14) {
                    TextField(text("mail.recipient.label"), text: $recipient)
                        .textFieldStyle(.plain)
                        .modifier(PaperInputStyle())
                        .accessibilityLabel(text("mail.recipient.label"))
                    TextField(text("mail.subject.label"), text: $subject)
                        .textFieldStyle(.plain)
                        .modifier(PaperInputStyle())
                        .accessibilityLabel(text("mail.subject.label"))
                    Text(text("mail.message.label"))
                        .font(.custom("Helvetica Neue", size: PaperStyle.controlFontSize).weight(.medium))
                    TextEditor(text: $bodyText)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 180)
                        .modifier(PaperInputStyle())
                        .accessibilityLabel(text("mail.message.accessibility"))
                }

                Button(text("mail.review")) {
                    reviewDraft()
                }
                .buttonStyle(PaperBorderButtonStyle())
                .disabled(opening)

                if let draft = reviewed {
                    reviewedDraftSection(draft)
                }

                if !status.isEmpty {
                    Text(text(status))
                        .font(.system(size: 13))
                        .foregroundStyle(statusIsFailure ? .orange : PaperStyle.muted)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: 692, alignment: .leading)
            .padding(.top, 40)
            .padding(.horizontal, 32)
            .padding(.bottom, 48)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(PaperStyle.appCanvas)
        .foregroundStyle(PaperStyle.text)
    }

    private func text(_ key: String) -> String {
        _ = localization.language
        return L10n.text(key, table: "Account")
    }

    private func format(_ key: String, _ value: CVarArg) -> String {
        _ = localization.language
        return L10n.format(key, value, table: "Account")
    }

    private func reviewDraft() {
        do {
            let draft = try GmailDraft(
                recipient: recipient.trimmingCharacters(in: .whitespacesAndNewlines),
                subject: subject,
                body: bodyText
            )
            _ = try draft.composeURL()
            reviewed = draft
            status = ""
            statusIsFailure = false
        } catch {
            reviewed = nil
            status = errorText(error)
            statusIsFailure = true
        }
    }

    private func reviewedDraftSection(_ draft: GmailDraft) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider().overlay(PaperStyle.divider)
            Text(text("mail.review.title"))
                .font(.system(size: 18, weight: .semibold))
            Text(format("mail.to", draft.recipient))
            Text(draft.subject)
                .font(.headline)
                .textSelection(.enabled)
            Text(draft.body)
                .textSelection(.enabled)
            Text(text("mail.open.warning"))
                .font(.system(size: 13))
                .foregroundStyle(PaperStyle.muted)
            HStack {
                Button(text("mail.open")) {
                    open(draft)
                }
                .buttonStyle(PaperBorderButtonStyle())
                .disabled(opening || !matches(draft))
                Button(text("mail.discard")) {
                    reviewed = nil
                }
                .buttonStyle(PaperBorderButtonStyle())
                .disabled(opening)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func matches(_ draft: GmailDraft) -> Bool {
        draft.recipient == recipient.trimmingCharacters(in: .whitespacesAndNewlines) &&
        draft.subject == subject &&
        draft.body == bodyText
    }

    private func open(_ draft: GmailDraft) {
        guard !opening, matches(draft) else { return }
        do {
            let url = try draft.composeURL()
            guard let brave = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: "com.brave.Browser"
            ) else {
                status = "mail.status.brave_missing"
                statusIsFailure = true
                return
            }
            opening = true
            NSWorkspace.shared.open(
                [url],
                withApplicationAt: brave,
                configuration: NSWorkspace.OpenConfiguration()
            ) { _, error in
                Task { @MainActor in
                    opening = false
                    if error != nil {
                        status = "mail.status.open_failed"
                        statusIsFailure = true
                    } else {
                        reviewed = nil
                        status = "mail.status.handed_off"
                        statusIsFailure = false
                    }
                }
            }
        } catch {
            status = errorText(error)
            statusIsFailure = true
        }
    }

    private func errorText(_ error: Error) -> String {
        guard let error = error as? GmailDraftError else {
            return "mail.error.generic"
        }
        switch error {
        case .invalidRecipient:
            return "mail.error.invalid_recipient"
        case let .controlCharacter(field):
            switch field {
            case .recipient:
                return "mail.error.control_recipient"
            case .subject:
                return "mail.error.control_subject"
            case .body:
                return "mail.error.control_message"
            }
        case .urlTooLong:
            return "mail.error.url_too_long"
        case .invalidComposeURL:
            return "mail.error.compose_url"
        }
    }
}
