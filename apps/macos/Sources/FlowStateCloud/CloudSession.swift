import Foundation
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
private struct ApprovedEmail: Decodable { let approvalId: String }

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
        try await client.mutation("workflows:registerDevice", with: ["deviceId": deviceID, "name": "Flow State Mac"])
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
            try? await client.mutation("workflows:cancelResearch", with: ["runId": created.runId])
            throw CancellationError()
        }
        activeRunID = created.runId
        observe(runID: created.runId)
        try await client.action("workflows:runResearch", with: ["runId": created.runId])
    }
    public func cancelIntent() { intentGeneration &+= 1 }

    public func routeIntent(utterance: String, sessionID: String, utteranceID: String,
                            contextRevision: Int, mode: String, context: CloudIntentContext,
                            grant: DesktopExecutionGrant?, observation: CloudIntentObservation? = nil,
                            observationAllowedUntil: Date? = nil) async throws -> IntentDecision {
        guard signedIn else { throw CloudSessionError.signInRequired }
        let token = intentGeneration
        try await registerDevice()
        guard signedIn, token == intentGeneration else { throw CancellationError() }
        var capabilities = Set<String>()
        if let grant, grant.expiresAt > Date() {
            for action in grant.allowedActions {
                capabilities.insert(action == .openApplication ? "app.open" : (action == .insertText || action == .press) ? "app.input" : "app.control")
            }
            for target in grant.allowedBundleIdentifiers {
                for capability in capabilities.sorted() {
                    guard signedIn, token == intentGeneration, grant.expiresAt > Date() else { throw CancellationError() }
                    try await client.mutation("grants:grant", with: ["deviceId": deviceID, "capability": capability,
                        "target": target, "expiresAt": grant.expiresAt.timeIntervalSince1970 * 1000])
                }
            }
        }
        if observation != nil, let expiry = observationAllowedUntil, expiry > Date(),
           let target = context.focusedAppBundleIdentifier {
            for capability in ["app.observe", "app.upload"] {
                guard signedIn, token == intentGeneration else { throw CancellationError() }
                try await client.mutation("grants:grant", with: ["deviceId": deviceID, "capability": capability,
                    "target": target, "expiresAt": expiry.timeIntervalSince1970 * 1000])
                capabilities.insert(capability)
            }
        }
        guard signedIn, token == intentGeneration else { throw CancellationError() }
        let response: IntentDecision = try await client.action("intents:route", with: [
            "deviceId": deviceID, "sessionId": sessionID, "utteranceId": utteranceID,
            "contextRevision": Double(contextRevision), "utterance": utterance, "mode": mode,
            "context": context, "supportedActions": ["openApplication", "scroll", "focus", "select", "press", "insertText"],
            "supportedCapabilities": capabilities.sorted().map { $0 as (any ConvexEncodable)? }, "policyVersion": "intent-v1", "observation": observation,
        ])
        try requireCurrentIntent(signedIn: signedIn, currentGeneration: intentGeneration, requestGeneration: token,
            expectedSession: sessionID, returnedSession: response.sessionID,
            expectedUtterance: utteranceID, returnedUtterance: response.utteranceID,
            expectedRevision: contextRevision, returnedRevision: response.contextRevision)
        return response
    }

    public func preparePlan(command: String, targetBundleIdentifier: String, locale: String) async throws {
        guard signedIn else { throw CloudSessionError.signInRequired }
        guard !planning else { throw CloudSessionError.busy }
        planning = true; defer { planning = false }
        planGeneration &+= 1; let token = planGeneration
        proposal = nil
        try await registerDevice()
        guard token == planGeneration else { throw CancellationError() }
        let context = command + "\nSelected target application: " + targetBundleIdentifier + ". Use only openApplication, scroll, insertText. Start by opening the selected target. Unsupported requests need clarification."
        let created: CreatedPlan = try await client.mutation("plans:createActionPlan", with: ["deviceId":deviceID,"command":context,"locale":locale])
        guard token == planGeneration else {
            try? await client.mutation("plans:cancelActionPlan", with:["planId":created.planId])
            throw CancellationError()
        }
        activePlanID = created.planId
        let response: NativePlanResponse = try await client.action("plans:resolveActionPlan", with:["planId":created.planId])
        let metadata = try await planMetadata(id:created.planId, fingerprint:response.fingerprint, token:token)
        guard token == planGeneration, signedIn, metadata.status == "awaiting_approval", metadata.error == nil,
              metadata.fingerprint == response.fingerprint, metadata.expiresAt > Date().timeIntervalSince1970 * 1000,
              response.actions.allSatisfy({ $0.targetBundleIdentifier == targetBundleIdentifier }) else { throw CloudSessionError.reviewChanged }
        proposal = CloudProposal(id:created.planId, fingerprint:response.fingerprint, actions:response.actions,expiresAt:metadata.expiresAt,generation:metadata.cancellationGeneration)
    }
    private func planMetadata(id: String, fingerprint: String, token: UInt64) async throws -> PlanMetadata {
        let snapshots = client.subscribe(to:"plans:getActionPlan",with:["planId":id],yielding:PlanMetadata.self)
            .mapError { $0 as any Error }
            .timeout(.seconds(15), scheduler:DispatchQueue.main, customError:{ CloudSessionError.reviewChanged })
        for try await value in snapshots.values {
            try checkPlan(token:token,expiresAt:value.expiresAt)
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
        guard signedIn, proposal?.id == plan.id, proposal?.fingerprint == plan.fingerprint,
              plan.expiresAt > Date().timeIntervalSince1970 * 1000,
              plan.actions.allSatisfy({ $0.targetBundleIdentifier == target && allowedActions.contains($0.desktopAction.kind) }) else { throw CloudSessionError.reviewChanged }
        let token = planGeneration
        let expiry = min(expiresAt.timeIntervalSince1970 * 1000, plan.expiresAt)
        try checkPlan(token:token,expiresAt:expiry)
        let capabilities = cloudExecutionCapabilities(for: plan.actions)
        for capability in capabilities {
            try await client.mutation("grants:grant",with:["deviceId":deviceID,"capability":capability,"target":target,"expiresAt":expiry])
            try checkPlan(token:token,expiresAt:expiry)
        }
        try checkPlan(token:token,expiresAt:expiry)
        try await client.mutation("plans:approveActionPlan",with:["planId":plan.id,"fingerprint":plan.fingerprint])
        try checkPlan(token:token,expiresAt:expiry)
        try await client.mutation("executions:start",with:["planId":plan.id,"fingerprint":plan.fingerprint])
        do { try checkPlan(token:token,expiresAt:expiry) } catch {
            try? await client.mutation("plans:cancelActionPlan",with:["planId":plan.id])
            throw error
        }
        proposal = nil
    }
    public func claimStep(_ plan:CloudProposal, ordinal:Int) async throws {
        guard isCurrent(plan) else { throw CancellationError() }
        let token = planGeneration
        try checkPlan(token: token, expiresAt: plan.expiresAt)
        try await client.mutation("executions:claimStep",with:["planId":plan.id,"ordinal":Double(ordinal),"generation":Double(plan.generation)])
        try checkPlan(token: token, expiresAt: plan.expiresAt)
        guard isCurrent(plan) else { throw CancellationError() }
    }
    public func finishStep(_ plan:CloudProposal, ordinal:Int, verified:Bool) async throws {
        try await client.mutation("executions:finishStep",with:["planId":plan.id,"ordinal":Double(ordinal),"generation":Double(plan.generation),"verified":verified])
    }
    public func cancelPlan() async {
        planGeneration &+= 1; proposal = nil
        let id = activePlanID; activePlanID = nil
        if let id { try? await client.mutation("plans:cancelActionPlan",with:["planId":id]) }
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
        try await client.mutation("workflows:cancelResearch", with: ["runId": runID])
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
        try await client.action("workflows:sendApprovedResearchEmail", with: ["runId": snapshot.id, "approvalId": approval.approvalId])
    }
}

func cloudExecutionCapabilities(for actions: [NativePlanAction]) -> Set<String> {
    Set(actions.map(\.capability))
}

public enum CloudSessionError: Error, LocalizedError {
    case signInRequired
    case reviewChanged
    case busy
    public var errorDescription: String? {
        switch self {
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
}
private struct CreatedPlan: Decodable { let planId: String }
private struct PlanMetadata: Decodable {
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
