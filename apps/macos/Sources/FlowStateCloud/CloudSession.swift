import Foundation
import CryptoKit
import FlowStateCore
import Combine
import ClerkKit
import ClerkConvex
@preconcurrency import ConvexMobile

public struct CloudNote: Decodable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let body: String
    public let url: String
    public let status: String
}
public struct CloudRun: Decodable, Sendable {
    public let sender: String?
    public let id: String
    public let status: String
    public let note: CloudNote?
    public let error: String?
}
private struct CreatedRun: Decodable { let runId: String }
private struct ExternalEffectResponse: Decodable {
    let status: String
    let receiptId: String
}
struct ExternalEffectReconcileResponse: Decodable {
    let status: String
    let receiptId: String
}

public enum ExternalEffectResolution: Equatable, Sendable {
    case pending(receiptID: String)
    case alreadySucceeded(receiptID: String)
    case needsReconciliation(receiptID: String)
    case invalid

    var receiptID: String? {
        switch self {
        case let .pending(receiptID), let .alreadySucceeded(receiptID), let .needsReconciliation(receiptID):
            return receiptID
        case .invalid:
            return nil
        }
    }

    var allowsLaunch: Bool {
        if case .pending = self { return true }
        return false
    }
}

func externalEffectResolution(status: String, receiptID: String) -> ExternalEffectResolution {
    guard !receiptID.isEmpty else { return .invalid }
    switch status {
    case "pending": return .pending(receiptID: receiptID)
    case "succeeded": return .alreadySucceeded(receiptID: receiptID)
    case "reconcile", "uncertain": return .needsReconciliation(receiptID: receiptID)
    default: return .invalid
    }
}

public func externalEffectRequestFingerprint(action: NativePlanAction) -> String {
    let source = externalEffectCanonicalAction(action)
    return SHA256.hash(data: source).map { String(format: "%02x", $0) }.joined()
}

private func externalEffectCanonicalAction(_ action: NativePlanAction) -> Data {
    func normalized(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func field(_ name: String, _ value: String) -> String {
        let value = normalized(value)
        return "\(name)=\(value.utf8.count):\(value)"
    }

    func optionalField(_ name: String, _ value: String?) -> String {
        guard let value else { return "\(name)=nil" }
        return field(name, value)
    }

    func exactOptionalField(_ name: String, _ value: String?) -> String {
        guard let value else { return "\(name)=nil" }
        return "\(name)=\(value.utf8.count):\(value)"
    }

    var fields = [
        field("kind", action.kind.rawValue),
        exactOptionalField("target", action.targetBundleIdentifier),
    ]
    switch action.parameters {
    case .openApplication:
        fields.append(field("parameters", "openApplication"))
    case let .scroll(lines):
        fields += [field("parameters", "scroll"), field("lines", String(lines))]
    case let .focus(role, label):
        fields += [field("parameters", "focus"), field("role", role), optionalField("label", label)]
    case let .select(label):
        fields += [field("parameters", "select"), field("label", label)]
    case let .press(key, modifiers):
        fields += [field("parameters", "press"), field("key", key), optionalField("modifiers", modifiers)]
    case let .openURL(url):
        fields += [field("parameters", "openURL"), field("url", url)]
    case let .attachFile(fileID):
        fields += [field("parameters", "attachFile"), field("fileID", fileID)]
    case let .sendEmail(recipient, subject, body):
        fields += [field("parameters", "sendEmail"), field("recipient", recipient), field("subject", subject), field("body", body)]
    case let .draftMessage(recipient, subject, body):
        fields += [field("parameters", "draftMessage"), field("recipient", recipient), field("subject", subject), field("body", body)]
    case let .insertText(text, replaceSelection):
        fields += [field("parameters", "insertText"), field("text", text), field("replaceSelection", String(replaceSelection))]
    }
    return Data(fields.joined(separator: "|").utf8)
}

func intentSupportedActionNames(for grant: DesktopExecutionGrant?) -> [String] {
    (grant?.allowedActions ?? [])
        .filter { $0 != .insertText }
        .map(\.rawValue)
        .sorted()
}

func intentSupportedTools(_ tools: [String]) -> [String] {
    tools.contains(NativePlanRoute.nativeAccessibility.rawValue)
        ? [NativePlanRoute.nativeAccessibility.rawValue]
        : []
}

private struct ApprovedEmail: Decodable { let approvalId: String }
private struct DictationCleanupResponse: Decodable {
    let text: String
    let cleaned: Bool
    let reason: String?
}

struct DictationCleanupRequest: Equatable, Sendable {
    static let actionName = "dictation:clean"
    let transcript: String
    let cleanupInstructions: String
    let enabled: Bool
}

/// Uses the official Clerk/Convex bridge. Provider keys never enter the native app.
/// Subscriptions only display state; they never execute desktop actions or resend mail.
@MainActor
public final class CloudSession: ObservableObject {
    public var onSessionInvalidated: (() -> Void)?
    @Published public private(set) var proposal: CloudProposal?
    private var activePlanID: String?
    private var planGeneration: UInt64 = 0
    private var planning = false
    private var intentGeneration: UInt64 = 0
    @Published public private(set) var signedIn = false
    @Published public private(set) var connecting = false
    @Published public private(set) var run: CloudRun?
    @Published public private(set) var error: String?
    public let deviceID: String
    private let client: ConvexClientWithAuth<String>
    private var authSubscription: AnyCancellable?
    private var runSubscription: AnyCancellable?
    private var generation: UInt64 = 0
    private var operationGeneration: UInt64 = 0
    private var activeRunID: String?
    private var researching = false
    private var sending = false

    public init(configuration: CloudConfiguration, defaults: UserDefaults = .standard) {
        deviceID = CloudConfiguration.deviceID(in: defaults)
        Clerk.configure(publishableKey: configuration.publishableKey)
        client = ConvexClientWithAuth(deploymentUrl: configuration.deploymentURL, authProvider: ClerkConvexAuthProvider())
        authSubscription = client.authState.receive(on: DispatchQueue.main).sink { [weak self] state in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch state {
                case .authenticated: self.signedIn = true; self.connecting = false
                case .loading: self.connecting = true
                case .unauthenticated:
                    if self.signedIn { self.onSessionInvalidated?() }
                    self.signedIn = false; self.connecting = false
                    self.intentGeneration &+= 1
                    self.planGeneration &+= 1; self.proposal = nil; self.activePlanID = nil
                    self.generation &+= 1; self.operationGeneration &+= 1; self.runSubscription = nil; self.run = nil; self.activeRunID = nil
                }
            }
        }
    }
    public func signIn() async throws {
        error = nil
        _ = try await Clerk.shared.auth.startHostedAuth(redirectUrl: "com.flowstate.dev://callback")
        // The bridge refreshes credentials; it doesn't replay any workflow.
        let result = await client.loginFromCache()
        if case .failure(let failure) = result { throw failure }
        try await registerDevice()
    }
    public func signOut() async {
        cancelIntent()
        onSessionInvalidated?()
        await cancelPlan()
        planGeneration &+= 1; proposal = nil; activePlanID = nil
        generation &+= 1; operationGeneration &+= 1; runSubscription = nil; run = nil; activeRunID = nil
        await client.logout()
        signedIn = false
    }
    private func registerDevice() async throws {
        let _: CloudMutationReceipt = try await client.mutation("workflows:registerDevice", with: ["deviceId": deviceID, "name": "Flow State Mac"])
    }
    public func research(query: String, sourceURL: String? = nil) async throws {
        guard signedIn else { throw CloudSessionError.signInRequired }
        guard !researching else { throw CloudSessionError.busy }
        researching = true
        defer { researching = false }
        operationGeneration &+= 1
        let token = operationGeneration
        try await registerDevice()
        guard operationGeneration == token else { throw CancellationError() }
        var arguments: [String: ConvexEncodable?] = ["deviceId": deviceID, "query": query]
        if let sourceURL { arguments["sourceUrl"] = sourceURL }
        let created: CreatedRun = try await client.mutation("workflows:createResearchRun", with: arguments)
        guard operationGeneration == token else {
            let _: CloudMutationReceipt? = try? await client.mutation("workflows:cancelResearch", with: ["runId": created.runId])
            throw CancellationError()
        }
        activeRunID = created.runId
        observe(runID: created.runId)
        let _: CloudMutationReceipt = try await client.action("workflows:runResearch", with: ["runId": created.runId])
    }
    public func cancelIntent() { intentGeneration &+= 1 }

    public func routeIntent(utterance: String, sessionID: String, utteranceID: String,
                            contextRevision: Int, mode: String, context: CloudIntentContext,
                            grant: DesktopExecutionGrant?, observation: CloudIntentObservation? = nil,
                            observationAllowedUntil: Date? = nil,
                            supportedTools: [String] = [NativePlanRoute.nativeAccessibility.rawValue]) async throws -> IntentDecision {
        guard signedIn else { throw CloudSessionError.signInRequired }
        let token = intentGeneration
        try await registerDevice()
        guard signedIn, token == intentGeneration else { throw CancellationError() }
        var capabilities = Set<String>()
        if let grant, grant.expiresAt > Date() {
            for action in grant.allowedActions {
                guard action != .insertText else { continue }
                capabilities.insert(action == .openApplication ? "app.open" : action == .press ? "app.input" : "app.control")
            }
            for target in grant.allowedBundleIdentifiers where target == context.focusedAppBundleIdentifier {
                for capability in capabilities.sorted() {
                    guard signedIn, token == intentGeneration, grant.expiresAt > Date() else { throw CancellationError() }
                    let _: CloudMutationReceipt = try await client.mutation("grants:grant", with: ["deviceId": deviceID, "capability": capability,
                        "target": target, "expiresAt": grant.expiresAt.timeIntervalSince1970 * 1000])
                }
            }
        }
        if let grant, grant.expiresAt > Date(), grant.allowedActions.contains(.openApplication) {
            let targets = Set(context.targetCandidates.filter { $0.kind == "app" }.compactMap(\.bundleIdentifier))
                .intersection(grant.allowedBundleIdentifiers).sorted()
            if !targets.isEmpty {
                guard signedIn, token == intentGeneration else { throw CancellationError() }
                let _: CloudMutationReceipt = try await client.mutation("grants:grantApplicationOpenTargets", with: ["deviceId": deviceID,
                    "targets": targets.map { $0 as ConvexEncodable? }, "expiresAt": grant.expiresAt.timeIntervalSince1970 * 1000])
            }
        }
        if let expiry = observationAllowedUntil, expiry > Date(),
           let target = context.focusedAppBundleIdentifier {
            for capability in ["app.observe", "app.upload"] {
                guard signedIn, token == intentGeneration else { throw CancellationError() }
                let _: CloudMutationReceipt = try await client.mutation("grants:grant", with: ["deviceId": deviceID, "capability": capability,
                    "target": target, "expiresAt": expiry.timeIntervalSince1970 * 1000])
                capabilities.insert(capability)
            }
        }
        guard signedIn, token == intentGeneration else { throw CancellationError() }
        let supportedActions = intentSupportedActionNames(for: grant)
        let intentTools = intentSupportedTools(supportedTools)
        guard !supportedActions.isEmpty, !intentTools.isEmpty else { throw CloudSessionError.reviewChanged }
        let response: IntentDecision = try await client.action("intents:route", with: [
            "deviceId": deviceID, "sessionId": sessionID, "utteranceId": utteranceID,
            "contextRevision": Double(contextRevision), "utterance": utterance, "mode": mode,
            "context": context, "supportedActions": supportedActions.map { $0 as ConvexEncodable? },
            "supportedTools": intentTools.map { $0 as ConvexEncodable? },
            "supportedCapabilities": capabilities.sorted().map { $0 as (any ConvexEncodable)? }, "policyVersion": "intent-v1", "observation": observation,
        ])
        try requireCurrentIntent(signedIn: signedIn, currentGeneration: intentGeneration, requestGeneration: token,
            expectedSession: sessionID, returnedSession: response.sessionID,
            expectedUtterance: utteranceID, returnedUtterance: response.utteranceID,
            expectedRevision: contextRevision, returnedRevision: response.contextRevision)
        return response
    }

    public func preparePlan(
        command: String,
        targetBundleIdentifier: String,
        locale: String,
        contextRevision: Int = 0,
        supportedTools: [String] = [NativePlanRoute.nativeAccessibility.rawValue],
        integrations: [String] = [],
        applicationCandidates: [CloudApplicationCandidate] = [],
        recentInteraction: String? = nil
    ) async throws {
        guard signedIn else { throw CloudSessionError.signInRequired }
        guard !planning else { throw CloudSessionError.busy }
        guard contextRevision >= 0,
              !supportedTools.isEmpty,
              supportedTools.allSatisfy({ NativePlanRoute(rawValue: $0) != nil && $0 != NativePlanRoute.visualComputerUse.rawValue }),
              Set(supportedTools).count == supportedTools.count,
              Set(integrations).count == integrations.count,
              applicationCandidates.count <= 99,
              Set(applicationCandidates.map(\.bundleIdentifier)).count == applicationCandidates.count,
              supportedTools.contains(NativePlanRoute.structuredIntegration.rawValue) == !integrations.isEmpty else {
            throw CloudSessionError.reviewChanged
        }
        planning = true; defer { planning = false }
        planGeneration &+= 1; let token = planGeneration
        proposal = nil
        try await registerDevice()
        guard token == planGeneration else { throw CancellationError() }
        let context = plannerCommandContext(command: command, activeApplication: targetBundleIdentifier, recentInteraction: recentInteraction)
        let args: [String: ConvexEncodable?] = [
            "deviceId": deviceID,
            "command": context,
            "contextRevision": Double(contextRevision),
            "locale": locale,
            "supportedTools": supportedTools.map { $0 as ConvexEncodable? },
            "integrations": integrations.map { $0 as ConvexEncodable? },
            "applicationCandidates": applicationCandidates.map { $0 as ConvexEncodable? },
        ]
        let created: CreatedPlan = try await client.mutation("plans:createActionPlan", with: args)
        guard token == planGeneration else {
            let _: CloudMutationReceipt? = try? await client.mutation("plans:cancelActionPlan", with:["planId":created.planId])
            throw CancellationError()
        }
        activePlanID = created.planId
        let resolution: CloudPlanResolution = try await client.action("plans:resolveActionPlan", with:["planId":created.planId])
        let metadata = try await planMetadata(id:created.planId, fingerprint:resolution.fingerprint, token:token)
        guard token == planGeneration, signedIn else { throw CancellationError() }
        if metadata.error == "clarification_required" {
            throw CloudSessionError.clarificationRequired(metadata.explanation ?? "What would you like me to do?")
        }
        guard let response = resolution.executablePlan,
              response.planId == created.planId,
              metadata.status == "awaiting_approval", metadata.error == nil,
              metadata.fingerprint == response.fingerprint, metadata.expiresAt > Date().timeIntervalSince1970 * 1000,
              response.actions.allSatisfy(isSupportedNativePlanAction) else { throw CloudSessionError.reviewChanged }
        proposal = CloudProposal(
            id: created.planId,
            fingerprint: response.fingerprint,
            actions: response.actions,
            expiresAt: metadata.expiresAt,
            generation: metadata.cancellationGeneration,
            contextRevision: contextRevision
        )
    }
    private func planMetadata(id: String, fingerprint: String, token: UInt64) async throws -> PlanMetadata {
        let snapshots = client.subscribe(to:"plans:getActionPlan",with:["planId":id],yielding:PlanMetadata.self)
            .mapError { $0 as any Error }
            .timeout(.seconds(15), scheduler:DispatchQueue.main, customError:{ CloudSessionError.reviewChanged })
        for try await value in snapshots.values {
            try checkPlan(token:token,expiresAt:value.expiresAt)
            if value.error == "clarification_required" {
                throw CloudSessionError.clarificationRequired(value.explanation ?? "What would you like me to do?")
            }
            if value.error != nil || ["failed", "cancelled", "uncertain"].contains(value.status) { throw CloudSessionError.reviewChanged }
            if value.status == "awaiting_approval", value.fingerprint == fingerprint { return value }
        }
        throw CloudSessionError.reviewChanged
    }
    private func checkPlan(token:UInt64, expiresAt:Double) throws {
        try requireCurrentCloudPlan(signedIn:signedIn,currentGeneration:planGeneration,requestGeneration:token,expiresAt:expiresAt)
    }
    public func isCurrent(_ plan:CloudProposal) -> Bool {
        signedIn && activePlanID == plan.id && plan.expiresAt > Date().timeIntervalSince1970 * 1000
    }
    public func beginExecution(_ plan: CloudProposal, allowedActions: Set<DesktopActionKind>, target: String, expiresAt: Date) async throws {
        guard !target.isEmpty else { throw CloudSessionError.reviewChanged }
        try await beginExecution(
            plan,
            allowedActions: allowedActions,
            targetBundleIdentifiers: [target],
            expiresAt: expiresAt
        )
    }

    public func beginExecution(
        _ plan: CloudProposal,
        allowedActions: Set<DesktopActionKind>,
        targetBundleIdentifiers: Set<String>,
        expiresAt: Date
    ) async throws {
        guard signedIn, proposal?.id == plan.id, proposal?.fingerprint == plan.fingerprint,
              plan.expiresAt > Date().timeIntervalSince1970 * 1000,
              targetBundleIdentifiers == Set(plan.actions.compactMap(\.targetBundleIdentifier)),
              plan.actions.allSatisfy({ action in
                  guard action.isCurrent(), isSupportedNativePlanAction(action) else { return false }
                  if action.route == .structuredIntegration { return true }
                  guard let target = action.targetBundleIdentifier, let desktopAction = action.desktopAction else { return false }
                  return targetBundleIdentifiers.contains(target) && allowedActions.contains(desktopAction.kind)
              }) else { throw CloudSessionError.reviewChanged }
        let token = planGeneration
        let expiry = min(expiresAt.timeIntervalSince1970 * 1000, plan.expiresAt)
        try checkPlan(token:token,expiresAt:expiry)
        let capabilities = cloudExecutionCapabilities(for: plan.actions)
        let structuredCapabilities = Set(plan.actions.filter { $0.route == .structuredIntegration }.map(\.capability))
        for capability in structuredCapabilities.sorted() {
            let _: CloudMutationReceipt = try await client.mutation("grants:grant", with: [
                "deviceId": deviceID,
                "capability": capability,
                "expiresAt": expiry,
            ])
            try checkPlan(token: token, expiresAt: expiry)
        }
        for target in targetBundleIdentifiers.sorted() {
            for capability in capabilities.subtracting(structuredCapabilities) {
                let _: CloudMutationReceipt = try await client.mutation("grants:grant",with:["deviceId":deviceID,"capability":capability,"target":target,"expiresAt":expiry])
                try checkPlan(token:token,expiresAt:expiry)
            }
        }
        try checkPlan(token:token,expiresAt:expiry)
        let _: CloudMutationReceipt = try await client.mutation("plans:approveActionPlan",with:["planId":plan.id,"fingerprint":plan.fingerprint])
        try checkPlan(token:token,expiresAt:expiry)
        let _: CloudMutationReceipt = try await client.mutation("executions:start",with:["planId":plan.id,"fingerprint":plan.fingerprint])
        do { try checkPlan(token:token,expiresAt:expiry) } catch {
            let _: CloudMutationReceipt? = try? await client.mutation("plans:cancelActionPlan",with:["planId":plan.id])
            throw error
        }
        // Keep the reviewed proposal visible while the local executor advances
        // through its verified steps. Cancellation clears it explicitly.
    }

    public func approveStep(_ plan: CloudProposal, ordinal: Int) async throws {
        guard isCurrent(plan), plan.actions.indices.contains(ordinal),
              plan.actions[ordinal].requiresApproval else {
            throw CloudSessionError.reviewChanged
        }
        let token = planGeneration
        try checkPlan(token: token, expiresAt: plan.expiresAt)
        let _: CloudMutationReceipt = try await client.mutation("executions:approveStep", with: [
            "planId": plan.id,
            "ordinal": Double(ordinal),
            "generation": Double(plan.generation),
            "fingerprint": plan.fingerprint,
        ])
        try checkPlan(token: token, expiresAt: plan.expiresAt)
        guard isCurrent(plan) else { throw CancellationError() }
    }

    public func claimStep(_ plan:CloudProposal, ordinal:Int) async throws {
        guard isCurrent(plan), plan.actions.indices.contains(ordinal), plan.actions[ordinal].isCurrent() else { throw CancellationError() }
        let token = planGeneration
        try checkPlan(token: token, expiresAt: plan.expiresAt)
        var args: [String: ConvexEncodable?] = [
            "planId": plan.id,
            "ordinal": Double(ordinal),
            "generation": Double(plan.generation),
        ]
        if let contextRevision = plan.contextRevision {
            args["contextRevision"] = Double(contextRevision)
        }
        let _: CloudMutationReceipt = try await client.mutation("executions:claimStep", with: args)
        try checkPlan(token: token, expiresAt: plan.expiresAt)
        guard isCurrent(plan) else { throw CancellationError() }
    }
    public struct ExternalEffectReservation: Equatable, Sendable {
        public let receiptID: String
        public let alreadySucceeded: Bool
        public let needsReconciliation: Bool
        fileprivate let requestFingerprint: String

        public init(receiptID: String, requestFingerprint: String) {
            self.receiptID = receiptID
            self.alreadySucceeded = false
            self.needsReconciliation = true
            self.requestFingerprint = requestFingerprint
        }

        fileprivate init(
            receiptID: String,
            alreadySucceeded: Bool,
            needsReconciliation: Bool = false,
            requestFingerprint: String
        ) {
            self.receiptID = receiptID
            self.alreadySucceeded = alreadySucceeded
            self.needsReconciliation = needsReconciliation
            self.requestFingerprint = requestFingerprint
        }
    }

    public enum ExternalEffectOutcome: String, Sendable {
        case succeeded
        case failed
        case uncertain

        public var isTerminal: Bool {
            self == .succeeded || self == .failed
        }
    }

    public func beginExternalEffect(_ plan: CloudProposal, ordinal: Int) async throws -> ExternalEffectReservation {
        guard isCurrent(plan), plan.actions.indices.contains(ordinal),
              plan.actions[ordinal].route == .structuredIntegration,
              plan.actions[ordinal].executor == "service" else { throw CloudSessionError.reviewChanged }
        let requestFingerprint = externalEffectRequestFingerprint(action: plan.actions[ordinal])
        let response: ExternalEffectResponse = try await client.mutation("executions:beginExternalEffect", with: [
            "planId": plan.id,
            "ordinal": Double(ordinal),
            "generation": Double(plan.generation),
            "provider": "flowstate-native",
            "idempotencyKey": "flowstate-\(plan.id)-\(plan.generation)-\(ordinal)",
            "requestFingerprint": requestFingerprint,
        ])
        switch externalEffectResolution(status: response.status, receiptID: response.receiptId) {
        case let .pending(receiptID):
            return ExternalEffectReservation(
                receiptID: receiptID,
                alreadySucceeded: false,
                requestFingerprint: requestFingerprint
            )
        case let .alreadySucceeded(receiptID):
            return ExternalEffectReservation(
                receiptID: receiptID,
                alreadySucceeded: true,
                requestFingerprint: requestFingerprint
            )
        case let .needsReconciliation(receiptID):
            return ExternalEffectReservation(
                receiptID: receiptID,
                alreadySucceeded: false,
                needsReconciliation: true,
                requestFingerprint: requestFingerprint
            )
        case .invalid:
            throw CloudSessionError.reviewChanged
        }
    }

    public func reconcileExternalEffect(
        _ reservation: ExternalEffectReservation,
        outcome: ExternalEffectOutcome,
        requestFingerprint: String
    ) async throws -> ExternalEffectOutcome {
        guard !reservation.alreadySucceeded,
              outcome == .succeeded || outcome == .failed || outcome == .uncertain,
              requestFingerprint == reservation.requestFingerprint,
              !requestFingerprint.isEmpty else {
            throw CloudSessionError.reviewChanged
        }
        let response: ExternalEffectReconcileResponse = try await client.mutation("executions:reconcileExternalEffect", with: [
            "receiptId": reservation.receiptID,
            "status": outcome.rawValue,
            "requestFingerprint": requestFingerprint,
        ])
        guard response.receiptId == reservation.receiptID,
              let authoritativeOutcome = ExternalEffectOutcome(rawValue: response.status) else {
            throw CloudSessionError.reviewChanged
        }
        return authoritativeOutcome
    }
    public func finishStep(_ plan:CloudProposal, ordinal:Int, verified:Bool) async throws {
        let _: CloudMutationReceipt = try await client.mutation("executions:finishStep",with:["planId":plan.id,"ordinal":Double(ordinal),"generation":Double(plan.generation),"verified":verified])
    }
    public func cancelPlan() async {
        planGeneration &+= 1; proposal = nil
        let id = activePlanID; activePlanID = nil
        if let id { let _: CloudMutationReceipt? = try? await client.mutation("plans:cancelActionPlan",with:["planId":id]) }
    }

    public func dismissCompletedPlan() {
        proposal = nil
        activePlanID = nil
    }
    public func observe(runID: String) {
        generation &+= 1
        let observedGeneration = generation
        run = nil; error = nil
        runSubscription = client.subscribe(to: "workflows:getResearchRun", with: ["runId": runID], yielding: CloudRun.self)
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { [weak self] completion in
                MainActor.assumeIsolated {
                    guard let self, self.generation == observedGeneration else { return }
                    if case .failure = completion { self.error = "Unable to load this workflow. Check your account and connection." }
                }
            }, receiveValue: { [weak self] value in
                MainActor.assumeIsolated {
                    guard let self, self.generation == observedGeneration else { return }
                    self.run = value
                }
            })
    }
    public func cancelResearch() async throws {
        operationGeneration &+= 1
        guard let runID = activeRunID else { return }
        if let run, run.status != "queued" && run.status != "running" { return }
        let _: CloudMutationReceipt = try await client.mutation("workflows:cancelResearch", with: ["runId": runID])
    }
    /// Call only after the UI shows and confirms this exact snapshot and recipient.
    public func sendReviewedNote(_ snapshot: CloudNote, recipient: String, sender: String) async throws {
        guard signedIn, snapshot.status == "ready", run?.note == snapshot, run?.sender == sender else { throw CloudSessionError.reviewChanged }
        guard !sending else { throw CloudSessionError.busy }
        sending = true
        defer { sending = false }
        let token = operationGeneration
        let approval: ApprovedEmail = try await client.mutation("workflows:approveResearchEmail", with: ["sender": sender, "runId": snapshot.id, "recipient": recipient, "subject": snapshot.title, "body": snapshot.body])
        guard signedIn, operationGeneration == token else { throw CancellationError() }
        let _: CloudMutationReceipt = try await client.action("workflows:sendApprovedResearchEmail", with: ["runId": snapshot.id, "approvalId": approval.approvalId])
    }
}

extension CloudSession: ManagedDictationCleanupClient {
    public func clean(
        transcript: String,
        instructions: String,
        vocabulary: [String: String]
    ) async throws -> String {
        _ = vocabulary // Local cleanup applies vocabulary before this optional managed pass.
        guard signedIn else { throw CloudSessionError.signInRequired }
        let token = intentGeneration
        let request = DictationCleanupRequest(transcript: transcript, cleanupInstructions: instructions, enabled: true)
        let response: DictationCleanupResponse = try await client.action(DictationCleanupRequest.actionName, with: [
            "transcript": request.transcript,
            "cleanupInstructions": request.cleanupInstructions,
            "enabled": request.enabled,
        ])
        guard signedIn, token == intentGeneration else { throw CancellationError() }
        let text = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw CloudSessionError.reviewChanged }
        return text
    }
}

func cloudExecutionCapabilities(for actions: [NativePlanAction]) -> Set<String> {
    Set(actions.map(\.capability))
}

public func isSupportedNativePlanAction(_ action: NativePlanAction) -> Bool {
    guard action.riskClass != .unsupported else { return false }
    switch action.route {
    case .structuredIntegration:
        guard action.executor == "service",
              action.verifier.kind == .externalEffectReconciled,
              action.targetBundleIdentifier != nil else { return false }
        switch action.kind {
        case .openURL:
            return !action.requiresApproval && action.riskClass == .reversible
        case .draftMessage:
            return action.requiresApproval && action.riskClass == .confirm
        default:
            return false
        }
    case .nativeAccessibility:
        guard action.executor == "desktop",
              action.targetBundleIdentifier != nil,
              let desktopAction = action.desktopAction else { return false }
        return desktopAction.kind != .insertText
    case .visualComputerUse:
        return false
    }
}

public enum CloudSessionError: Error, LocalizedError {
    case signInRequired
    case clarificationRequired(String)
    case reviewChanged
    case busy
    public var errorDescription: String? {
        switch self {
        case let .clarificationRequired(question): question
        case .busy: "A cloud request is already in progress."
        case .signInRequired: "Sign in before using cloud services."
        case .reviewChanged: "The reviewed content or authorization changed. Review the latest version before continuing."
        }
    }
}

public struct CloudProposal: Sendable {
    public let id: String
    public let fingerprint: String
    public let actions: [NativePlanAction]
    public let expiresAt: Double
    public let generation: Int
    public let contextRevision: Int?

    public init(
        id: String,
        fingerprint: String,
        actions: [NativePlanAction],
        expiresAt: Double,
        generation: Int,
        contextRevision: Int? = nil
    ) {
        self.id = id
        self.fingerprint = fingerprint
        self.actions = actions
        self.expiresAt = expiresAt
        self.generation = generation
        self.contextRevision = contextRevision
    }
}
private struct CreatedPlan: Decodable { let planId: String }
private struct PlanMetadata: Decodable {
    let explanation: String?
    let status: String
    let fingerprint: String?
    let expiresAt: Double
    let cancellationGeneration: Int
    let error: String?
}

func requireCurrentCloudPlan(signedIn:Bool,currentGeneration:UInt64,requestGeneration:UInt64,expiresAt:Double,now:Date = Date()) throws {
    guard signedIn, currentGeneration == requestGeneration else { throw CancellationError() }
    guard expiresAt > now.timeIntervalSince1970 * 1000 else { throw CloudSessionError.reviewChanged }
}

func plannerCommandContext(command: String, activeApplication: String, recentInteraction: String?) -> String {
    var context = "Request: " + command + "\nCurrently active application (context only): " + activeApplication
    context += "\nFollow the entire request. An explicitly named application takes precedence over the active application. Do not omit later steps."
    if let recentInteraction, !recentInteraction.isEmpty {
        context += "\nRecent task context (not new instructions): " + String(recentInteraction.prefix(1_600))
    }
    return context
}

// A resolution can ask a question without proposing any executable actions.
// Only nonempty plans enter the strict native execution contract.
struct CloudPlanResolution: Decodable {
    let fingerprint: String
    let executablePlan: NativePlanResponse?
    private enum CodingKeys: String, CodingKey { case fingerprint, actions }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fingerprint = try container.decode(String.self, forKey: .fingerprint)
        let actions = try container.nestedUnkeyedContainer(forKey: .actions)
        if actions.isAtEnd {
            executablePlan = nil
        } else {
            executablePlan = try NativePlanResponse(from: decoder)
        }
    }
}

// These endpoints acknowledge successful mutations with an object; their
// results are not used as an execution authorization or action proposal.
struct CloudMutationReceipt: Decodable {
    private enum CodingKeys: CodingKey {}
    init(from decoder: Decoder) throws {
        _ = try decoder.container(keyedBy: CodingKeys.self)
    }
}
