import Foundation

public enum NativePlanDecodingError: Error, Equatable, LocalizedError, Sendable {
    case malformed(String)
    case unknownField(String)
    case unsupportedAction(String)
    case unsupportedCapability(String)
    case unsupportedExecutor(String)
    case unsupportedVisualTarget
    case invalidTarget
    case invalidParameters(String)

    public var errorDescription: String? {
        switch self {
        case let .malformed(message): "Malformed native plan: \(message)"
        case let .unknownField(field): "Unknown native plan field: \(field)"
        case let .unsupportedAction(kind): "Unsupported native plan action: \(kind)"
        case let .unsupportedCapability(capability): "Unsupported native plan capability: \(capability)"
        case let .unsupportedExecutor(executor): "Unsupported native plan executor: \(executor)"
        case .unsupportedVisualTarget: "Visual targets are not available to the native executor."
        case .invalidTarget: "A native plan action needs a non-empty target bundle identifier."
        case let .invalidParameters(message): "Invalid native plan parameters: \(message)"
        }
    }
}

public enum NativePlanActionKind: String, Codable, Equatable, Sendable {
    case openApplication
    case scroll
    case insertText
}

public enum NativePlanParameters: Equatable, Sendable {
    case openApplication
    case scroll(lines: Int32)
    case insertText(text: String, replaceSelection: Bool)
}

public indirect enum NativePlanJSONValue: Codable, Equatable, Sendable {
    case null
    case boolean(Bool)
    case number(Double)
    case string(String)
    case array([NativePlanJSONValue])
    case object([String: NativePlanJSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([NativePlanJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: NativePlanJSONValue].self) {
            self = .object(value)
        } else {
            throw NativePlanDecodingError.malformed("Unsupported JSON value.")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case let .boolean(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        }
    }
}

public struct NativePlanAction: Codable, Equatable, Sendable, CustomStringConvertible {
    public let kind: NativePlanActionKind
    public let targetBundleIdentifier: String
    public let parameters: NativePlanParameters
    public let capability: String
    public let executor: String
    public let requiresApproval: Bool
    public let visualTarget: NativePlanJSONValue?

    public init(
        kind: NativePlanActionKind,
        targetBundleIdentifier: String,
        parameters: NativePlanParameters,
        capability: String,
        executor: String = "desktop",
        requiresApproval: Bool,
        visualTarget: NativePlanJSONValue? = nil
    ) {
        self.kind = kind
        self.targetBundleIdentifier = targetBundleIdentifier
        self.parameters = parameters
        self.capability = capability
        self.executor = executor
        self.requiresApproval = requiresApproval
        self.visualTarget = visualTarget
    }

    public var desktopAction: DesktopAction {
        switch parameters {
        case .openApplication:
            .openApplication(bundleIdentifier: targetBundleIdentifier)
        case let .scroll(lines):
            .scroll(lines: lines)
        case let .insertText(text, _):
            .insertText(text)
        }
    }

    public var summary: String {
        switch parameters {
        case .openApplication:
            return "Open \(targetBundleIdentifier)"
        case let .scroll(lines):
            let direction = lines < 0 ? "down" : "up"
            return "Scroll \(direction) in \(targetBundleIdentifier) (amount: \(abs(lines)))"
        case let .insertText(text, _):
            return "Insert text into \(targetBundleIdentifier): \(text)"
        }
    }

    public var description: String { summary }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case kind
        case targetBundleIdentifier
        case parameters
        case capability
        case executor
        case requiresApproval
        case visualTarget
    }

    private struct EmptyCodingKey: CodingKey {
        let stringValue: String
        let intValue: Int?

        init?(stringValue: String) {
            self.stringValue = stringValue
            intValue = nil
        }

        init?(intValue: Int) {
            stringValue = String(intValue)
            self.intValue = intValue
        }
    }

    private enum ScrollCodingKeys: String, CodingKey, CaseIterable {
        case lines
    }

    private enum InsertTextCodingKeys: String, CodingKey, CaseIterable {
        case text
        case replaceSelection
    }

    public init(from decoder: Decoder) throws {
        let allFields = try decoder.container(keyedBy: NativePlanCodingKey.self)
        try rejectUnknownKeys(
            allFields.allKeys,
            allowed: CodingKeys.allCases.map(\.stringValue)
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let kindValue = try container.decode(String.self, forKey: .kind)
        guard let kind = NativePlanActionKind(rawValue: kindValue) else {
            throw NativePlanDecodingError.unsupportedAction(kindValue)
        }
        let target = try container.decode(String.self, forKey: .targetBundleIdentifier)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { throw NativePlanDecodingError.invalidTarget }

        let capability = try container.decode(String.self, forKey: .capability)
        let expectedCapability: String = switch kind {
        case .openApplication, .scroll:
            "app.control"
        case .insertText:
            "app.input"
        }
        guard capability == expectedCapability else {
            throw NativePlanDecodingError.unsupportedCapability(capability)
        }

        let executor = try container.decode(String.self, forKey: .executor)
        guard executor == "desktop" else {
            throw NativePlanDecodingError.unsupportedExecutor(executor)
        }

        let requiresApproval = try container.decode(Bool.self, forKey: .requiresApproval)
        let expectedApproval = kind == .insertText
        guard requiresApproval == expectedApproval else {
            throw NativePlanDecodingError.invalidParameters(
                "requiresApproval must be \(expectedApproval) for \(kind.rawValue)."
            )
        }
        if container.contains(.visualTarget), try !container.decodeNil(forKey: .visualTarget) {
            throw NativePlanDecodingError.unsupportedVisualTarget
        }

        let parametersDecoder = try container.superDecoder(forKey: .parameters)
        let parameters: NativePlanParameters
        switch kind {
        case .openApplication:
            let allParameters = try parametersDecoder.container(keyedBy: NativePlanCodingKey.self)
            try rejectUnknownKeys(allParameters.allKeys, allowed: [])
            let parametersContainer = try parametersDecoder.container(keyedBy: EmptyCodingKey.self)
            _ = parametersContainer
            parameters = .openApplication
        case .scroll:
            let allParameters = try parametersDecoder.container(keyedBy: NativePlanCodingKey.self)
            try rejectUnknownKeys(
                allParameters.allKeys,
                allowed: ScrollCodingKeys.allCases.map(\.stringValue)
            )
            let parametersContainer = try parametersDecoder.container(keyedBy: ScrollCodingKeys.self)
            let lines = try parametersContainer.decode(Int32.self, forKey: .lines)
            guard (-100...100).contains(lines) else {
                throw NativePlanDecodingError.invalidParameters("lines must be between -100 and 100.")
            }
            parameters = .scroll(lines: lines)
        case .insertText:
            let allParameters = try parametersDecoder.container(keyedBy: NativePlanCodingKey.self)
            try rejectUnknownKeys(
                allParameters.allKeys,
                allowed: InsertTextCodingKeys.allCases.map(\.stringValue)
            )
            let parametersContainer = try parametersDecoder.container(keyedBy: InsertTextCodingKeys.self)
            let text = try parametersContainer.decode(String.self, forKey: .text)
            guard text.count <= 20_000 else {
                throw NativePlanDecodingError.invalidParameters("text is limited to 20,000 characters.")
            }
            let replaceSelection = try parametersContainer.decodeIfPresent(Bool.self, forKey: .replaceSelection) ?? true
            guard replaceSelection else {
                throw NativePlanDecodingError.invalidParameters("replaceSelection must be true.")
            }
            parameters = .insertText(text: text, replaceSelection: replaceSelection)
        }

        self.init(
            kind: kind,
            targetBundleIdentifier: target,
            parameters: parameters,
            capability: capability,
            executor: executor,
            requiresApproval: requiresApproval,
            visualTarget: nil
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind.rawValue, forKey: .kind)
        try container.encode(targetBundleIdentifier, forKey: .targetBundleIdentifier)
        try container.encode(capability, forKey: .capability)
        try container.encode(executor, forKey: .executor)
        try container.encode(requiresApproval, forKey: .requiresApproval)
        try container.encodeIfPresent(visualTarget, forKey: .visualTarget)

        switch parameters {
        case .openApplication:
            _ = container.nestedContainer(keyedBy: EmptyCodingKey.self, forKey: .parameters)
        case let .scroll(lines):
            var parametersContainer = container.nestedContainer(keyedBy: ScrollCodingKeys.self, forKey: .parameters)
            try parametersContainer.encode(lines, forKey: .lines)
        case let .insertText(text, replaceSelection):
            var parametersContainer = container.nestedContainer(keyedBy: InsertTextCodingKeys.self, forKey: .parameters)
            try parametersContainer.encode(text, forKey: .text)
            try parametersContainer.encode(replaceSelection, forKey: .replaceSelection)
        }
    }
}

public struct NativePlanResponse: Codable, Equatable, Sendable {
    public let planId: String
    public let status: String
    public let fingerprint: String
    public let actions: [NativePlanAction]
    public let capabilities: [String]

    public init(
        planId: String,
        status: String,
        fingerprint: String,
        actions: [NativePlanAction],
        capabilities: [String]
    ) {
        self.planId = planId
        self.status = status
        self.fingerprint = fingerprint
        self.actions = actions
        self.capabilities = capabilities
    }

    public var planID: String { planId }

    public static func decode(
        _ data: Data,
        using decoder: JSONDecoder = JSONDecoder()
    ) throws -> Self {
        do {
            return try decoder.decode(Self.self, from: data)
        } catch let error as NativePlanDecodingError {
            throw error
        } catch {
            throw NativePlanDecodingError.malformed(String(describing: error))
        }
    }

    public func executionContext(
        expiresAt: Date,
        cancellationGeneration: UInt64
    ) -> NativePlanExecutionContext {
        NativePlanExecutionContext(
            plan: self,
            expiresAt: expiresAt,
            cancellationGeneration: cancellationGeneration
        )
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case planId
        case status
        case fingerprint
        case actions
        case capabilities
    }

    public init(from decoder: Decoder) throws {
        let allFields = try decoder.container(keyedBy: NativePlanCodingKey.self)
        try rejectUnknownKeys(
            allFields.allKeys,
            allowed: CodingKeys.allCases.map(\.stringValue)
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let planId = try container.decode(String.self, forKey: .planId)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let status = try container.decode(String.self, forKey: .status)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fingerprint = try container.decode(String.self, forKey: .fingerprint)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !planId.isEmpty, !status.isEmpty, !fingerprint.isEmpty else {
            throw NativePlanDecodingError.malformed("planId, status, and fingerprint are required.")
        }
        let capabilities = try container.decode([String].self, forKey: .capabilities)
        guard capabilities.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw NativePlanDecodingError.malformed("capabilities cannot contain empty values.")
        }
        let actions = try container.decode([NativePlanAction].self, forKey: .actions)
        guard (1...12).contains(actions.count) else {
            throw NativePlanDecodingError.invalidParameters("actions must contain between 1 and 12 items.")
        }
        self.init(
            planId: planId,
            status: status,
            fingerprint: fingerprint,
            actions: actions,
            capabilities: capabilities
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(planId, forKey: .planId)
        try container.encode(status, forKey: .status)
        try container.encode(fingerprint, forKey: .fingerprint)
        try container.encode(actions, forKey: .actions)
        try container.encode(capabilities, forKey: .capabilities)
    }
}

public typealias NativePlan = NativePlanResponse

public struct NativePlanExecutionContext: Equatable, Sendable {
    public let plan: NativePlanResponse
    public let expiresAt: Date
    public let cancellationGeneration: UInt64

    public init(
        plan: NativePlanResponse,
        expiresAt: Date,
        cancellationGeneration: UInt64
    ) {
        self.plan = plan
        self.expiresAt = expiresAt
        self.cancellationGeneration = cancellationGeneration
    }
}

private struct NativePlanCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

private func rejectUnknownKeys<K: CodingKey>(_ keys: [K], allowed: [String]) throws {
    let allowedValues = Set(allowed)
    if let unknown = keys.first(where: { !allowedValues.contains($0.stringValue) }) {
        throw NativePlanDecodingError.unknownField(unknown.stringValue)
    }
}
