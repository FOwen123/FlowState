import AppKit
import SwiftUI
import FlowStateCloud

struct CloudAccountView: View {
    @ObservedObject var model: FlowStateAppModel
    @ObservedObject private var localization = UILocalization.shared
    @State private var configurationError: String?
    @State private var didAttemptConfiguration = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(accountText("account.title"))
                        .font(PaperStyle.textFont(size: PaperStyle.headingFontSize, weight: .bold))
                    Text(accountText("account.subtitle"))
                        .font(.system(size: 15))
                        .foregroundStyle(PaperStyle.muted)
                }

                if let session = model.cloudSession {
                    CloudConnectedView(model: model, cloud: session)
                } else if configurationError != nil {
                    AccountUnavailableView(retry: retryConfiguration)
                } else {
                    ProgressView()
                        .accessibilityLabel(accountText("account.signing_in"))
                        .frame(maxWidth: .infinity, alignment: .leading)
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
        .task {
            configureBundledAccount()
        }
    }

    private func accountText(_ key: String) -> String {
        _ = localization.language
        return L10n.text(key, table: "Account")
    }

    private func configureBundledAccount() {
        guard !didAttemptConfiguration, model.cloudSession == nil else { return }
        didAttemptConfiguration = true

        guard
            let deploymentURL = Bundle.main.object(forInfoDictionaryKey: "FlowStateConvexURL") as? String,
            let publishableKey = Bundle.main.object(forInfoDictionaryKey: "FlowStateClerkPublishableKey") as? String,
            !deploymentURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !publishableKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            configurationError = accountText("account.unavailable.message")
            return
        }

        do {
            let configuration = try CloudConfiguration(
                deploymentURL: deploymentURL.trimmingCharacters(in: .whitespacesAndNewlines),
                publishableKey: publishableKey.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            model.connectCloud(configuration)
            configurationError = nil
        } catch {
            configurationError = accountText("account.unavailable.message")
        }
    }

    private func retryConfiguration() {
        didAttemptConfiguration = false
        configurationError = nil
        configureBundledAccount()
    }
}

private struct AccountUnavailableView: View {
    let retry: () -> Void
    @ObservedObject private var localization = UILocalization.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.system(size: 30))
                .foregroundStyle(PaperStyle.secondary)
                .accessibilityHidden(true)
            Text(text("account.unavailable.title"))
                .font(PaperStyle.textFont(size: 20, weight: .bold))
            Text(text("account.unavailable.message"))
                .font(.system(size: 14))
                .foregroundStyle(PaperStyle.muted)
            Button(text("account.retry"), action: retry)
                .buttonStyle(PaperBorderButtonStyle())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func text(_ key: String) -> String {
        _ = localization.language
        return L10n.text(key, table: "Account")
    }
}

private struct CloudConnectedView: View {
    @ObservedObject var model: FlowStateAppModel
    @ObservedObject var cloud: CloudSession
    @ObservedObject private var localization = UILocalization.shared
    @State private var command = ""
    @State private var query = ""
    @State private var recipient = ""
    @State private var reviewed: CloudNote?
    @State private var reviewedRecipient = ""
    @State private var reviewedSender = ""
    @State private var error: String?
    @State private var busy = false

    @ViewBuilder
    var body: some View {
        if cloud.signedIn {
            signedInContent
        } else {
            signedOutContent
        }
    }

    private var signedOutContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            Image(systemName: "person.crop.circle")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(PaperStyle.secondary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 8) {
                Text(text("account.signed_out.title"))
                    .font(PaperStyle.textFont(size: 24, weight: .bold))
                Text(text("account.signed_out.subtitle"))
                    .font(.system(size: 15))
                    .foregroundStyle(PaperStyle.muted)
            }

            VStack(alignment: .leading, spacing: 16) {
                benefit(
                    icon: "magnifyingglass",
                    title: text("account.benefit.research.title"),
                    detail: text("account.benefit.research.detail")
                )
                Divider().overlay(PaperStyle.divider)
                benefit(
                    icon: "envelope.open",
                    title: text("account.benefit.email.title"),
                    detail: text("account.benefit.email.detail")
                )
            }

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "safari")
                    .foregroundStyle(PaperStyle.muted)
                    .accessibilityHidden(true)
                Text(text("account.browser_reassurance"))
                    .font(.system(size: 13))
                    .foregroundStyle(PaperStyle.muted)
            }

            Button {
                perform({ try await cloud.signIn() }, failureKey: "account.error.sign_in")
            } label: {
                HStack(spacing: 8) {
                    if busy || cloud.connecting {
                        ProgressView()
                            .controlSize(.small)
                            .tint(PaperStyle.text)
                    }
                    Text(busy || cloud.connecting ? text("account.signing_in") : text("account.sign_in"))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(PaperBorderButtonStyle())
            .disabled(busy || cloud.connecting)

            if let error {
                Text(text(error))
                    .font(.system(size: 13))
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
            if cloud.error != nil {
                Text(text("account.error.sign_in"))
                    .font(.system(size: 13))
                    .foregroundStyle(.orange)
            }
        }
    }

    private var signedInContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(text("account.connected"))
                        .font(.system(size: 20, weight: .semibold))
                    Text(text("account.connected.subtitle"))
                        .font(.system(size: 14))
                        .foregroundStyle(PaperStyle.muted)
                }
                Spacer()
                Button(text("account.sign_out")) {
                    Task { await model.signOutCloud() }
                }
                .buttonStyle(PaperBorderButtonStyle())
            }

            Divider().overlay(PaperStyle.divider)
            managedCommandsSection
            Divider().overlay(PaperStyle.divider)
            researchSection

            if let reviewed {
                Divider().overlay(PaperStyle.divider)
                reviewedEmailSection(reviewed)
            }

            if let error {
                Text(text(error))
                    .font(.system(size: 13))
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
            if cloud.error != nil {
                Text(text("account.error.data"))
                    .font(.system(size: 13))
                    .foregroundStyle(.orange)
            }
        }
    }

    private var managedCommandsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeading(
                title: text("account.managed.title"),
                detail: text("account.managed.description")
            )

            Toggle(text("account.managed.toggle"), isOn: Binding(
                get: { model.useManagedCommands },
                set: {
                    model.useManagedCommands = $0
                    UserDefaults.standard.set($0, forKey: "FlowState.managedCommands")
                }
            ))
            .toggleStyle(.switch)

            TextField(text("account.managed.command.placeholder"), text: $command)
                .textFieldStyle(.plain)
                .modifier(PaperInputStyle())
                .accessibilityLabel(text("account.managed.command.placeholder"))

            Button(model.executingPlan ? text("account.managed.preparing") : text("account.managed.prepare")) {
                model.prepareCloudCommand(command)
            }
            .buttonStyle(PaperBorderButtonStyle())
            .disabled(command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.executingPlan)

            Text(L10n.text(model.cloudStatus))
                .font(.system(size: 13))
                .foregroundStyle(PaperStyle.muted)

            if !model.externalEffectRecoveries.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(model.externalEffectRecoveries) { recovery in
                        VStack(alignment: .leading, spacing: 8) {
                            Text("A reviewed handoff may already have completed.")
                                .font(.system(size: 13, weight: .medium))
                            Text(recovery.summary)
                                .font(.system(size: 13))
                                .foregroundStyle(PaperStyle.muted)
                            HStack {
                                Button("It completed") {
                                    model.confirmExternalEffect(recovery)
                                }
                                .buttonStyle(PaperBorderButtonStyle())
                                Button("It failed") {
                                    model.rejectExternalEffect(recovery)
                                }
                                .buttonStyle(PaperBorderButtonStyle())
                            }
                        }
                    }
                }
                .padding(12)
                .background(PaperStyle.selected, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Choose whether the previous reviewed handoff completed or failed")
            }

            if let plan = cloud.proposal {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(plan.actions.enumerated()), id: \.offset) { index, action in
                        let appName: String = if let bundleIdentifier = action.targetBundleIdentifier {
                            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
                                .map { FileManager.default.displayName(atPath: $0.path) } ?? bundleIdentifier
                        } else {
                            "Selected app"
                        }
                        let summary = L10n.planSummary(action.parameters, appName: appName)
                        Text(accountFormat("account.plan.action", index + 1, summary))
                            .textSelection(.enabled)
                            .accessibilityLabel(summary)
                    }
                    Text(accountFormat(
                        "account.plan.expires",
                        Date(timeIntervalSince1970: plan.expiresAt/1000).formatted()
                    ))
                    .font(.system(size: 13))
                    .foregroundStyle(PaperStyle.muted)
                    if let currentStep = model.currentPlanStep {
                        Text("Current step: \(currentStep)")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(PaperStyle.secondary)
                            .textSelection(.enabled)
                    }
                    HStack {
                        Button(text("account.managed.confirm")) {
                            model.executeCloudPlan(plan)
                        }
                        .buttonStyle(PaperBorderButtonStyle())
                        .disabled(model.executingPlan)
                        Button(text("account.managed.discard")) {
                            model.cancelInputTask()
                        }
                        .buttonStyle(PaperBorderButtonStyle())
                    }
                }
            }
        }
    }

    private var researchSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeading(
                title: text("account.research.title"),
                detail: text("account.research.placeholder")
            )

            TextField(text("account.research.placeholder"), text: $query)
                .textFieldStyle(.plain)
                .modifier(PaperInputStyle())
                .accessibilityLabel(text("account.research.placeholder"))

            HStack {
                Button(text("account.research.action")) {
                    perform {
                        try await cloud.research(
                            query: query + "\nAnswer in English with sources."
                        )
                    }
                }
                .buttonStyle(PaperBorderButtonStyle())
                .disabled(busy || query.trimmingCharacters(in: .whitespacesAndNewlines).count < 2)

                Button(text("account.research.cancel")) {
                    perform { try await cloud.cancelResearch() }
                }
                .buttonStyle(PaperBorderButtonStyle())
                .disabled(busy)
            }

            if let run = cloud.run {
                Text(accountFormat("account.research.status", runStatusText(run.status)))
                    .font(.system(size: 13))
                    .foregroundStyle(PaperStyle.muted)

                if run.status == "uncertain" {
                    Text(text("account.research.uncertain"))
                        .font(.system(size: 13))
                        .foregroundStyle(.orange)
                }

                if let note = run.note {
                    Text(note.title)
                        .font(.headline)
                        .textSelection(.enabled)
                    ScrollView {
                        Text(note.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 180)

                    TextField(text("account.mail.recipient.placeholder"), text: $recipient)
                        .textFieldStyle(.plain)
                        .modifier(PaperInputStyle())
                        .accessibilityLabel(text("account.mail.recipient.placeholder"))

                    Button(text("account.mail.review")) {
                        reviewed = note
                        reviewedRecipient = recipient
                        reviewedSender = cloud.run?.sender ?? ""
                    }
                    .buttonStyle(PaperBorderButtonStyle())
                    .disabled(
                        busy ||
                        note.status != "ready" ||
                        recipient.isEmpty ||
                        cloud.run?.sender == nil
                    )
                }
            }
        }
    }

    private func reviewedEmailSection(_ snapshot: CloudNote) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(text("account.mail.confirm.title"))
                .font(.system(size: 18, weight: .semibold))
            Text(accountFormat("account.mail.from", reviewedSender))
            Text(accountFormat("account.mail.to", reviewedRecipient))
            Text(snapshot.title)
                .font(.headline)
                .textSelection(.enabled)
            ScrollView {
                Text(snapshot.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 200)
            Text(text("account.mail.sender_note"))
                .font(.system(size: 13))
                .foregroundStyle(PaperStyle.muted)
            HStack {
                Button(text("account.mail.send")) {
                    perform {
                        try await cloud.sendReviewedNote(
                            snapshot,
                            recipient: reviewedRecipient,
                            sender: reviewedSender
                        )
                        reviewed = nil
                    }
                }
                .buttonStyle(PaperBorderButtonStyle())
                .disabled(
                    busy ||
                    cloud.run?.note != snapshot ||
                    cloud.run?.sender != reviewedSender
                )
                Button(text("account.mail.cancel")) {
                    reviewed = nil
                }
                .buttonStyle(PaperBorderButtonStyle())
                .disabled(busy)
            }
        }
    }

    private func benefit(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .frame(width: 20)
                .foregroundStyle(PaperStyle.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(PaperStyle.muted)
            }
        }
    }

    private func sectionHeading(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 18, weight: .semibold))
            Text(detail)
                .font(.system(size: 13))
                .foregroundStyle(PaperStyle.muted)
        }
    }

    private func text(_ key: String) -> String {
        _ = localization.language
        return L10n.text(key, table: "Account")
    }

    private func accountFormat(_ key: String, _ value: CVarArg) -> String {
        _ = localization.language
        return L10n.format(key, value, table: "Account")
    }

    private func accountFormat(_ key: String, _ first: CVarArg, _ second: CVarArg) -> String {
        _ = localization.language
        return L10n.format(key, first, second, table: "Account")
    }

    private func runStatusText(_ status: String) -> String {
        switch status {
        case "queued": return text("account.run.queued")
        case "running": return text("account.run.running")
        case "awaiting_approval": return text("account.run.awaiting_approval")
        case "approved": return text("account.run.approved")
        case "sending": return text("account.run.sending")
        case "completed": return text("account.run.completed")
        case "uncertain": return text("account.run.uncertain")
        case "failed": return text("account.run.failed")
        case "cancelled": return text("account.run.cancelled")
        default: return text("account.run.unknown")
        }
    }

    private func cloudErrorText(_ error: Error) -> String {
        guard let cloudError = error as? CloudSessionError else {
            return "account.error.request"
        }
        switch cloudError {
        case .signInRequired:
            return "account.status.signin_required"
        case .reviewChanged:
            return "account.error.review_changed"
        case .busy:
            return "account.error.busy"
        }
    }

    private func perform(
        _ action: @escaping @MainActor () async throws -> Void,
        failureKey: String? = nil
    ) {
        guard !busy else { return }
        busy = true
        error = nil
        Task { @MainActor in
            do {
                try await action()
            } catch {
                self.error = failureKey ?? cloudErrorText(error)
            }
            busy = false
        }
    }
}
