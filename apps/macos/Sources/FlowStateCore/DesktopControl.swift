import ApplicationServices
import AppKit
import CoreGraphics
import Foundation

public enum DesktopActionKind: String, CaseIterable, Codable, Sendable {
    case openApplication
    case scroll
    case focus
    case select
    case press
    case click
    case insertText

    /// Generic text insertion is retained as a decoding compatibility case,
    /// but it is no longer a control grant or an executable action.
    public static var allCases: [DesktopActionKind] {
        [.openApplication, .scroll, .focus, .select, .press, .click]
    }
}

public enum DesktopAction: Equatable, Codable, Sendable {
    case openApplication(bundleIdentifier: String)
    case scroll(lines: Int32)
    case focus(role: String?)
    case focusTarget(role: String?, label: String?)
    case select
    case selectTarget(label: String)
    case press
    case keyPress(key: String, modifiers: String?)
    case clickTarget(label: String)
    case insertText(String)

    public static func focus(role: String?, label: String?) -> Self {
        .focusTarget(role: role, label: label)
    }

    public static func select(label: String) -> Self {
        .selectTarget(label: label)
    }

    public static func press(key: String, modifiers: String?) -> Self {
        .keyPress(key: key, modifiers: modifiers)
    }

    public static func click(label: String) -> Self {
        .clickTarget(label: label)
    }

    var movesKeyboardFocus: Bool {
        if case .keyPress("Tab", _) = self { return true }
        if case .clickTarget = self { return true }
        return false
    }

    public var kind: DesktopActionKind {
        switch self {
        case .openApplication: .openApplication
        case .scroll: .scroll
        case .focus, .focusTarget: .focus
        case .select, .selectTarget: .select
        case .press, .keyPress: .press
        case .clickTarget: .click
        case .insertText: .insertText
        }
    }
}

public enum DesktopUndoSupport: String, Codable, Equatable, Sendable {
    case none
    case restoreText
}

public struct VisualComputerUseExecutor: Sendable {
    public init() {}

    @discardableResult
    public func click(
        target: NativePlanVisualTarget,
        in observation: CaptureObservation,
        authorize: @escaping @Sendable () async -> Bool
    ) async throws -> CGPoint {
        guard AXIsProcessTrusted() else { throw DesktopExecutionError.accessibilityDenied }
        let point = try target.screenPoint(in: observation)
        guard await authorize(),
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier == observation.bundleIdentifier,
              let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(
                mouseEventSource: source,
                mouseType: .leftMouseDown,
                mouseCursorPosition: point,
                mouseButton: .left
              ),
              let up = CGEvent(
                mouseEventSource: source,
                mouseType: .leftMouseUp,
                mouseCursorPosition: point,
                mouseButton: .left
              ) else {
            throw DesktopExecutionError.targetChanged
        }
        AXDesktopDriver.tagAutomationEvent(down)
        AXDesktopDriver.tagAutomationEvent(up)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return point
    }
}

public struct DesktopExecutionGrant: Codable, Equatable, Sendable {
    public let allowedBundleIdentifiers: Set<String>
    public let allowedActions: Set<DesktopActionKind>
    public let generation: UInt64
    public let expiresAt: Date

    public init(
        allowedBundleIdentifiers: Set<String>,
        allowedActions: Set<DesktopActionKind>,
        generation: UInt64,
        expiresAt: Date
    ) {
        self.allowedBundleIdentifiers = allowedBundleIdentifiers
        self.allowedActions = allowedActions
        self.generation = generation
        self.expiresAt = expiresAt
    }

    public func allows(_ action: DesktopAction, bundleIdentifier: String) -> Bool {
        guard expiresAt > Date(),
              allowedBundleIdentifiers.contains(bundleIdentifier),
              action.kind != .insertText,
              allowedActions.contains(action.kind) else { return false }
        if case let .openApplication(actionBundleIdentifier) = action {
            return actionBundleIdentifier == bundleIdentifier
        }
        return true
    }
}

public struct DesktopTextRange: Codable, Equatable, Sendable {
    public let location: Int
    public let length: Int

    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }
}

public struct DesktopObservation: Codable, Equatable, Sendable {
    public let bundleIdentifier: String
    public let focusedElementID: String?
    public let value: String?
    public let focusedRole: String?
    public let focusedLabel: String?
    public let isEditable: Bool
    public let isSecure: Bool
    public let selectedTextRange: DesktopTextRange?
    public let observedAt: Date

    public init(
        bundleIdentifier: String,
        focusedElementID: String? = nil,
        value: String? = nil,
        focusedRole: String? = nil,
        focusedLabel: String? = nil,
        isEditable: Bool = false,
        isSecure: Bool = false,
        selectedTextRange: DesktopTextRange? = nil,
        observedAt: Date = Date()
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.focusedElementID = focusedElementID
        self.value = value
        self.focusedRole = focusedRole
        self.focusedLabel = focusedLabel
        self.isEditable = isEditable
        self.isSecure = isSecure
        self.selectedTextRange = selectedTextRange
        self.observedAt = observedAt
    }

    private enum CodingKeys: String, CodingKey {
        case bundleIdentifier
        case focusedElementID
        case value
        case focusedRole
        case focusedLabel
        case isEditable
        case isSecure
        case selectedTextRange
        case observedAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            bundleIdentifier: try values.decode(String.self, forKey: .bundleIdentifier),
            focusedElementID: try values.decodeIfPresent(String.self, forKey: .focusedElementID),
            value: try values.decodeIfPresent(String.self, forKey: .value),
            focusedRole: try values.decodeIfPresent(String.self, forKey: .focusedRole),
            focusedLabel: try values.decodeIfPresent(String.self, forKey: .focusedLabel),
            isEditable: try values.decodeIfPresent(Bool.self, forKey: .isEditable) ?? false,
            isSecure: try values.decodeIfPresent(Bool.self, forKey: .isSecure) ?? false,
            selectedTextRange: try values.decodeIfPresent(DesktopTextRange.self, forKey: .selectedTextRange),
            observedAt: try values.decode(Date.self, forKey: .observedAt)
        )
    }

    /// Safe context for routing. It intentionally excludes the focused value,
    /// which may contain private document text and is only needed for local undo.
    public var safeContext: DesktopSafeContext {
        DesktopSafeContext(
            bundleIdentifier: bundleIdentifier,
            focusedElementID: focusedElementID,
            focusedRole: focusedRole,
            focusedLabel: focusedLabel,
            isEditable: isEditable,
            isSecure: isSecure,
            observedAt: observedAt
        )
    }
}

public struct DesktopSafeContext: Codable, Equatable, Sendable {
    public let bundleIdentifier: String
    public let focusedElementID: String?
    public let focusedRole: String?
    public let focusedLabel: String?
    public let isEditable: Bool
    public let isSecure: Bool
    public let observedAt: Date

    public init(
        bundleIdentifier: String,
        focusedElementID: String?,
        focusedRole: String?,
        focusedLabel: String?,
        isEditable: Bool,
        isSecure: Bool,
        observedAt: Date
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.focusedElementID = focusedElementID
        self.focusedRole = focusedRole
        self.focusedLabel = focusedLabel
        self.isEditable = isEditable
        self.isSecure = isSecure
        self.observedAt = observedAt
    }
}

public struct DesktopActionResult: Equatable, Sendable {
    public let verified: Bool
    /// True once the native effect was attempted. A false result with this flag
    /// means the final result is unknown and must never be replayed automatically.
    public let effectAttempted: Bool
    public let valueBefore: String?
    public let valueAfter: String?

    public init(
        verified: Bool,
        effectAttempted: Bool = false,
        valueBefore: String? = nil,
        valueAfter: String? = nil
    ) {
        self.verified = verified
        self.effectAttempted = effectAttempted
        self.valueBefore = valueBefore
        self.valueAfter = valueAfter
    }
}

public struct VerifiedDesktopAction: Codable, Equatable, Sendable {
    public let operationID: UUID
    public let action: DesktopAction
    public let targetBundleIdentifier: String
    public let focusedElementID: String?
    public let valueBefore: String?
    public let valueAfter: String?
    public let undoSupport: DesktopUndoSupport
    public let generation: UInt64

    public init(
        operationID: UUID = UUID(),
        action: DesktopAction,
        targetBundleIdentifier: String,
        focusedElementID: String?,
        valueBefore: String?,
        valueAfter: String?,
        undoSupport: DesktopUndoSupport,
        generation: UInt64
    ) {
        self.operationID = operationID
        self.action = action
        self.targetBundleIdentifier = targetBundleIdentifier
        self.focusedElementID = focusedElementID
        self.valueBefore = valueBefore
        self.valueAfter = valueAfter
        self.undoSupport = undoSupport
        self.generation = generation
    }
}

public enum DesktopAutomationState: String, Codable, Equatable, Sendable {
    case idle
    case ready
    case running
    case pausedForUser
    case reconciliationRequired
    case cancelled
}

public enum DesktopExecutionError: Error, Equatable, LocalizedError, Sendable {
    case notStarted
    case staleGeneration
    case grantExpired
    case actionNotGranted
    case targetChanged
    case verificationFailed
    case dispatchUncertain
    case reconciliationRequired
    case pausedForTakeover
    case interveningEdit
    case undoUnsupported
    case accessibilityDenied
    case applicationNotFound(String)
    case nativeFailure(String)

    public var errorDescription: String? {
        switch self {
        case .notStarted: "Desktop control is not active for this task."
        case .staleGeneration: "This action belongs to an obsolete execution generation."
        case .grantExpired: "The desktop-control grant has expired."
        case .actionNotGranted: "This action is not granted for the current task."
        case .targetChanged: "The focused application changed before the action ran."
        case .verificationFailed: "The action was not verified before its effect boundary."
        case .dispatchUncertain: "The action may have run; check its effect before continuing."
        case .reconciliationRequired: "Check the last action before continuing or granting desktop control again."
        case .pausedForTakeover: "Desktop control is paused while you use the Mac."
        case .interveningEdit: "The focused value changed, so undo was not performed."
        case .undoUnsupported: "This action has no safe verified undo."
        case .accessibilityDenied: "Accessibility permission is required for desktop control."
        case let .applicationNotFound(bundle): "Could not find application \(bundle)."
        case let .nativeFailure(message): message
        }
    }
}

public protocol DesktopDriver: Sendable {
    func observe() async throws -> DesktopObservation
    /// Drivers must return `effectAttempted: true` for an unverified result
    /// after crossing the native effect boundary, and throw
    /// `DesktopExecutionError.dispatchUncertain` if they fail after dispatch.
    func perform(
        _ action: DesktopAction,
        expectedObservation: DesktopObservation,
        authorize: @escaping @Sendable () async -> Bool
    ) async throws -> DesktopActionResult
    func restoreValue(
        _ value: String,
        expectedObservation: DesktopObservation,
        authorize: @escaping @Sendable () async -> Bool
    ) async throws
}

/// Serializes desktop effects and rejects late work after local cancellation.
/// Physical user input is observed by the app, but does not revoke a task;
/// every subsequent effect re-observes its target and preconditions.
public actor DesktopAutomationController {
    private let driver: any DesktopDriver
    private var grant: DesktopExecutionGrant?
    private var stateValue: DesktopAutomationState = .idle
    private var generation: UInt64 = 0
    private var latestLifecycleEpoch: UInt64 = 0
    private struct OperationToken: Equatable, Sendable {
        let id: UUID
        let generation: UInt64
    }
    private var activeOperation: OperationToken?

    public init(driver: any DesktopDriver = AXDesktopDriver()) {
        self.driver = driver
    }

    public var state: DesktopAutomationState { stateValue }

    private func acceptLifecycleEpoch(_ epoch: UInt64?) -> Bool {
        guard let epoch else { return true }
        guard epoch >= latestLifecycleEpoch else { return false }
        latestLifecycleEpoch = epoch
        return true
    }

    public func begin(grant: DesktopExecutionGrant, lifecycleEpoch: UInt64? = nil) throws {
        guard acceptLifecycleEpoch(lifecycleEpoch) else { throw DesktopExecutionError.staleGeneration }
        guard grant.expiresAt > Date() else { throw DesktopExecutionError.grantExpired }
        self.grant = grant
        generation = grant.generation
        activeOperation = nil
        stateValue = .ready
    }

    /// Captures the current app and focused control for a bounded routing
    /// request. The caller must pass this same snapshot to `execute` after any
    /// cloud inference so a changed focus cannot receive the result.
    public func observeCurrent() async throws -> DesktopObservation {
        guard stateValue == .ready else {
            if stateValue == .pausedForUser { throw DesktopExecutionError.pausedForTakeover }
            if stateValue == .reconciliationRequired { throw DesktopExecutionError.reconciliationRequired }
            if stateValue == .cancelled { throw DesktopExecutionError.staleGeneration }
            throw DesktopExecutionError.notStarted
        }
        guard let grant, grant.generation == generation else {
            throw DesktopExecutionError.staleGeneration
        }
        guard grant.expiresAt > Date() else { throw DesktopExecutionError.grantExpired }
        let observation = try await driver.observe()
        guard stateValue == .ready,
              self.grant?.generation == generation,
              grant.expiresAt > Date() else {
            throw DesktopExecutionError.staleGeneration
        }
        return observation
    }

    public func cancel(lifecycleEpoch: UInt64? = nil) {
        guard acceptLifecycleEpoch(lifecycleEpoch) else { return }
        generation &+= 1
        activeOperation = nil
        grant = nil
        stateValue = .cancelled
    }

    public func notePhysicalTakeover(lifecycleEpoch: UInt64? = nil) {
        guard acceptLifecycleEpoch(lifecycleEpoch) else { return }
        // Unrelated user input is not an authoritative cancellation signal.
        // Keep the grant and operation generation intact so the next action
        // can reobserve and either continue or fail closed on target drift.
    }

    @discardableResult
    public func resume() async throws -> DesktopObservation {
        guard stateValue == .pausedForUser else {
            if stateValue == .reconciliationRequired { throw DesktopExecutionError.reconciliationRequired }
            throw DesktopExecutionError.notStarted
        }
        guard activeOperation == nil else { throw DesktopExecutionError.staleGeneration }
        guard let grant, grant.expiresAt > Date() else {
            throw DesktopExecutionError.grantExpired
        }
        let token = OperationToken(id: UUID(), generation: generation)
        activeOperation = token
        let observation: DesktopObservation
        do {
            observation = try await driver.observe()
        } catch {
            if activeOperation == token {
                activeOperation = nil
            }
            throw error
        }
        guard isCurrentResume(token, grant: grant),
              self.grant?.generation == grant.generation,
              grant.expiresAt > Date()
        else {
            if activeOperation == token {
                activeOperation = nil
            }
            throw DesktopExecutionError.staleGeneration
        }
        let resumedGeneration = max(generation, grant.generation) &+ 1
        self.grant = DesktopExecutionGrant(
            allowedBundleIdentifiers: grant.allowedBundleIdentifiers,
            allowedActions: grant.allowedActions,
            generation: resumedGeneration,
            expiresAt: grant.expiresAt
        )
        generation = resumedGeneration
        activeOperation = nil
        stateValue = .ready
        return observation
    }

    public func execute(
        _ action: DesktopAction,
        expectedBundleIdentifier: String,
        expectedObservation: DesktopObservation? = nil
    ) async throws -> VerifiedDesktopAction {
        guard action.kind != .insertText else {
            throw DesktopExecutionError.actionNotGranted
        }
        guard stateValue == .ready else {
            if stateValue == .pausedForUser { throw DesktopExecutionError.pausedForTakeover }
            if stateValue == .reconciliationRequired { throw DesktopExecutionError.reconciliationRequired }
            if stateValue == .cancelled { throw DesktopExecutionError.staleGeneration }
            throw DesktopExecutionError.notStarted
        }
        guard activeOperation == nil else { throw DesktopExecutionError.staleGeneration }
        guard let grant else { throw DesktopExecutionError.notStarted }
        guard grant.generation == generation else { throw DesktopExecutionError.staleGeneration }
        guard grant.expiresAt > Date() else { throw DesktopExecutionError.grantExpired }
        guard grant.allows(action, bundleIdentifier: expectedBundleIdentifier) else {
            throw DesktopExecutionError.actionNotGranted
        }

        let token = OperationToken(id: UUID(), generation: generation)
        activeOperation = token
        stateValue = .running
        var effectAttempted = false
        do {
            let before = try await driver.observe()
            guard isCurrent(token, state: .running), grant.expiresAt > Date() else {
                throw DesktopExecutionError.staleGeneration
            }
            if let expectedObservation {
                guard sameObservationContext(before, expectedObservation) else {
                    throw DesktopExecutionError.targetChanged
                }
            }
            guard action.kind == .openApplication || before.bundleIdentifier == expectedBundleIdentifier else {
                throw DesktopExecutionError.targetChanged
            }

            let authorization: @Sendable () async -> Bool = { [self] in
                await isCurrent(token, state: .running)
            }
            let result = try await driver.perform(
                action,
                expectedObservation: before,
                authorize: authorization
            )
            effectAttempted = result.effectAttempted || result.verified
            guard result.verified else {
                if result.effectAttempted {
                    throw DesktopExecutionError.dispatchUncertain
                }
                guard isCurrent(token, state: .running) else {
                    throw DesktopExecutionError.staleGeneration
                }
                throw DesktopExecutionError.verificationFailed
            }
            guard isCurrent(token, state: .running) else {
                throw DesktopExecutionError.staleGeneration
            }
            let after = try await driver.observe()
            guard isCurrent(token, state: .running) else {
                throw DesktopExecutionError.staleGeneration
            }
            guard after.bundleIdentifier == expectedBundleIdentifier,
                  action.kind == .openApplication || action.kind == .scroll || action.movesKeyboardFocus ||
                    sameElementIdentity(after.focusedElementID, before.focusedElementID) else {
                throw DesktopExecutionError.targetChanged
            }
            activeOperation = nil
            stateValue = .ready
            return VerifiedDesktopAction(
                action: action,
                targetBundleIdentifier: expectedBundleIdentifier,
                focusedElementID: before.focusedElementID,
                valueBefore: result.valueBefore ?? before.value,
                valueAfter: result.valueAfter ?? after.value,
                undoSupport: action.kind == .insertText &&
                    (result.valueBefore ?? before.value) != nil &&
                    (result.valueAfter ?? after.value) != nil
                    ? .restoreText : .none,
                generation: token.generation
            )
        } catch {
            if activeOperation == token {
                activeOperation = nil
                stateValue = effectAttempted || (error as? DesktopExecutionError) == .dispatchUncertain
                    ? .reconciliationRequired : .ready
            }
            throw error
        }
    }

    public func executeVisualClick(
        target: NativePlanVisualTarget,
        capture: CaptureObservation,
        expectedBundleIdentifier: String,
        revalidate: @escaping @Sendable () async throws -> Void,
        verify: @escaping @Sendable () async throws -> Bool
    ) async throws -> VerifiedDesktopAction {
        guard stateValue == .ready else {
            if stateValue == .pausedForUser { throw DesktopExecutionError.pausedForTakeover }
            if stateValue == .reconciliationRequired { throw DesktopExecutionError.reconciliationRequired }
            throw DesktopExecutionError.notStarted
        }
        guard activeOperation == nil, let grant,
              grant.generation == generation, grant.expiresAt > Date(),
              grant.allows(.click(label: "visual target"), bundleIdentifier: expectedBundleIdentifier),
              capture.bundleIdentifier == expectedBundleIdentifier else {
            throw DesktopExecutionError.actionNotGranted
        }

        let token = OperationToken(id: UUID(), generation: generation)
        activeOperation = token
        stateValue = .running
        var effectAttempted = false
        do {
            let before = try await driver.observe()
            guard before.bundleIdentifier == expectedBundleIdentifier,
                  isCurrent(token, state: .running) else {
                throw DesktopExecutionError.targetChanged
            }
            let authorization: @Sendable () async -> Bool = { [self] in
                guard await isCurrent(token, state: .running) else { return false }
                do {
                    try await revalidate()
                    return await isCurrent(token, state: .running)
                } catch {
                    return false
                }
            }
            _ = try await VisualComputerUseExecutor().click(
                target: target,
                in: capture,
                authorize: authorization
            )
            effectAttempted = true
            guard isCurrent(token, state: .running), try await verify() else {
                throw DesktopExecutionError.dispatchUncertain
            }
            let after = try await driver.observe()
            guard isCurrent(token, state: .running),
                  after.bundleIdentifier == expectedBundleIdentifier else {
                throw DesktopExecutionError.dispatchUncertain
            }
            activeOperation = nil
            stateValue = .ready
            return VerifiedDesktopAction(
                action: .click(label: "visual target"),
                targetBundleIdentifier: expectedBundleIdentifier,
                focusedElementID: before.focusedElementID,
                valueBefore: before.value,
                valueAfter: after.value,
                undoSupport: .none,
                generation: token.generation
            )
        } catch {
            if activeOperation == token {
                activeOperation = nil
                stateValue = effectAttempted ? .reconciliationRequired : .ready
            }
            throw error
        }
    }

    public func undo(_ record: VerifiedDesktopAction) async throws {
        guard record.undoSupport == .restoreText else {
            throw DesktopExecutionError.undoUnsupported
        }
        guard record.action.kind == .insertText,
              record.focusedElementID != nil,
              record.valueBefore != nil,
              record.valueAfter != nil
        else { throw DesktopExecutionError.undoUnsupported }
        guard stateValue == .ready else {
            if stateValue == .reconciliationRequired { throw DesktopExecutionError.reconciliationRequired }
            throw DesktopExecutionError.notStarted
        }
        guard activeOperation == nil else { throw DesktopExecutionError.staleGeneration }
        guard let grant, grant.generation == generation, grant.expiresAt > Date() else {
            throw DesktopExecutionError.staleGeneration
        }
        guard let valueBefore = record.valueBefore else {
            throw DesktopExecutionError.undoUnsupported
        }
        guard grant.allows(record.action, bundleIdentifier: record.targetBundleIdentifier) else {
            throw DesktopExecutionError.actionNotGranted
        }
        guard record.generation == generation else {
            throw DesktopExecutionError.staleGeneration
        }

        let token = OperationToken(id: UUID(), generation: generation)
        activeOperation = token
        stateValue = .running
        do {
            let observation = try await driver.observe()
            guard isCurrent(token, state: .running) else {
                throw DesktopExecutionError.staleGeneration
            }
            guard observation.bundleIdentifier == record.targetBundleIdentifier,
                  observation.focusedElementID == record.focusedElementID,
                  observation.value == record.valueAfter
            else { throw DesktopExecutionError.interveningEdit }

            let authorization: @Sendable () async -> Bool = { [self] in
                await isCurrent(token, state: .running)
            }
            try await driver.restoreValue(
                valueBefore,
                expectedObservation: observation,
                authorize: authorization
            )
            guard isCurrent(token, state: .running) else {
                throw DesktopExecutionError.staleGeneration
            }
            activeOperation = nil
            stateValue = .ready
        } catch {
            if activeOperation == token {
                activeOperation = nil
                stateValue = .ready
            }
            throw error
        }
    }

    private func isCurrent(_ token: OperationToken, state: DesktopAutomationState) -> Bool {
        guard let grant else { return false }
        return activeOperation == token &&
            generation == token.generation &&
            stateValue == state &&
            grant.generation == token.generation &&
            grant.expiresAt > Date()
    }

    private func isCurrentResume(_ token: OperationToken, grant: DesktopExecutionGrant) -> Bool {
        activeOperation == token &&
            generation == token.generation &&
            stateValue == .pausedForUser &&
            self.grant?.generation == grant.generation &&
            grant.expiresAt > Date()
    }
}

/// Native Accessibility and input driver. It only runs when the caller has
/// already granted the action and requested execution for the current target.
public final class AXDesktopDriver: @unchecked Sendable, DesktopDriver {
    private static let maxRetainedElements = 256
    private let identityLock = NSLock()
    private var retainedElements: [String: AXUIElement] = [:]
    private var retainedElementOrder: [String] = []

    public init() {}

    static func isSecureTextField(role: String?, subrole: String?) -> Bool {
        role == "AXSecureTextField" || subrole == "AXSecureTextField"
    }

    static func canReadValue(role: String?, subrole: String?) -> Bool {
        guard role != nil else { return false }
        guard role != "AXSecureTextField" else { return false }
        return !isSecureTextField(role: role, subrole: subrole)
    }

    static func isPressableControlEnabled(_ enabled: Bool?) -> Bool {
        enabled != false
    }

    public func observe() async throws -> DesktopObservation {
        guard AXIsProcessTrusted() else { throw DesktopExecutionError.accessibilityDenied }
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleIdentifier = app.bundleIdentifier
        else { throw DesktopExecutionError.nativeFailure("No frontmost application is available.") }

        let system = AXUIElementCreateSystemWide()
        let focused = copyAttribute(system, kAXFocusedUIElementAttribute as CFString)
        let focusedElement = focused.map { $0 as! AXUIElement }
        let role = focusedElement.flatMap { copyAttribute($0, kAXRoleAttribute as CFString) as? String }
        let subrole = focusedElement.flatMap { copyAttribute($0, kAXSubroleAttribute as CFString) as? String }
        let label = focusedElement.flatMap { self.accessibleLabel($0) }
        let isEditable = focusedElement.map(Self.isEditable) ?? false
        let isSecure = Self.isSecureTextField(role: role, subrole: subrole)
        let selection = focusedElement.flatMap { selectedTextRange(for: $0) }
        let value: String?
        if Self.canReadValue(role: role, subrole: subrole), !isSecure {
            value = focusedElement.flatMap { copyAttribute($0, kAXValueAttribute as CFString) as? String }
        } else {
            value = nil
        }
        let elementID = focusedElement.map(retainedElementIdentifier)
        return DesktopObservation(
            bundleIdentifier: bundleIdentifier,
            focusedElementID: elementID,
            value: value,
            focusedRole: role,
            focusedLabel: label,
            isEditable: isEditable,
            isSecure: isSecure,
            selectedTextRange: selection.map { DesktopTextRange(location: $0.location, length: $0.length) }
        )
    }

    public func perform(
        _ action: DesktopAction,
        expectedObservation: DesktopObservation,
        authorize: @escaping @Sendable () async -> Bool
    ) async throws -> DesktopActionResult {
        if action.kind != .openApplication {
            let current = try await observe()
            guard current.bundleIdentifier == expectedObservation.bundleIdentifier,
                  sameElementIdentity(current.focusedElementID, expectedObservation.focusedElementID),
                  current.selectedTextRange == expectedObservation.selectedTextRange
            else { throw DesktopExecutionError.targetChanged }
        }
        switch action {
        case let .openApplication(bundleIdentifier):
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
                throw DesktopExecutionError.applicationNotFound(bundleIdentifier)
            }
            guard await authorize() else { throw DesktopExecutionError.staleGeneration }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            let application = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NSRunningApplication, Error>) in
                NSWorkspace.shared.openApplication(at: url, configuration: configuration) { application, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let application { continuation.resume(returning: application) }
                    else { continuation.resume(throwing: DesktopExecutionError.applicationNotFound(bundleIdentifier)) }
                }
            }
            // Opening is asynchronous. A cancelled launch must never activate late.
            guard await authorize() else { throw DesktopExecutionError.staleGeneration }
            _ = application.activate(options: [.activateAllWindows])
            let appElement = AXUIElementCreateApplication(application.processIdentifier)
            _ = AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            for _ in 0..<10 {
                guard await authorize() else { throw DesktopExecutionError.staleGeneration }
                if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleIdentifier {
                    return DesktopActionResult(verified: true)
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            return DesktopActionResult(verified: false, effectAttempted: true)
        case let .scroll(lines):
            guard (-100...100).contains(lines) else { throw DesktopExecutionError.actionNotGranted }
            guard await authorize() else { throw DesktopExecutionError.staleGeneration }
            guard let target = NSWorkspace.shared.frontmostApplication,
                  target.bundleIdentifier == expectedObservation.bundleIdentifier else { throw DesktopExecutionError.targetChanged }
            let applicationElement = AXUIElementCreateApplication(target.processIdentifier)
            guard let windowValue = copyAttribute(applicationElement, kAXFocusedWindowAttribute as CFString),
                  CFGetTypeID(windowValue) == AXUIElementGetTypeID() else {
                throw DesktopExecutionError.nativeFailure("This window does not expose an unambiguous accessible vertical scrollbar.")
            }
            let window = windowValue as! AXUIElement
            guard sameElementIdentity((try? focusedElement()).map(retainedElementIdentifier), expectedObservation.focusedElementID) else {
                throw DesktopExecutionError.targetChanged
            }
            if let scrollbar = verticalScrollbar(in: window) {
                guard let before = copyAttribute(scrollbar, kAXValueAttribute as CFString) as? NSNumber,
                      (0...1).contains(before.doubleValue) else {
                    throw DesktopExecutionError.nativeFailure("This window does not expose an unambiguous accessible vertical scrollbar.")
                }
                var settable: DarwinBoolean = false
                guard AXUIElementIsAttributeSettable(scrollbar, kAXValueAttribute as CFString, &settable) == .success, settable.boolValue else {
                    throw DesktopExecutionError.nativeFailure("This app does not allow accessible scrolling.")
                }
                // ponytail: normalized increments where the app omits its scroll increment;
                // visual scrolling needs a separate verified target, never a global wheel event.
                let increment = (copyAttribute(scrollbar, kAXValueIncrementAttribute as CFString) as? NSNumber)?.doubleValue ?? 0.01
                guard increment.isFinite, increment > 0, increment <= 1 else { throw DesktopExecutionError.verificationFailed }
                let desired = min(1, max(0, before.doubleValue - Double(lines) * increment))
                if desired == before.doubleValue { return DesktopActionResult(verified:true) }
                guard await authorize() else { throw DesktopExecutionError.staleGeneration }
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier,
                      let currentWindow = copyAttribute(applicationElement, kAXFocusedWindowAttribute as CFString),
                      CFEqual(currentWindow, windowValue),
                      let scrollWindow = copyAttribute(scrollbar, kAXWindowAttribute as CFString),
                      CFEqual(scrollWindow, windowValue),
                      sameElementIdentity((try? focusedElement()).map(retainedElementIdentifier), expectedObservation.focusedElementID) else {
                    throw DesktopExecutionError.targetChanged
                }
                guard AXUIElementSetAttributeValue(scrollbar, kAXValueAttribute as CFString, NSNumber(value:desired)) == .success else {
                    return DesktopActionResult(verified:false)
                }
                for _ in 0..<10 {
                    guard await authorize() else { throw DesktopExecutionError.staleGeneration }
                    if let after = copyAttribute(scrollbar, kAXValueAttribute as CFString) as? NSNumber,
                       (lines < 0 && after.doubleValue > before.doubleValue) || (lines > 0 && after.doubleValue < before.doubleValue) {
                        return DesktopActionResult(verified:true)
                    }
                    try await Task.sleep(for:.milliseconds(50))
                }
                return DesktopActionResult(verified:false, effectAttempted: true)
            }
            return try await scrollWebContent(in: window, lines: lines, expectedFocus: expectedObservation.focusedElementID, authorize: authorize)
        case .focus, .focusTarget, .select, .selectTarget, .press, .keyPress, .clickTarget, .insertText:
            guard action.kind != .insertText else { throw DesktopExecutionError.actionNotGranted }
            guard AXIsProcessTrusted() else { throw DesktopExecutionError.accessibilityDenied }
            let focused = try focusedElement(matching: expectedObservation)
            switch action {
            case let .focus(role):
                if let role, let actual = copyAttribute(focused, kAXRoleAttribute as CFString) as? String, role != actual {
                    return DesktopActionResult(verified: false)
                }
                guard await authorize() else { throw DesktopExecutionError.staleGeneration }
                let effectFocused = try focusedElement(matching: expectedObservation)
                let effectRole = copyAttribute(effectFocused, kAXRoleAttribute as CFString) as? String
                let effectSubrole = copyAttribute(effectFocused, kAXSubroleAttribute as CFString) as? String
                guard !Self.isSecureTextField(role: effectRole, subrole: effectSubrole),
                      role == nil || role == effectRole else {
                    return DesktopActionResult(verified: false)
                }
            case let .focusTarget(role, label):
                let actualRole = copyAttribute(focused, kAXRoleAttribute as CFString) as? String
                let actualLabel = accessibleLabel(focused)
                let actualSubrole = copyAttribute(focused, kAXSubroleAttribute as CFString) as? String
                guard (role == nil || role == actualRole),
                      label == nil || label == actualLabel,
                      !Self.isSecureTextField(role: actualRole, subrole: actualSubrole) else {
                    return DesktopActionResult(verified: false)
                }
                guard await authorize() else { throw DesktopExecutionError.staleGeneration }
                let effectFocused = try focusedElement(matching: expectedObservation)
                let effectRole = copyAttribute(effectFocused, kAXRoleAttribute as CFString) as? String
                let effectSubrole = copyAttribute(effectFocused, kAXSubroleAttribute as CFString) as? String
                let effectLabel = accessibleLabel(effectFocused)
                guard (role == nil || role == effectRole),
                      label == nil || label == effectLabel,
                      !Self.isSecureTextField(role: effectRole, subrole: effectSubrole) else {
                    return DesktopActionResult(verified: false)
                }
                guard AXUIElementSetAttributeValue(effectFocused, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success else {
                    return DesktopActionResult(verified: false)
                }
                guard let focusedAfter = try? focusedElement(matching: expectedObservation),
                      sameElementIdentity(retainedElementIdentifier(focusedAfter), expectedObservation.focusedElementID) else {
                    return DesktopActionResult(verified: false, effectAttempted: true)
                }
            case .select:
                guard await authorize() else { throw DesktopExecutionError.staleGeneration }
                let effectFocused = try focusedElement(matching: expectedObservation)
                let effectRole = copyAttribute(effectFocused, kAXRoleAttribute as CFString) as? String
                let effectSubrole = copyAttribute(effectFocused, kAXSubroleAttribute as CFString) as? String
                guard !Self.isSecureTextField(role: effectRole, subrole: effectSubrole) else {
                    return DesktopActionResult(verified: false)
                }
                guard AXUIElementSetAttributeValue(effectFocused, kAXSelectedAttribute as CFString, kCFBooleanTrue) == .success else {
                    return DesktopActionResult(verified: false)
                }
                guard (copyAttribute(effectFocused, kAXSelectedAttribute as CFString) as? NSNumber)?.boolValue == true else {
                    return DesktopActionResult(verified: false, effectAttempted: true)
                }
            case let .selectTarget(label):
                guard accessibleLabel(focused) == label else {
                    return DesktopActionResult(verified: false)
                }
                guard await authorize() else { throw DesktopExecutionError.staleGeneration }
                let effectFocused = try focusedElement(matching: expectedObservation)
                let effectRole = copyAttribute(effectFocused, kAXRoleAttribute as CFString) as? String
                let effectSubrole = copyAttribute(effectFocused, kAXSubroleAttribute as CFString) as? String
                guard accessibleLabel(effectFocused) == label,
                      !Self.isSecureTextField(role: effectRole, subrole: effectSubrole) else {
                    return DesktopActionResult(verified: false)
                }
                guard AXUIElementSetAttributeValue(effectFocused, kAXSelectedAttribute as CFString, kCFBooleanTrue) == .success else {
                    return DesktopActionResult(verified: false)
                }
                guard (copyAttribute(effectFocused, kAXSelectedAttribute as CFString) as? NSNumber)?.boolValue == true else {
                    return DesktopActionResult(verified: false, effectAttempted: true)
                }
            case .press:
                guard await authorize() else { throw DesktopExecutionError.staleGeneration }
                let effectFocused = try focusedElement(matching: expectedObservation)
                guard AXUIElementPerformAction(effectFocused, kAXPressAction as CFString) == .success else {
                    return DesktopActionResult(verified: false)
                }
            case let .keyPress(key, modifiers):
                guard Self.allowedPressKeys.contains(key),
                      modifiers == nil || Self.allowedPressModifiers.contains(modifiers ?? "") else {
                    throw DesktopExecutionError.actionNotGranted
                }
                guard await authorize(), let keyCode = Self.keyCode(for: key) else {
                    throw DesktopExecutionError.staleGeneration
                }
                let current = try await observe()
                guard sameObservationContext(current, expectedObservation) else {
                    throw DesktopExecutionError.targetChanged
                }
                guard await authorize() else { throw DesktopExecutionError.staleGeneration }
                let source = CGEventSource(stateID: .combinedSessionState)
                guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
                      let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
                    throw DesktopExecutionError.nativeFailure("Could not create a keyboard event.")
                }
                Self.tagAutomationEvent(keyDown)
                Self.tagAutomationEvent(keyUp)
                keyDown.flags = []
                keyUp.flags = []
                if modifiers == "Shift" { keyDown.flags.insert(.maskShift); keyUp.flags.insert(.maskShift) }
                if modifiers == "Command" { keyDown.flags.insert(.maskCommand); keyUp.flags.insert(.maskCommand) }
                let clipboardBefore = await MainActor.run { NSPasteboard.general.changeCount }
                guard await authorize(),
                      let target = NSWorkspace.shared.frontmostApplication,
                      target.bundleIdentifier == expectedObservation.bundleIdentifier,
                      let postingFocused = try? focusedElement(matching: expectedObservation),
                      !Self.isSecureTextField(
                        role: copyAttribute(postingFocused, kAXRoleAttribute as CFString) as? String,
                        subrole: copyAttribute(postingFocused, kAXSubroleAttribute as CFString) as? String
                      )
                else { throw DesktopExecutionError.targetChanged }
                keyDown.postToPid(target.processIdentifier)
                keyUp.postToPid(target.processIdentifier)
                do {
                    for _ in 0..<10 {
                        try await Task.sleep(for: .milliseconds(30))
                        guard await authorize() else { throw DesktopExecutionError.dispatchUncertain }
                        let after = try await observe()
                        guard after.bundleIdentifier == current.bundleIdentifier else {
                            throw DesktopExecutionError.dispatchUncertain
                        }
                        let clipboardAfter = await MainActor.run { NSPasteboard.general.changeCount }
                        if keyboardEffectObserved(key: key, modifiers: modifiers, before: current, after: after,
                                                  clipboardChanged: clipboardAfter != clipboardBefore) {
                            return DesktopActionResult(verified: true, effectAttempted: true)
                        }
                    }
                } catch {
                    throw DesktopExecutionError.dispatchUncertain
                }
                return DesktopActionResult(verified: false, effectAttempted: true)
            case let .clickTarget(label):
                guard let target = NSWorkspace.shared.frontmostApplication,
                      target.bundleIdentifier == expectedObservation.bundleIdentifier else {
                    throw DesktopExecutionError.targetChanged
                }
                let applicationElement = AXUIElementCreateApplication(target.processIdentifier)
                guard let windowValue = copyAttribute(applicationElement, kAXFocusedWindowAttribute as CFString),
                      CFGetTypeID(windowValue) == AXUIElementGetTypeID(),
                      uniquelyPressableElement(labeled: label, in: windowValue as! AXUIElement) != nil else {
                    return DesktopActionResult(verified: false)
                }
                guard await authorize(),
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier,
                      sameObservationContext(try await observe(), expectedObservation),
                      let currentWindow = copyAttribute(applicationElement, kAXFocusedWindowAttribute as CFString),
                      CFEqual(currentWindow, windowValue),
                      let control = uniquelyPressableElement(
                        labeled: label,
                        in: currentWindow as! AXUIElement
                      ) else {
                    throw DesktopExecutionError.targetChanged
                }
                let status = AXUIElementPerformAction(control, kAXPressAction as CFString)
                return DesktopActionResult(
                    verified: status == .success,
                    effectAttempted: status == .success
                )
            case let .insertText(text):
                let role = copyAttribute(focused, kAXRoleAttribute as CFString) as? String
                let subrole = copyAttribute(focused, kAXSubroleAttribute as CFString) as? String
                guard let role else {
                    throw DesktopExecutionError.nativeFailure("The focused Accessibility element has no role.")
                }
                guard !Self.isSecureTextField(role: role, subrole: subrole) else {
                    throw DesktopExecutionError.nativeFailure("Secure text fields are not controlled by FlowState.")
                }
                guard Self.canReadValue(role: role, subrole: subrole) else {
                    throw DesktopExecutionError.nativeFailure("The focused Accessibility element cannot be verified safely.")
                }
                guard await authorize() else { throw DesktopExecutionError.staleGeneration }
                let effectFocused = try focusedElement(matching: expectedObservation)
                let effectRole = copyAttribute(effectFocused, kAXRoleAttribute as CFString) as? String
                let effectSubrole = copyAttribute(effectFocused, kAXSubroleAttribute as CFString) as? String
                guard let effectRole,
                      Self.canReadValue(role: effectRole, subrole: effectSubrole),
                      let effectPrevious = copyAttribute(effectFocused, kAXValueAttribute as CFString) as? String,
                      let effectSelectedRange = selectedTextRange(for: effectFocused),
                      let effectExpectedAfter = replacing(effectPrevious, range: effectSelectedRange, with: text)
                else {
                    return DesktopActionResult(verified: false)
                }
                guard AXUIElementSetAttributeValue(
                    effectFocused,
                    kAXSelectedTextAttribute as CFString,
                    text as CFString
                ) == .success else {
                    return DesktopActionResult(verified: false, valueBefore: effectPrevious)
                }
                let after = copyAttribute(effectFocused, kAXValueAttribute as CFString) as? String
                return DesktopActionResult(
                    verified: after == effectExpectedAfter,
                    effectAttempted: true,
                    valueBefore: effectPrevious,
                    valueAfter: after
                )
            case .openApplication, .scroll:
                return DesktopActionResult(verified: false)
            }
            return DesktopActionResult(verified: true)
        }
    }

    public func restoreValue(
        _ value: String,
        expectedObservation: DesktopObservation,
        authorize: @escaping @Sendable () async -> Bool
    ) async throws {
        let current = try await observe()
        guard current.bundleIdentifier == expectedObservation.bundleIdentifier,
              sameElementIdentity(current.focusedElementID, expectedObservation.focusedElementID),
              current.value == expectedObservation.value
        else { throw DesktopExecutionError.interveningEdit }
        let focused = try focusedElement(matching: expectedObservation)
        let role = copyAttribute(focused, kAXRoleAttribute as CFString) as? String
        let subrole = copyAttribute(focused, kAXSubroleAttribute as CFString) as? String
        guard Self.canReadValue(role: role, subrole: subrole),
              sameElementIdentity(retainedElementIdentifier(focused), expectedObservation.focusedElementID) else {
            throw DesktopExecutionError.interveningEdit
        }
        guard await authorize() else { throw DesktopExecutionError.staleGeneration }
        let effectFocused = try focusedElement(matching: expectedObservation)
        let effectRole = copyAttribute(effectFocused, kAXRoleAttribute as CFString) as? String
        let effectSubrole = copyAttribute(effectFocused, kAXSubroleAttribute as CFString) as? String
        guard Self.canReadValue(role: effectRole, subrole: effectSubrole),
              let effectValue = copyAttribute(effectFocused, kAXValueAttribute as CFString) as? String,
              effectValue == expectedObservation.value else {
            throw DesktopExecutionError.interveningEdit
        }
        guard AXUIElementSetAttributeValue(effectFocused, kAXValueAttribute as CFString, value as CFString) == .success else {
            throw DesktopExecutionError.nativeFailure("The focused element rejected the previous value.")
        }
    }

    private func focusedElement() throws -> AXUIElement {
        let system = AXUIElementCreateSystemWide()
        guard let value = copyAttribute(system, kAXFocusedUIElementAttribute as CFString)
        else { throw DesktopExecutionError.nativeFailure("No focused Accessibility element is available.") }
        return value as! AXUIElement
    }

    private static let allowedPressKeys = NativePlanAction.allowedPressKeys
    private static let allowedPressModifiers = NativePlanAction.allowedPressModifiers

    private func accessibleLabel(_ element: AXUIElement) -> String? {
        for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute] {
            if let value = copyAttribute(element, attribute as CFString) as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }
        return nil
    }

    private static func isEditable(_ element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success
            && settable.boolValue
    }

    private static func keyCode(for key: String) -> CGKeyCode? {
        switch key {
        case "ArrowUp": 126
        case "ArrowDown": 125
        case "ArrowLeft": 123
        case "ArrowRight": 124
        case "PageUp": 116
        case "PageDown": 121
        case "Home": 115
        case "End": 119
        case "Tab": 48
        case "Escape": 53
        case "Enter": 36
        case "A": 0
        case "C": 8
        case "V": 9
        default: nil
        }
    }

    private func focusedElement(matching expectedObservation: DesktopObservation) throws -> AXUIElement {
        let element = try focusedElement()
        guard sameElementIdentity(retainedElementIdentifier(element), expectedObservation.focusedElementID) else {
            throw DesktopExecutionError.targetChanged
        }
        return element
    }

    private func retainedElementIdentifier(_ element: AXUIElement) -> String {
        identityLock.lock()
        defer { identityLock.unlock() }

        if let existingID = retainedElementOrder.first(where: { id in
            guard let retained = retainedElements[id] else { return false }
            return CFEqual(retained as CFTypeRef, element as CFTypeRef)
        }) {
            return existingID
        }

        let id = UUID().uuidString
        retainedElements[id] = element
        retainedElementOrder.append(id)
        if retainedElementOrder.count > Self.maxRetainedElements {
            let evictedID = retainedElementOrder.removeFirst()
            retainedElements.removeValue(forKey: evictedID)
        }
        return id
    }

    private func verticalScrollbar(in window: AXUIElement) -> AXUIElement? {
        var ancestor = try? focusedElement()
        for _ in 0..<32 {
            guard let current = ancestor else { break }
            if let bar = copyAttribute(current, kAXVerticalScrollBarAttribute as CFString), CFGetTypeID(bar) == AXUIElementGetTypeID() { return (bar as! AXUIElement) }
            if CFEqual(current, window) { break }
            ancestor = copyAttribute(current, kAXParentAttribute as CFString).flatMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
        }
        var queue = [window]
        var index = 0
        var found: AXUIElement?
        while index < queue.count, index < 256 {
            let element = queue[index]; index += 1
            if copyAttribute(element, kAXRoleAttribute as CFString) as? String == kAXScrollBarRole,
               copyAttribute(element, kAXOrientationAttribute as CFString) as? String == kAXVerticalOrientationValue {
                if found != nil { return nil }
                found = element
            }
            if let children = copyAttribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement] { queue.append(contentsOf:children) }
        }
        return index == queue.count ? found : nil
    }

    private struct ScrollCandidate {
        let element: AXUIElement
        let frame: CGRect
    }

    private func scrollWebContent(
        in window: AXUIElement,
        lines: Int32,
        expectedFocus: String?,
        authorize: @escaping @Sendable () async -> Bool
    ) async throws -> DesktopActionResult {
        guard let context = webScrollContext(in: window) else {
            throw DesktopExecutionError.nativeFailure("This window does not expose an accessible scroll target.")
        }
        let frames = context.candidates.map(\.frame)
        guard let targetIndex = axScrollTargetIndex(candidates: frames, viewport: context.viewport, lines: lines) else {
            throw DesktopExecutionError.nativeFailure("No more accessible content was found in that direction.")
        }
        let target = context.candidates[targetIndex]
        guard await authorize() else { throw DesktopExecutionError.staleGeneration }
        let currentViewport = frame(of: context.webArea)
        let currentTargetFrame = frame(of: target.element)
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == context.processIdentifier,
              let currentWindow = copyAttribute(
                  AXUIElementCreateApplication(context.processIdentifier),
                  kAXFocusedWindowAttribute as CFString
              ),
              CFEqual(currentWindow, window),
              sameElementIdentity((try? focusedElement()).map(retainedElementIdentifier), expectedFocus),
              let currentViewport,
              currentViewport == context.viewport,
              let currentTargetFrame,
              currentTargetFrame == target.frame else {
            throw DesktopExecutionError.targetChanged
        }
        guard AXUIElementPerformAction(target.element, "AXScrollToVisible" as CFString) == .success else {
            return DesktopActionResult(verified: false, effectAttempted: true)
        }
        for _ in 0..<10 {
            guard await authorize() else { throw DesktopExecutionError.staleGeneration }
            if let after = frame(of: target.element), after.width > 0, after.height > 0,
               (lines < 0 && after.minY < target.frame.minY) ||
                (lines > 0 && after.maxY > target.frame.maxY) {
                return DesktopActionResult(verified: true)
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        return DesktopActionResult(verified: false, effectAttempted: true)
    }

    private struct WebScrollContext {
        let processIdentifier: pid_t
        let webArea: AXUIElement
        let viewport: CGRect
        let candidates: [ScrollCandidate]
    }

    private func webScrollContext(in window: AXUIElement) -> WebScrollContext? {
        var webAreas: [AXUIElement] = []
        var queue = [window]
        var index = 0
        while index < queue.count, index < 4096 {
            let element = queue[index]
            index += 1
            if copyAttribute(element, kAXRoleAttribute as CFString) as? String == "AXWebArea" {
                webAreas.append(element)
                continue
            }
            if let children = copyAttribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement] {
                queue.append(contentsOf: children)
            }
        }
        guard index == queue.count else { return nil }
        guard webAreas.count == 1,
              let viewport = frame(of: webAreas[0]) else { return nil }

        var candidates: [ScrollCandidate] = []
        queue = [webAreas[0]]
        index = 0
        while index < queue.count, index < 4096 {
            let element = queue[index]
            index += 1
            if element !== webAreas[0],
               let role = copyAttribute(element, kAXRoleAttribute as CFString) as? String,
               ["AXStaticText", "AXHeading", "AXLink"].contains(role),
               actionNames(for: element).contains("AXScrollToVisible"),
               let frame = frame(of: element),
               frame.width > 0, frame.height >= 0 {
                candidates.append(ScrollCandidate(element: element, frame: frame))
            }
            if let children = copyAttribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement] {
                queue.append(contentsOf: children)
            }
        }
        guard index == queue.count else { return nil }
        guard !candidates.isEmpty,
              let application = NSWorkspace.shared.frontmostApplication else { return nil }
        return WebScrollContext(
            processIdentifier: application.processIdentifier,
            webArea: webAreas[0],
            viewport: viewport,
            candidates: candidates
        )
    }

    private func actionNames(for element: AXUIElement) -> [String] {
        var values: CFArray?
        guard AXUIElementCopyActionNames(element, &values) == .success,
              let values else { return [] }
        return (values as NSArray).compactMap { $0 as? String }
    }

    private func uniquelyPressableElement(labeled label: String, in root: AXUIElement) -> AXUIElement? {
        let expected = label.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var queue = [root]
        var matches: [AXUIElement] = []
        var index = 0
        while index < queue.count, index < 4_096 {
            let element = queue[index]
            index += 1
            let actual = accessibleLabel(element)?
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let enabled = (copyAttribute(element, kAXEnabledAttribute as CFString) as? NSNumber)?.boolValue
            if actual == expected,
               Self.isPressableControlEnabled(enabled),
               actionNames(for: element).contains(kAXPressAction as String) {
                matches.append(element)
                if matches.count > 1 { return nil }
            }
            if let children = copyAttribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement] {
                queue.append(contentsOf: children)
            }
        }
        guard index == queue.count else { return nil }
        return matches.first
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        guard let positionValue = copyAttribute(element, kAXPositionAttribute as CFString),
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              let sizeValue = copyAttribute(element, kAXSizeAttribute as CFString),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        let position = positionValue as! AXValue
        let size = sizeValue as! AXValue
        guard AXValueGetType(position) == .cgPoint,
              AXValueGetType(size) == .cgSize else { return nil }
        var origin = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &origin),
              AXValueGetValue(size, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: origin, size: dimensions)
    }

    private func selectedTextRange(for element: AXUIElement) -> CFRange? {
        guard let value = copyAttribute(element, kAXSelectedTextRangeAttribute as CFString) else {
            return nil
        }
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cfRange
        else { return nil }
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return range
    }

    private func replacing(_ value: String, range: CFRange, with replacement: String) -> String? {
        let source = value as NSString
        guard range.location >= 0,
              range.length >= 0,
              range.location <= source.length,
              range.length <= source.length - range.location
        else { return nil }
        return source.replacingCharacters(
            in: NSRange(location: range.location, length: range.length),
            with: replacement
        )
    }

    private func copyAttribute(_ element: AXUIElement, _ attribute: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value
    }

    static func tagAutomationEvent(_ event: CGEvent) {
        event.setIntegerValueField(
            .eventSourceUserData,
            value: Int64(bitPattern: InputTakeoverMonitor.automationEventTag)
        )
    }
}

func axScrollTargetIndex(candidates: [CGRect], viewport: CGRect, lines: Int32) -> Int? {
    guard lines != 0,
          viewport.width > 0,
          viewport.height > 0 else { return nil }
    let valid = candidates.enumerated().filter { _, frame in
        frame.width > 0 && frame.height >= 0
    }
    if lines < 0 {
        return valid
            .filter { $0.element.minY >= viewport.maxY }
            .min { $0.element.minY < $1.element.minY }?
            .offset
    }
    return valid
        .filter { $0.element.minY <= viewport.minY && $0.element.maxY <= viewport.minY + 1 }
        .max { $0.element.maxY == $1.element.maxY ? $0.offset < $1.offset : $0.element.maxY < $1.element.maxY }?
        .offset
}

private func sameElementIdentity(_ lhs: String?, _ rhs: String?) -> Bool {
    lhs == rhs
}

private func sameObservationContext(_ lhs: DesktopObservation, _ rhs: DesktopObservation) -> Bool {
    lhs.bundleIdentifier == rhs.bundleIdentifier &&
        sameElementIdentity(lhs.focusedElementID, rhs.focusedElementID) &&
        lhs.focusedRole == rhs.focusedRole &&
        lhs.focusedLabel == rhs.focusedLabel &&
        lhs.isEditable == rhs.isEditable &&
        lhs.isSecure == rhs.isSecure &&
        lhs.selectedTextRange == rhs.selectedTextRange
}


/// Verify an observable result, not merely successful construction of an input event.
func keyboardEffectObserved(key: String, modifiers: String?, before: DesktopObservation,
                            after: DesktopObservation, clipboardChanged: Bool) -> Bool {
    guard before.bundleIdentifier == after.bundleIdentifier else { return false }
    if key == "C", modifiers == "Command" { return clipboardChanged }
    if key == "A", modifiers == "Command", let value = before.value {
        return after.focusedElementID == before.focusedElementID &&
            after.selectedTextRange == DesktopTextRange(location: 0, length: (value as NSString).length)
    }
    if key == "Tab", after.focusedElementID != before.focusedElementID { return true }
    guard after.focusedElementID == before.focusedElementID else { return false }
    return after.value != before.value || after.selectedTextRange != before.selectedTextRange
}
