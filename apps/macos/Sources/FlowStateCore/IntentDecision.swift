import Foundation

public enum IntentDecisionDecodingError: Error, Equatable, LocalizedError, Sendable {
    case malformed(String)
    case unknownField(String)
    case invalidCombination(String)
    case stale

    public var errorDescription: String? {
        switch self {
        case let .malformed(message): "Malformed intent decision: \(message)"
        case let .unknownField(field): "Unknown intent decision field: \(field)"
        case let .invalidCombination(message): "Invalid intent decision: \(message)"
        case .stale: "This intent decision belongs to an obsolete request context."
        }
    }
}

public enum IntentDecisionKind: String, Codable, Equatable, Sendable {
    case execute
    case dictation
    case clarify
    case unsupported
    case abstain
}

public struct IntentDecisionConfidence: Codable, Equatable, Sendable {
    public let intent: Double
    public let action: Double?
    public let target: Double?
    public let topTwoMargin: Double?

    public init(intent: Double, action: Double? = nil, target: Double? = nil, topTwoMargin: Double? = nil) throws {
        try Self.validate(intent, name: "intent")
        if let action { try Self.validate(action, name: "action") }
        if let target { try Self.validate(target, name: "target") }
        if let topTwoMargin { try Self.validate(topTwoMargin, name: "topTwoMargin") }
        self.intent = intent
        self.action = action
        self.target = target
        self.topTwoMargin = topTwoMargin
    }

    private static func validate(_ value: Double, name: String) throws {
        guard value.isFinite, (0...1).contains(value) else {
            throw IntentDecisionDecodingError.invalidCombination("\(name) confidence must be between 0 and 1.")
        }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case intent
        case action
        case target
        case topTwoMargin
    }

    public init(from decoder: Decoder) throws {
        let allFields = try decoder.container(keyedBy: AnyIntentCodingKey.self)
        try rejectUnknownKeys(allFields.allKeys, allowed: CodingKeys.allCases.map(\.stringValue))
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            intent: values.decode(Double.self, forKey: .intent),
            action: values.decodeIfPresent(Double.self, forKey: .action),
            target: values.decodeIfPresent(Double.self, forKey: .target),
            topTwoMargin: values.decodeIfPresent(Double.self, forKey: .topTwoMargin)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(intent, forKey: .intent)
        try values.encodeIfPresent(action, forKey: .action)
        try values.encodeIfPresent(target, forKey: .target)
        try values.encodeIfPresent(topTwoMargin, forKey: .topTwoMargin)
    }
}

public struct IntentDecisionModel: Codable, Equatable, Sendable {
    public let jev: String
    public let fallback: String?

    public init(jev: String, fallback: String? = nil) throws {
        let jev = jev.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !jev.isEmpty else { throw IntentDecisionDecodingError.malformed("model.jev is required.") }
        self.jev = jev
        self.fallback = fallback?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case jev
        case fallback
    }

    public init(from decoder: Decoder) throws {
        let allFields = try decoder.container(keyedBy: AnyIntentCodingKey.self)
        try rejectUnknownKeys(allFields.allKeys, allowed: CodingKeys.allCases.map(\.stringValue))
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            jev: values.decode(String.self, forKey: .jev),
            fallback: values.decodeIfPresent(String.self, forKey: .fallback)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(jev, forKey: .jev)
        try values.encodeIfPresent(fallback, forKey: .fallback)
    }
}

public struct IntentDecisionUsage: Codable, Equatable, Sendable {
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let totalTokens: Int?
    public let estimatedCostUSD: Double?

    public init(inputTokens: Int? = nil, outputTokens: Int? = nil, totalTokens: Int? = nil, estimatedCostUSD: Double? = nil) throws {
        for (name, value) in [("inputTokens", inputTokens), ("outputTokens", outputTokens), ("totalTokens", totalTokens)] {
            if let value, value < 0 { throw IntentDecisionDecodingError.invalidCombination("usage.\(name) cannot be negative.") }
        }
        if let estimatedCostUSD, !estimatedCostUSD.isFinite || estimatedCostUSD < 0 {
            throw IntentDecisionDecodingError.invalidCombination("usage.estimatedCostUSD is invalid.")
        }
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
        self.estimatedCostUSD = estimatedCostUSD
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case inputTokens
        case outputTokens
        case totalTokens
        case estimatedCostUSD
    }

    public init(from decoder: Decoder) throws {
        let allFields = try decoder.container(keyedBy: AnyIntentCodingKey.self)
        try rejectUnknownKeys(allFields.allKeys, allowed: CodingKeys.allCases.map(\.stringValue))
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            inputTokens: values.decodeIfPresent(Int.self, forKey: .inputTokens),
            outputTokens: values.decodeIfPresent(Int.self, forKey: .outputTokens),
            totalTokens: values.decodeIfPresent(Int.self, forKey: .totalTokens),
            estimatedCostUSD: values.decodeIfPresent(Double.self, forKey: .estimatedCostUSD)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeIfPresent(inputTokens, forKey: .inputTokens)
        try values.encodeIfPresent(outputTokens, forKey: .outputTokens)
        try values.encodeIfPresent(totalTokens, forKey: .totalTokens)
        try values.encodeIfPresent(estimatedCostUSD, forKey: .estimatedCostUSD)
    }
}

public struct IntentDecisionAction: Codable, Equatable, Sendable {
    public let targetID: String?
    public let nativePlanAction: NativePlanAction

    public var kind: NativePlanActionKind { nativePlanAction.kind }
    public var targetBundleIdentifier: String? { nativePlanAction.targetBundleIdentifier }
    public var capability: String { nativePlanAction.capability }
    public var executor: String { nativePlanAction.executor }
    public var requiresApproval: Bool { nativePlanAction.requiresApproval }

    private let parameters: [String: NativePlanJSONValue]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case kind
        case targetId
        case targetBundleIdentifier
        case parameters
        case capability
        case executor
        case requiresApproval
        case visualTarget
    }

    public init(from decoder: Decoder) throws {
        let allFields = try decoder.container(keyedBy: AnyIntentCodingKey.self)
        try rejectUnknownKeys(allFields.allKeys, allowed: CodingKeys.allCases.map(\.stringValue))
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try values.decode(String.self, forKey: .kind)
        guard let actionKind = NativePlanActionKind(rawValue: kind) else {
            throw IntentDecisionDecodingError.invalidCombination("unsupported native action \(kind).")
        }
        guard actionKind != .insertText else {
            throw IntentDecisionDecodingError.invalidCombination("insertText is available only through the Dictation shortcut.")
        }
        let targetID = try values.decodeIfPresent(String.self, forKey: .targetId)?.trimmedNonEmpty
        let targetBundle = try values.decodeIfPresent(String.self, forKey: .targetBundleIdentifier)?.trimmedNonEmpty
        let parameters = try values.decodeIfPresent([String: NativePlanJSONValue].self, forKey: .parameters) ?? [:]
        let capability = try values.decodeIfPresent(String.self, forKey: .capability)
            ?? Self.defaultCapability(for: actionKind)
        let executor = try values.decodeIfPresent(String.self, forKey: .executor) ?? "desktop"
        let visualTarget = try values.decodeIfPresent(NativePlanJSONValue.self, forKey: .visualTarget)
        let requiresApproval = try values.decodeIfPresent(Bool.self, forKey: .requiresApproval)
            ?? Self.defaultRequiresApproval(kind: actionKind, parameters: parameters)

        var object: [String: NativePlanJSONValue] = [
            "kind": .string(actionKind.rawValue),
            "targetBundleIdentifier": targetBundle.map(NativePlanJSONValue.string) ?? .null,
            "parameters": .object(parameters),
            "capability": .string(capability),
            "executor": .string(executor),
            "requiresApproval": .boolean(requiresApproval)
        ]
        if let targetID { object["targetId"] = .string(targetID) }
        if let visualTarget { object["visualTarget"] = visualTarget }
        let nativePlanAction: NativePlanAction
        do {
            nativePlanAction = try JSONDecoder().decode(
                NativePlanAction.self,
                from: JSONEncoder().encode(NativePlanJSONValue.object(object))
            )
        } catch let error as NativePlanDecodingError {
            throw IntentDecisionDecodingError.invalidCombination(error.localizedDescription)
        } catch {
            throw IntentDecisionDecodingError.malformed(String(describing: error))
        }
        self.targetID = targetID
        self.nativePlanAction = nativePlanAction
        self.parameters = parameters
    }

    private init(targetID: String?, nativePlanAction: NativePlanAction, parameters: [String: NativePlanJSONValue]) {
        self.targetID = targetID
        self.nativePlanAction = nativePlanAction
        self.parameters = parameters
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(nativePlanAction.kind.rawValue, forKey: .kind)
        try values.encodeIfPresent(targetID, forKey: .targetId)
        try values.encode(nativePlanAction.targetBundleIdentifier, forKey: .targetBundleIdentifier)
        try values.encode(parameters, forKey: .parameters)
        try values.encode(nativePlanAction.capability, forKey: .capability)
        try values.encode(nativePlanAction.executor, forKey: .executor)
        try values.encode(nativePlanAction.requiresApproval, forKey: .requiresApproval)
        if nativePlanAction.visualTarget != nil { try values.encode(nativePlanAction.visualTarget, forKey: .visualTarget) }
    }

    private static func defaultCapability(for kind: NativePlanActionKind) -> String {
        switch kind {
        case .openApplication: "app.open"
        case .scroll, .focus, .select, .click: "app.control"
        case .press, .insertText: "app.input"
        case .openURL: "app.control"
        case .attachFile: "file.upload"
        case .sendEmail: "mail.send"
        case .draftMessage: "mail.draft"
        }
    }

    private static func defaultRequiresApproval(kind: NativePlanActionKind, parameters: [String: NativePlanJSONValue]) -> Bool {
        if kind == .click || kind == .openURL || kind == .attachFile || kind == .sendEmail || kind == .draftMessage { return true }
        guard kind == .insertText || kind == .press else { return false }
        if kind == .insertText { return true }
        let key = parameters["key"]?.stringValue
        let modifiers = parameters["modifiers"]?.stringValue
        return key == "Enter" || modifiers != nil
    }
}

public struct IntentDecision: Codable, Equatable, Sendable {
    public let requestID: String
    public let sessionID: String
    public let utteranceID: String
    public let contextRevision: Int
    public let policyVersion: String
    /// Optional policy metadata is accepted only as the backend's explicit
    /// envelope fields; action and confidence schemas remain strict.
    public let policyRevision: String?
    public let reason: String?
    public let decision: IntentDecisionKind
    public let intent: String?
    public let action: IntentDecisionAction?
    public let textFallbackUsed: Bool
    public let visionFallbackUsed: Bool
    public let requiresObservation: Bool
    public let clarification: String?
    public let confidence: IntentDecisionConfidence
    public let model: IntentDecisionModel
    public let usage: IntentDecisionUsage?
    public let latencyMs: Int?

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case requestId
        case sessionId
        case utteranceId
        case contextRevision
        case policyVersion
        case policyRevision
        case reason
        case decision
        case intent
        case action
        case textFallbackUsed
        case visionFallbackUsed
        case requiresObservation
        case clarification
        case confidence
        case model
        case usage
        case latencyMs
    }

    public static func decode(_ data: Data, using decoder: JSONDecoder = JSONDecoder()) throws -> Self {
        do { return try decoder.decode(Self.self, from: data) }
        catch let error as IntentDecisionDecodingError { throw error }
        catch { throw IntentDecisionDecodingError.malformed(String(describing: error)) }
    }

    public init(from decoder: Decoder) throws {
        let allFields = try decoder.container(keyedBy: AnyIntentCodingKey.self)
        try rejectUnknownKeys(allFields.allKeys, allowed: CodingKeys.allCases.map(\.stringValue))
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let requestID = try values.decode(String.self, forKey: .requestId).trimmedNonEmpty
        let sessionID = try values.decode(String.self, forKey: .sessionId).trimmedNonEmpty
        let utteranceID = try values.decode(String.self, forKey: .utteranceId).trimmedNonEmpty
        let contextRevision = try values.decode(Int.self, forKey: .contextRevision)
        guard contextRevision >= 0 else { throw IntentDecisionDecodingError.invalidCombination("contextRevision cannot be negative.") }
        let policyVersion = try values.decode(String.self, forKey: .policyVersion).trimmedNonEmpty
        let policyRevision = try values.decodeIfPresent(String.self, forKey: .policyRevision)?.trimmedNonEmpty
        let reason = try values.decodeIfPresent(String.self, forKey: .reason)?.trimmedNonEmpty
        let decision = try values.decode(IntentDecisionKind.self, forKey: .decision)
        let intent = try values.decodeIfPresent(String.self, forKey: .intent)?.trimmedNonEmpty
        let action = try values.decodeIfPresent(IntentDecisionAction.self, forKey: .action)
        let textFallbackUsed = try values.decode(Bool.self, forKey: .textFallbackUsed)
        let visionFallbackUsed = try values.decode(Bool.self, forKey: .visionFallbackUsed)
        let requiresObservation = try values.decode(Bool.self, forKey: .requiresObservation)
        let clarification = try values.decodeIfPresent(String.self, forKey: .clarification)?.trimmedNonEmpty
        let confidence = try values.decode(IntentDecisionConfidence.self, forKey: .confidence)
        let model = try values.decode(IntentDecisionModel.self, forKey: .model)
        let usage = try values.decodeIfPresent(IntentDecisionUsage.self, forKey: .usage)
        let latencyMs = try values.decodeIfPresent(Int.self, forKey: .latencyMs)
        if let latencyMs, latencyMs < 0 { throw IntentDecisionDecodingError.invalidCombination("latencyMs cannot be negative.") }

        switch decision {
        case .execute:
            guard action != nil else { throw IntentDecisionDecodingError.invalidCombination("execute requires action.") }
        case .dictation:
            throw IntentDecisionDecodingError.invalidCombination("dictation is not a Mac Control decision; use the Dictation shortcut.")
        case .clarify:
            guard action == nil, clarification != nil else {
                throw IntentDecisionDecodingError.invalidCombination("clarify cannot execute an action and needs clarification.")
            }
        case .unsupported, .abstain:
            guard action == nil else {
                throw IntentDecisionDecodingError.invalidCombination("\(decision.rawValue) cannot include an action.")
            }
        }

        self.requestID = requestID
        self.sessionID = sessionID
        self.utteranceID = utteranceID
        self.contextRevision = contextRevision
        self.policyVersion = policyVersion
        self.policyRevision = policyRevision
        self.reason = reason
        self.decision = decision
        self.intent = intent
        self.action = action
        self.textFallbackUsed = textFallbackUsed
        self.visionFallbackUsed = visionFallbackUsed
        self.requiresObservation = requiresObservation
        self.clarification = clarification
        self.confidence = confidence
        self.model = model
        self.usage = usage
        self.latencyMs = latencyMs
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(requestID, forKey: .requestId)
        try values.encode(sessionID, forKey: .sessionId)
        try values.encode(utteranceID, forKey: .utteranceId)
        try values.encode(contextRevision, forKey: .contextRevision)
        try values.encode(policyVersion, forKey: .policyVersion)
        try values.encodeIfPresent(policyRevision, forKey: .policyRevision)
        try values.encodeIfPresent(reason, forKey: .reason)
        try values.encode(decision, forKey: .decision)
        try values.encodeIfPresent(intent, forKey: .intent)
        try values.encodeIfPresent(action, forKey: .action)
        try values.encode(textFallbackUsed, forKey: .textFallbackUsed)
        try values.encode(visionFallbackUsed, forKey: .visionFallbackUsed)
        try values.encode(requiresObservation, forKey: .requiresObservation)
        try values.encodeIfPresent(clarification, forKey: .clarification)
        try values.encode(confidence, forKey: .confidence)
        try values.encode(model, forKey: .model)
        try values.encodeIfPresent(usage, forKey: .usage)
        try values.encodeIfPresent(latencyMs, forKey: .latencyMs)
    }
}

public struct IntentDecisionStaleChecker: Sendable, Equatable {
    public let requestID: String
    public let sessionID: String
    public let utteranceID: String
    public let contextRevision: Int
    public let policyVersion: String

    public init(requestID: String, sessionID: String, utteranceID: String, contextRevision: Int, policyVersion: String) {
        self.requestID = requestID
        self.sessionID = sessionID
        self.utteranceID = utteranceID
        self.contextRevision = contextRevision
        self.policyVersion = policyVersion
    }

    public func isCurrent(_ decision: IntentDecision) -> Bool {
        requestID == decision.requestID &&
            sessionID == decision.sessionID &&
            utteranceID == decision.utteranceID &&
            contextRevision == decision.contextRevision &&
            policyVersion == decision.policyVersion
    }

    public func validate(_ decision: IntentDecision) throws {
        guard isCurrent(decision) else { throw IntentDecisionDecodingError.stale }
    }
}

private struct AnyIntentCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

private func rejectUnknownKeys<K: CodingKey>(_ keys: [K], allowed: [String]) throws {
    let allowedValues = Set(allowed)
    if let unknown = keys.first(where: { !allowedValues.contains($0.stringValue) }) {
        throw IntentDecisionDecodingError.unknownField(unknown.stringValue)
    }
}

private extension String {
    var trimmedNonEmpty: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension NativePlanJSONValue {
    var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }
}
