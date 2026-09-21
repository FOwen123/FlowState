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
    case focus
    case select
    case press
    case openURL
    case attachFile
    case sendEmail
    case draftMessage
    case insertText
}

public enum NativePlanRoute: String, Codable, Equatable, Sendable {
    case structuredIntegration
    case nativeAccessibility
    case visualComputerUse

    /// Source-compatible spelling for older native call sites. Canonical
    /// backend payloads use `visualComputerUse`.
    public static var freshVisual: Self { .visualComputerUse }
}

public enum NativePlanRisk: String, Codable, Equatable, Sendable {
    case reversible
    case confirm
    case unsupported

    /// Source-compatible aliases for the pre-canonical native vocabulary.
    public static var routine: Self { .reversible }
    public static var consequential: Self { .confirm }
}

public enum NativePlanParameters: Equatable, Sendable {
    case openApplication
    case scroll(lines: Int32)
    case focus(role: String, label: String?)
    case select(label: String)
    case press(key: String, modifiers: String?)
    case openURL(url: String)
    case attachFile(fileID: String)
    case sendEmail(recipient: String, subject: String, body: String)
    case draftMessage(recipient: String, subject: String, body: String)
    case insertText(text: String, replaceSelection: Bool)
}

public struct NativePlanPreconditions: Codable, Equatable, Sendable {
    public let targetBundleIdentifier: String?
    public let requiresFreshObservation: Bool

    public init(targetBundleIdentifier: String? = nil, requiresFreshObservation: Bool) {
        self.targetBundleIdentifier = targetBundleIdentifier
        self.requiresFreshObservation = requiresFreshObservation
    }
}

public enum NativePlanVerifierKind: String, Codable, Equatable, Sendable {
    case boundedAction
    case externalEffectReconciled
    case visualObservation
}

public struct NativePlanVerifier: Codable, Equatable, Sendable {
    public let kind: NativePlanVerifierKind

    public init(kind: NativePlanVerifierKind) {
        self.kind = kind
    }
}

public enum NativePlanReversalKind: String, Codable, Equatable, Sendable {
    case none
    case reconcile
    case undo
}

public struct NativePlanReversal: Codable, Equatable, Sendable {
    public let kind: NativePlanReversalKind
    public let supported: Bool

    public init(kind: NativePlanReversalKind, supported: Bool) {
        self.kind = kind
        self.supported = supported
    }
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
    public let targetID: String?
    public let targetBundleIdentifier: String?
    public let parameters: NativePlanParameters
    public let capability: String
    public let executor: String
    public let requiresApproval: Bool
    public let visualTarget: NativePlanJSONValue?
    public let route: NativePlanRoute
    public let preconditions: NativePlanPreconditions
    public let verifier: NativePlanVerifier
    public let riskClass: NativePlanRisk
    public let reversal: NativePlanReversal
    public let expiresAt: Date?

    public var risk: NativePlanRisk { riskClass }
    public var reversalSupported: Bool { reversal.supported }

    public init(
        kind: NativePlanActionKind,
        targetID: String? = nil,
        targetBundleIdentifier: String? = nil,
        parameters: NativePlanParameters,
        capability: String,
        executor: String = "desktop",
        requiresApproval: Bool,
        visualTarget: NativePlanJSONValue? = nil,
        route: NativePlanRoute = .nativeAccessibility,
        preconditions: NativePlanPreconditions? = nil,
        verifier: NativePlanVerifier? = nil,
        risk: NativePlanRisk? = nil,
        reversal: NativePlanReversal? = nil,
        reversalSupported: Bool? = nil,
        expiresAt: Date? = nil
    ) {
        self.kind = kind
        self.targetID = targetID
        self.targetBundleIdentifier = targetBundleIdentifier
        self.parameters = parameters
        self.capability = capability
        self.executor = executor
        self.requiresApproval = requiresApproval
        self.visualTarget = visualTarget
        self.route = route
        self.preconditions = preconditions ?? NativePlanPreconditions(
            targetBundleIdentifier: targetBundleIdentifier,
            requiresFreshObservation: route == .visualComputerUse
        )
        self.verifier = verifier ?? NativePlanVerifier(kind: route == .visualComputerUse ? .visualObservation : .boundedAction)
        self.riskClass = risk ?? (requiresApproval ? .confirm : .reversible)
        self.reversal = reversal ?? NativePlanReversal(
            kind: reversalSupported == true ? .undo : .none,
            supported: reversalSupported ?? false
        )
        self.expiresAt = expiresAt
    }

    public func isCurrent(at now: Date = Date()) -> Bool {
        expiresAt.map { $0 > now } ?? true
    }

    public var desktopAction: DesktopAction? {
        switch parameters {
        case .openApplication:
            targetBundleIdentifier.map(DesktopAction.openApplication(bundleIdentifier:))
        case let .scroll(lines):
            .some(.scroll(lines: lines))
        case let .focus(role, label):
            .some(.focus(role: role, label: label))
        case let .select(label):
            .some(.select(label: label))
        case let .press(key, modifiers):
            .some(.press(key: key, modifiers: modifiers))
        case .openURL, .attachFile, .sendEmail, .draftMessage, .insertText:
            nil
        }
    }

    public var summary: String {
        let app = targetBundleIdentifier ?? "the selected app"
        switch parameters {
        case .openApplication:
            return "Open \(app)"
        case let .scroll(lines):
            let direction = lines < 0 ? "down" : "up"
            return "Scroll \(direction) in \(app) (amount: \(abs(lines)))"
        case let .focus(role, label):
            return label.map { "Focus \($0) (\(role)) in \(app)" }
                ?? "Focus \(role) in \(app)"
        case let .select(label):
            return "Select \(label) in \(app)"
        case let .press(key, modifiers):
            return modifiers.map { "Press \($0)-\(key) in \(app)" }
                ?? "Press \(key) in \(app)"
        case let .openURL(url):
            return "Open URL \(url)"
        case let .attachFile(fileID):
            return "Attach approved file \(fileID)"
        case let .sendEmail(recipient, subject, _):
            return "Send email to \(recipient): \(subject)"
        case let .draftMessage(recipient, subject, _):
            return "Draft email to \(recipient): \(subject)"
        case let .insertText(text, _):
            return "Insert text into \(app): \(text)"
        }
    }

    public var description: String { summary }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case kind
        case targetId
        case targetBundleIdentifier
        case parameters
        case capability
        case executor
        case requiresApproval
        case visualTarget
        case route
        case preconditions
        case verifier
        case riskClass
        case reversal
        // Legacy native metadata is accepted only for source-compatible
        // construction; canonical payloads use riskClass and reversal.
        case risk
        case reversalSupported
        case expiresAt
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

    private enum FocusCodingKeys: String, CodingKey, CaseIterable {
        case role
        case label
    }

    private enum SelectCodingKeys: String, CodingKey, CaseIterable {
        case label
    }

    private enum PressCodingKeys: String, CodingKey, CaseIterable {
        case key
        case modifiers
    }

    private enum OpenURLCodingKeys: String, CodingKey, CaseIterable {
        case url
    }

    private enum AttachFileCodingKeys: String, CodingKey, CaseIterable {
        case fileId
    }

    private enum SendEmailCodingKeys: String, CodingKey, CaseIterable {
        case recipient
        case subject
        case body
    }

    private typealias DraftMessageCodingKeys = SendEmailCodingKeys

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
        guard kind != .insertText else {
            throw NativePlanDecodingError.unsupportedAction("insertText is available only through the Dictation shortcut.")
        }
        let targetID = try container.decodeIfPresent(String.self, forKey: .targetId)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let targetID, targetID.isEmpty {
            throw NativePlanDecodingError.invalidTarget
        }
        let target = try container.decodeIfPresent(String.self, forKey: .targetBundleIdentifier)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let target, target.isEmpty { throw NativePlanDecodingError.invalidTarget }

        let capability = try container.decode(String.self, forKey: .capability)
        let allowedCapabilities: Set<String> = switch kind {
        case .openApplication:
            ["app.control", "app.open"]
        case .scroll, .focus, .select:
            ["app.control"]
        case .press, .insertText:
            ["app.input"]
        case .openURL:
            ["app.control"]
        case .attachFile:
            ["file.upload"]
        case .sendEmail:
            ["mail.send"]
        case .draftMessage:
            ["mail.draft"]
        }
        guard allowedCapabilities.contains(capability) else {
            throw NativePlanDecodingError.unsupportedCapability(capability)
        }

        let executor = try container.decode(String.self, forKey: .executor)
        guard executor == "desktop" || executor == "service" else {
            throw NativePlanDecodingError.unsupportedExecutor(executor)
        }
        let expectedExecutor = switch kind {
        case .openURL, .attachFile, .sendEmail, .draftMessage: "service"
        default: "desktop"
        }
        guard executor == expectedExecutor else {
            throw NativePlanDecodingError.unsupportedExecutor(executor)
        }
        let requiresApproval = try container.decode(Bool.self, forKey: .requiresApproval)

        let visualTarget = try container.decodeIfPresent(NativePlanJSONValue.self, forKey: .visualTarget)

        let route: NativePlanRoute
        if let rawRoute = try container.decodeIfPresent(String.self, forKey: .route) {
            guard let decodedRoute = NativePlanRoute(rawValue: rawRoute) else {
                throw NativePlanDecodingError.malformed("Unknown plan route.")
            }
            route = decodedRoute
        } else {
            route = .nativeAccessibility
        }
        let preconditions = try container.decodeIfPresent(NativePlanPreconditions.self, forKey: .preconditions)
            ?? NativePlanPreconditions(targetBundleIdentifier: target, requiresFreshObservation: route == .visualComputerUse)
        if preconditions.targetBundleIdentifier != target {
            throw NativePlanDecodingError.invalidTarget
        }
        let verifier = try container.decodeIfPresent(NativePlanVerifier.self, forKey: .verifier)
            ?? NativePlanVerifier(kind: route == .visualComputerUse ? .visualObservation : .boundedAction)
        let risk: NativePlanRisk
        if let canonicalRisk = try container.decodeIfPresent(NativePlanRisk.self, forKey: .riskClass) {
            risk = canonicalRisk
        } else if let legacyRisk = try container.decodeIfPresent(NativePlanRisk.self, forKey: .risk) {
            risk = legacyRisk
        } else {
            risk = requiresApproval ? .confirm : .reversible
        }
        let reversal = try container.decodeIfPresent(NativePlanReversal.self, forKey: .reversal)
            ?? NativePlanReversal(kind: (try container.decodeIfPresent(Bool.self, forKey: .reversalSupported) ?? false) ? .undo : .none,
                                  supported: try container.decodeIfPresent(Bool.self, forKey: .reversalSupported) ?? false)
        let expiresAt = try container.decodeIfPresent(Date.self, forKey: .expiresAt)

        if kind == .openApplication && target == nil {
            throw NativePlanDecodingError.invalidTarget
        }
        if route == .structuredIntegration && executor != "service" {
            throw NativePlanDecodingError.unsupportedExecutor(executor)
        }
        if route == .structuredIntegration,
           ![NativePlanActionKind.openURL, .attachFile, .sendEmail, .draftMessage].contains(kind) {
            throw NativePlanDecodingError.unsupportedAction(kind.rawValue)
        }
        if route == .structuredIntegration,
           [NativePlanActionKind.openURL, .draftMessage].contains(kind),
           target == nil {
            throw NativePlanDecodingError.invalidTarget
        }
        if kind == .openURL, route == .structuredIntegration,
           requiresApproval || risk != .reversible {
            throw NativePlanDecodingError.invalidParameters(
                "openURL must be a reversible handoff without approval."
            )
        }
        if kind == .draftMessage, route == .structuredIntegration,
           !requiresApproval || risk != .confirm {
            throw NativePlanDecodingError.invalidParameters(
                "draftMessage requires confirmation."
            )
        }
        if route == .nativeAccessibility && executor != "desktop" {
            throw NativePlanDecodingError.unsupportedExecutor(executor)
        }
        if route == .nativeAccessibility && target == nil {
            throw NativePlanDecodingError.invalidTarget
        }
        if route == .visualComputerUse && visualTarget == nil {
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
        case .focus:
            let allParameters = try parametersDecoder.container(keyedBy: NativePlanCodingKey.self)
            try rejectUnknownKeys(
                allParameters.allKeys,
                allowed: FocusCodingKeys.allCases.map(\.stringValue)
            )
            let parametersContainer = try parametersDecoder.container(keyedBy: FocusCodingKeys.self)
            let role = try parametersContainer.decode(String.self, forKey: .role)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !role.isEmpty, role.count <= 100 else {
                throw NativePlanDecodingError.invalidParameters("focus role must be between 1 and 100 characters.")
            }
            let label = try parametersContainer.decodeIfPresent(String.self, forKey: .label)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard label == nil || !(label?.isEmpty ?? true) && (label?.count ?? 0) <= 300 else {
                throw NativePlanDecodingError.invalidParameters("focus label is invalid.")
            }
            parameters = .focus(role: role, label: label)
        case .select:
            let allParameters = try parametersDecoder.container(keyedBy: NativePlanCodingKey.self)
            try rejectUnknownKeys(
                allParameters.allKeys,
                allowed: SelectCodingKeys.allCases.map(\.stringValue)
            )
            let parametersContainer = try parametersDecoder.container(keyedBy: SelectCodingKeys.self)
            let label = try parametersContainer.decode(String.self, forKey: .label)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty, label.count <= 300 else {
                throw NativePlanDecodingError.invalidParameters("select label must be between 1 and 300 characters.")
            }
            parameters = .select(label: label)
        case .press:
            let allParameters = try parametersDecoder.container(keyedBy: NativePlanCodingKey.self)
            try rejectUnknownKeys(
                allParameters.allKeys,
                allowed: PressCodingKeys.allCases.map(\.stringValue)
            )
            let parametersContainer = try parametersDecoder.container(keyedBy: PressCodingKeys.self)
            let key = try parametersContainer.decode(String.self, forKey: .key)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard NativePlanAction.allowedPressKeys.contains(key) else {
                throw NativePlanDecodingError.invalidParameters("press key is not on the native allowlist.")
            }
            let modifiers = try parametersContainer.decodeIfPresent(String.self, forKey: .modifiers)
            if let modifiers, !NativePlanAction.allowedPressModifiers.contains(modifiers) {
                throw NativePlanDecodingError.invalidParameters("press modifiers are not on the native allowlist.")
            }
            parameters = .press(key: key, modifiers: modifiers)
        case .openURL:
            let allParameters = try parametersDecoder.container(keyedBy: NativePlanCodingKey.self)
            try rejectUnknownKeys(allParameters.allKeys, allowed: ["url"])
            let parametersContainer = try parametersDecoder.container(keyedBy: OpenURLCodingKeys.self)
            let url = try parametersContainer.decode(String.self, forKey: .url).trimmingCharacters(in: .whitespacesAndNewlines)
            guard url.count <= 2_000, let parsed = URL(string: url), parsed.scheme == "http" || parsed.scheme == "https" else {
                throw NativePlanDecodingError.invalidParameters("openURL requires an HTTP(S) URL.")
            }
            parameters = .openURL(url: parsed.absoluteString)
        case .attachFile:
            let allParameters = try parametersDecoder.container(keyedBy: NativePlanCodingKey.self)
            try rejectUnknownKeys(allParameters.allKeys, allowed: ["fileId"])
            let parametersContainer = try parametersDecoder.container(keyedBy: AttachFileCodingKeys.self)
            let fileID = try parametersContainer.decode(String.self, forKey: .fileId).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !fileID.isEmpty, fileID.count <= 200 else { throw NativePlanDecodingError.invalidParameters("fileId is invalid.") }
            parameters = .attachFile(fileID: fileID)
        case .sendEmail:
            let allParameters = try parametersDecoder.container(keyedBy: NativePlanCodingKey.self)
            try rejectUnknownKeys(allParameters.allKeys, allowed: ["recipient", "subject", "body"])
            let parametersContainer = try parametersDecoder.container(keyedBy: SendEmailCodingKeys.self)
            let recipient = try parametersContainer.decode(String.self, forKey: .recipient).trimmingCharacters(in: .whitespacesAndNewlines)
            let subject = try parametersContainer.decode(String.self, forKey: .subject).trimmingCharacters(in: .whitespacesAndNewlines)
            let body = try parametersContainer.decode(String.self, forKey: .body)
            guard !recipient.isEmpty, recipient.count <= 320, !subject.isEmpty, subject.count <= 998, body.count <= 100_000 else {
                throw NativePlanDecodingError.invalidParameters("sendEmail parameters are invalid.")
            }
            parameters = .sendEmail(recipient: recipient, subject: subject, body: body)
        case .draftMessage:
            let allParameters = try parametersDecoder.container(keyedBy: NativePlanCodingKey.self)
            try rejectUnknownKeys(allParameters.allKeys, allowed: ["recipient", "subject", "body"])
            let parametersContainer = try parametersDecoder.container(keyedBy: DraftMessageCodingKeys.self)
            let recipient = try parametersContainer.decode(String.self, forKey: .recipient).trimmingCharacters(in: .whitespacesAndNewlines)
            let subject = try parametersContainer.decode(String.self, forKey: .subject).trimmingCharacters(in: .whitespacesAndNewlines)
            let body = try parametersContainer.decode(String.self, forKey: .body)
            guard !recipient.isEmpty, recipient.count <= 320, !subject.isEmpty, subject.count <= 998, body.count <= 100_000 else {
                throw NativePlanDecodingError.invalidParameters("draftMessage parameters are invalid.")
            }
            parameters = .draftMessage(recipient: recipient, subject: subject, body: body)
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

        let expectedApproval: Bool = switch parameters {
        case .insertText: true
        case let .press(key, modifiers): key == "Enter" || modifiers != nil
        case .attachFile, .sendEmail: true
        case .openURL: false
        case .draftMessage: true
        default: false
        }
        guard !expectedApproval || requiresApproval else {
            throw NativePlanDecodingError.invalidParameters(
                "Approval is required for \(kind.rawValue)."
            )
        }

        self.init(
            kind: kind,
            targetID: targetID,
            targetBundleIdentifier: target,
            parameters: parameters,
            capability: capability,
            executor: executor,
            requiresApproval: requiresApproval,
            visualTarget: visualTarget,
            route: route,
            preconditions: preconditions,
            verifier: verifier,
            risk: risk,
            reversal: reversal,
            expiresAt: expiresAt
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind.rawValue, forKey: .kind)
        try container.encodeIfPresent(targetID, forKey: .targetId)
        try container.encode(targetBundleIdentifier, forKey: .targetBundleIdentifier)
        try container.encode(capability, forKey: .capability)
        try container.encode(executor, forKey: .executor)
        try container.encode(requiresApproval, forKey: .requiresApproval)
        try container.encodeIfPresent(visualTarget, forKey: .visualTarget)
        try container.encode(route.rawValue, forKey: .route)
        try container.encode(preconditions, forKey: .preconditions)
        try container.encode(verifier, forKey: .verifier)
        try container.encode(riskClass.rawValue, forKey: .riskClass)
        try container.encode(reversal, forKey: .reversal)
        try container.encodeIfPresent(expiresAt, forKey: .expiresAt)

        switch parameters {
        case .openApplication:
            _ = container.nestedContainer(keyedBy: EmptyCodingKey.self, forKey: .parameters)
        case let .scroll(lines):
            var parametersContainer = container.nestedContainer(keyedBy: ScrollCodingKeys.self, forKey: .parameters)
            try parametersContainer.encode(lines, forKey: .lines)
        case let .focus(role, label):
            var parametersContainer = container.nestedContainer(keyedBy: FocusCodingKeys.self, forKey: .parameters)
            try parametersContainer.encode(role, forKey: .role)
            try parametersContainer.encodeIfPresent(label, forKey: .label)
        case let .select(label):
            var parametersContainer = container.nestedContainer(keyedBy: SelectCodingKeys.self, forKey: .parameters)
            try parametersContainer.encode(label, forKey: .label)
        case let .press(key, modifiers):
            var parametersContainer = container.nestedContainer(keyedBy: PressCodingKeys.self, forKey: .parameters)
            try parametersContainer.encode(key, forKey: .key)
            try parametersContainer.encodeIfPresent(modifiers, forKey: .modifiers)
        case let .openURL(url):
            var parametersContainer = container.nestedContainer(keyedBy: OpenURLCodingKeys.self, forKey: .parameters)
            try parametersContainer.encode(url, forKey: .url)
        case let .attachFile(fileID):
            var parametersContainer = container.nestedContainer(keyedBy: AttachFileCodingKeys.self, forKey: .parameters)
            try parametersContainer.encode(fileID, forKey: .fileId)
        case let .sendEmail(recipient, subject, body):
            var parametersContainer = container.nestedContainer(keyedBy: SendEmailCodingKeys.self, forKey: .parameters)
            try parametersContainer.encode(recipient, forKey: .recipient)
            try parametersContainer.encode(subject, forKey: .subject)
            try parametersContainer.encode(body, forKey: .body)
        case let .draftMessage(recipient, subject, body):
            var parametersContainer = container.nestedContainer(keyedBy: DraftMessageCodingKeys.self, forKey: .parameters)
            try parametersContainer.encode(recipient, forKey: .recipient)
            try parametersContainer.encode(subject, forKey: .subject)
            try parametersContainer.encode(body, forKey: .body)
        case let .insertText(text, replaceSelection):
            var parametersContainer = container.nestedContainer(keyedBy: InsertTextCodingKeys.self, forKey: .parameters)
            try parametersContainer.encode(text, forKey: .text)
            try parametersContainer.encode(replaceSelection, forKey: .replaceSelection)
        }
    }

    public static let allowedPressKeys: Set<String> = [
        "ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight",
        "PageUp", "PageDown", "Home", "End", "Tab", "Escape", "Enter",
        "A", "C", "V"
    ]

    public static let allowedPressModifiers: Set<String> = ["Shift", "Command"]
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
