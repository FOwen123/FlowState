import SwiftUI
import FlowStateCloud

struct CloudAccountView: View {
    @ObservedObject var model: FlowStateAppModel
    @AppStorage("FlowState.convexURL") private var deploymentURL = ""
    @AppStorage("FlowState.clerkPublishableKey") private var publishableKey = ""
    @State private var configurationError: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Cloud account / 雲端帳戶").font(.title2)
            if let session = model.cloudSession {
                CloudConnectedView(model:model, cloud: session)
            } else {
                Text("Connect your Flow State account for public research and reviewed email. Provider API keys stay on the backend.")
                    .foregroundStyle(.secondary)
                TextField("Convex HTTPS URL", text: $deploymentURL)
                TextField("Clerk publishable key (pk_…)", text: $publishableKey)
                Button("Connect / 連線") { configure() }
                if let configurationError { Text(configurationError).foregroundStyle(.red) }
            }
        }.padding(28)
        .task {
            if deploymentURL.isEmpty { deploymentURL = Bundle.main.object(forInfoDictionaryKey: "FlowStateConvexURL") as? String ?? "" }
            if publishableKey.isEmpty { publishableKey = Bundle.main.object(forInfoDictionaryKey: "FlowStateClerkPublishableKey") as? String ?? "" }
            if !deploymentURL.isEmpty && !publishableKey.isEmpty { configure() }
        }
    }
    private func configure() {
        do { model.connectCloud(try CloudConfiguration(deploymentURL: deploymentURL.trimmingCharacters(in: .whitespacesAndNewlines), publishableKey: publishableKey.trimmingCharacters(in: .whitespacesAndNewlines))); configurationError = nil }
        catch { configurationError = "Use a valid HTTPS deployment URL and a public pk_ Clerk key. Never enter a provider secret here." }
    }
}

private struct CloudConnectedView: View {
    @ObservedObject var model: FlowStateAppModel
    @State private var command = ""
    @ObservedObject var cloud: CloudSession
    @State private var query = ""
    @State private var language = "en"
    @State private var recipient = ""
    @State private var reviewed: CloudNote?
    @State private var reviewedRecipient = ""
    @State private var reviewedSender = ""
    @State private var error: String?
    @State private var busy = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if cloud.signedIn {
                HStack { Text("Connected / 已連線"); Spacer(); Button("Sign out / 登出") { Task { await cloud.signOut() } } }
                Text("Queries and public source content are processed by Convex, Firecrawl, TypeSafe and OpenAI. Nothing from your screen or microphone is uploaded here.").font(.callout).foregroundStyle(.secondary)
                GroupBox("Managed commands / 雲端指令") {
                    VStack(alignment:.leading,spacing:10) {
                        Toggle("Interpret unfamiliar voice commands / 理解不熟悉的語音指令",isOn:Binding(get:{model.useManagedCommands},set:{model.useManagedCommands=$0;UserDefaults.standard.set($0,forKey:"FlowState.managedCommands")}))
                        Text("Command text and the selected app name go to TypeSafe/OpenAI. You review the actions before they run. Screen images and audio are not included.").font(.caption)
                        TextField("What should Flow State do? / 想執行什麼操作？",text:$command)
                        Button("Prepare plan / 準備操作") { model.prepareCloudCommand(command) }.disabled(command.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || model.executingPlan)
                        Text(model.cloudStatus).font(.caption)
                        if let plan = cloud.proposal {
                            ForEach(Array(plan.actions.enumerated()),id:\.offset) { index,action in
                                Text("\(index+1). \(action.summary)").textSelection(.enabled)
                            }
                            Text("Approved only until \(Date(timeIntervalSince1970:plan.expiresAt/1000).formatted()). / 授權到期後需重新確認。").font(.caption)
                            HStack {
                                Button("Confirm and run / 確認執行") { model.executeCloudPlan(plan) }.disabled(model.executingPlan)
                                Button("Discard plan / 放棄操作") { model.cancelInputTask() }
                            }
                        }
                    }.padding(8)
                }
                Picker("Answer language / 回答語言", selection: $language) { Text("English").tag("en"); Text("繁體中文").tag("zh-Hant") }
                TextField("Research a public topic / 研究公開主題", text: $query)
                HStack {
                    Button("Research / 研究") { perform { try await cloud.research(query: query + (language == "zh-Hant" ? "\n請以繁體中文回答並附上來源。" : "\nAnswer in English with sources.")) } }.disabled(busy || query.trimmingCharacters(in: .whitespacesAndNewlines).count < 2)
                    Button("Cancel research / 取消研究") { Task { do { try await cloud.cancelResearch() } catch { self.error = error.localizedDescription } } }
                }
                if let run = cloud.run {
                    Text("Status / 狀態: \(run.status)").font(.caption)
                    if run.status == "uncertain" { Text("Check AgentMail sent history before any further send. Retry is disabled to avoid duplicates. / 請先檢查寄件紀錄，避免重複寄送。") }
                    if let note = run.note {
                        Text(note.title).font(.headline)
                        ScrollView { Text(note.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 180)
                        TextField("Recipient / 收件人", text: $recipient)
                        Button("Review email / 檢視郵件") { reviewed = note; reviewedRecipient = recipient; reviewedSender = cloud.run?.sender ?? "" }
                            .disabled(busy || note.status != "ready" || recipient.isEmpty || cloud.run?.sender == nil)
                    }
                }
                if let snapshot = reviewed {
                    GroupBox("Confirm email / 確認郵件") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("From: \(reviewedSender)")
                            Text("To: \(reviewedRecipient)")
                            Text(snapshot.title).font(.headline)
                            ScrollView { Text(snapshot.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 200)
                            Text("Sent from the configured Flow State assistant inbox, not your personal mailbox.").font(.caption)
                            HStack {
                                Button("Confirm send / 確認寄出") { perform { try await cloud.sendReviewedNote(snapshot, recipient: reviewedRecipient, sender: reviewedSender); reviewed = nil } }.disabled(busy || cloud.run?.note != snapshot || cloud.run?.sender != reviewedSender)
                                Button("Cancel / 取消") { reviewed = nil }.disabled(busy)
                            }
                        }.padding(8)
                    }
                }
            } else {
                Text("Sign in through Clerk. Your password stays in the system browser authentication flow.")
                Button(cloud.connecting ? "Connecting…" : "Sign in / 登入") { perform { try await cloud.signIn() } }.disabled(busy || cloud.connecting)
            }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if let error = cloud.error { Text(error).foregroundStyle(.red) }
        }
    }
    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true; error = nil
        Task { do { try await action() } catch { self.error = error.localizedDescription }; busy = false }
    }
}
