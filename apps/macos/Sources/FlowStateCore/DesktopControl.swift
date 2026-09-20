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
    case insertText
}

public enum DesktopAction: Equatable, Codable, Sendable {
    case openApplication(bundleIdentifier: String)
    case scroll(lines: Int32)
    case focus(role: String?)
    case select
    case press
    case insertText(String)

    public var kind: DesktopActionKind {
        switch self {
        case .openApplication: .openApplication
        case .scroll: .scroll
        case .focus: .focus
        case .select: .select
        case .press: .press
        case .insertText: .insertText
        }
    }
}

public enum DesktopUndoSupport: String, Codable, Equatable, Sendable {
    case none
    case restoreText
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
              allowedActions.contains(action.kind) else { return false }
        if case let .openApplication(actionBundleIdentifier) = action {
            return actionBundleIdentifier == bundleIdentifier
        }
        return true
    }
}

public struct DesktopObservation: Codable, Equatable, Sendable {
    public let bundleIdentifier: String
    public let focusedElementID: String?
    public let value: String?
    public let observedAt: Date

    public init(
        bundleIdentifier: String,
        focusedElementID: String? = nil,
        value: String? = nil,
        observedAt: Date = Date()
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.focusedElementID = focusedElementID
        self.value = value
        self.observedAt = observedAt
    }
}

public struct DesktopActionResult: Equatable, Sendable {
    public let verified: Bool
    public let valueBefore: String?
    public let valueAfter: String?

    public init(verified: Bool, valueBefore: String? = nil, valueAfter: String? = nil) {
        self.verified = verified
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
    case cancelled
}

public enum DesktopExecutionError: Error, Equatable, LocalizedError, Sendable {
    case notStarted
    case staleGeneration
    case grantExpired
    case actionNotGranted
    case targetChanged
    case verificationFailed
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
        case .verificationFailed: "The action ran but its expected effect was not verified."
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

/// Serializes desktop effects and rejects late work after local cancellation or
/// physical takeover. The caller must supply a grant for each task.
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

    public func cancel(lifecycleEpoch: UInt64? = nil) {
        guard acceptLifecycleEpoch(lifecycleEpoch) else { return }
        generation &+= 1
        activeOperation = nil
        grant = nil
        stateValue = .cancelled
    }

    public func notePhysicalTakeover(lifecycleEpoch: UInt64? = nil) {
        guard acceptLifecycleEpoch(lifecycleEpoch) else { return }
        guard stateValue == .ready || stateValue == .running else { return }
        generation &+= 1
        activeOperation = nil
        stateValue = .pausedForUser
    }

    @discardableResult
    public func resume() async throws -> DesktopObservation {
        guard stateValue == .pausedForUser else {
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
        expectedBundleIdentifier: String
    ) async throws -> VerifiedDesktopAction {
        guard stateValue == .ready else {
            if stateValue == .pausedForUser { throw DesktopExecutionError.pausedForTakeover }
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
        do {
            let before = try await driver.observe()
            guard isCurrent(token, state: .running), grant.expiresAt > Date() else {
                throw DesktopExecutionError.staleGeneration
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
            guard isCurrent(token, state: .running) else {
                throw DesktopExecutionError.staleGeneration
            }
            let after = try await driver.observe()
            guard isCurrent(token, state: .running) else {
                throw DesktopExecutionError.staleGeneration
            }
            guard result.verified else {
                throw DesktopExecutionError.verificationFailed
            }
            guard after.bundleIdentifier == expectedBundleIdentifier,
                  action.kind == .openApplication || action.kind == .scroll ||
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
                stateValue = .ready
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
        guard stateValue == .ready else { throw DesktopExecutionError.notStarted }
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
        role == "AXTextField" && subrole == "AXSecureTextField"
    }

    static func canReadValue(role: String?, subrole: String?) -> Bool {
        guard role != nil else { return false }
        guard role != "AXSecureTextField" else { return false }
        return !isSecureTextField(role: role, subrole: subrole)
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
        let value: String?
        if Self.canReadValue(role: role, subrole: subrole) {
            value = focusedElement.flatMap { copyAttribute($0, kAXValueAttribute as CFString) as? String }
        } else {
            value = nil
        }
        let elementID = focusedElement.map(retainedElementIdentifier)
        return DesktopObservation(
            bundleIdentifier: bundleIdentifier,
            focusedElementID: elementID,
            value: value
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
                  sameElementIdentity(current.focusedElementID, expectedObservation.focusedElementID)
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
            return DesktopActionResult(verified: false)
        case let .scroll(lines):
            guard (-100...100).contains(lines) else { throw DesktopExecutionError.actionNotGranted }
            guard await authorize() else { throw DesktopExecutionError.staleGeneration }
            guard let target = NSWorkspace.shared.frontmostApplication,
                  target.bundleIdentifier == expectedObservation.bundleIdentifier else { throw DesktopExecutionError.targetChanged }
            let applicationElement = AXUIElementCreateApplication(target.processIdentifier)
            guard let windowValue = copyAttribute(applicationElement, kAXFocusedWindowAttribute as CFString),
                  CFGetTypeID(windowValue) == AXUIElementGetTypeID(),
                  let scrollbar = verticalScrollbar(in: windowValue as! AXUIElement),
                  let before = copyAttribute(scrollbar, kAXValueAttribute as CFString) as? NSNumber,
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
            return DesktopActionResult(verified:false)
        case .focus, .select, .press, .insertText:
            guard AXIsProcessTrusted() else { throw DesktopExecutionError.accessibilityDenied }
            let focused = try focusedElement(matching: expectedObservation)
            switch action {
            case let .focus(role):
                if let role, let actual = copyAttribute(focused, kAXRoleAttribute as CFString) as? String, role != actual {
                    return DesktopActionResult(verified: false)
                }
                guard await authorize() else { throw DesktopExecutionError.staleGeneration }
            case .select:
                guard await authorize() else { throw DesktopExecutionError.staleGeneration }
                let effectFocused = try focusedElement(matching: expectedObservation)
                guard AXUIElementSetAttributeValue(effectFocused, kAXSelectedAttribute as CFString, kCFBooleanTrue) == .success else {
                    return DesktopActionResult(verified: false)
                }
            case .press:
                guard await authorize() else { throw DesktopExecutionError.staleGeneration }
                let effectFocused = try focusedElement(matching: expectedObservation)
                guard AXUIElementPerformAction(effectFocused, kAXPressAction as CFString) == .success else {
                    return DesktopActionResult(verified: false)
                }
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

    private func selectedTextRange(for element: AXUIElement) -> CFRange? {
        guard let value = copyAttribute(element, kAXSelectedTextRangeAttribute as CFString) else {
            return nil
        }
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
}

private func sameElementIdentity(_ lhs: String?, _ rhs: String?) -> Bool {
    lhs == rhs
}
