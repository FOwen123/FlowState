import AppKit
import FlowStateCore
import SwiftUI

struct PersonalMailView: View {
    @State private var recipient = ""
    @State private var subject = ""
    @State private var bodyText = ""
    @State private var reviewed: GmailDraft?
    @State private var status = ""
    @State private var opening = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Gmail in Brave / Gmail 草稿").font(.title2)
                Text("Prepare a personal-mail draft. Gmail uses the account signed in to Brave; check its From field before sending. This does not use the Flow State assistant inbox.")
                    .foregroundStyle(.secondary)
                TextField("Recipient / 收件人", text: $recipient)
                TextField("Subject / 主旨", text: $subject)
                Text("Message / 內容")
                TextEditor(text: $bodyText).frame(minHeight: 180).accessibilityLabel("Email message / 郵件內容")
                Button("Review draft / 檢視草稿") {
                    do {
                        let draft = try GmailDraft(recipient: recipient.trimmingCharacters(in: .whitespacesAndNewlines), subject: subject, body: bodyText)
                        _ = try draft.composeURL()
                        reviewed = draft
                        status = ""
                    } catch { reviewed = nil; status = error.localizedDescription }
                }.disabled(opening)
                if let draft = reviewed {
                    GroupBox("Open this exact draft / 開啟此草稿") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("To: \(draft.recipient)")
                            Text(draft.subject).font(.headline)
                            Text(draft.body).textSelection(.enabled)
                            Text("Opening sends these draft fields to Gmail in a URL, which may remain in browser history. It does not press Send. Verify the account and content in Gmail; its compose-link behavior may change.")
                                .font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button("Open draft in Brave / 在 Brave 開啟草稿") { open(draft) }.disabled(opening || !matches(draft))
                                Button("Discard review / 放棄檢視") { reviewed = nil }.disabled(opening)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                }
                Text(status).font(.callout).textSelection(.enabled)
            }.padding(28)
        }
    }
    private func matches(_ draft: GmailDraft) -> Bool {
        draft.recipient == recipient.trimmingCharacters(in: .whitespacesAndNewlines) && draft.subject == subject && draft.body == bodyText
    }
    private func open(_ draft: GmailDraft) {
        guard !opening, matches(draft) else { return }
        do {
            let url = try draft.composeURL()
            guard let brave = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.brave.Browser") else {
                status = "Install Brave before opening this draft. / 請先安裝 Brave。"
                return
            }
            opening = true
            NSWorkspace.shared.open([url], withApplicationAt: brave, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                Task { @MainActor in
                    opening = false
                    if error != nil { status = "Brave could not open the draft. Nothing was sent. / 無法開啟草稿。" }
                    else { reviewed = nil; status = "Draft handed to Brave. Check Gmail's sender and fields before sending. / 請在 Gmail 確認寄件人與內容。" }
                }
            }
        } catch { status = error.localizedDescription }
    }
}
