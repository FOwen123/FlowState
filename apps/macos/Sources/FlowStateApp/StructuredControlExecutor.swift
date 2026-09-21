import AppKit
import Foundation
import FlowStateCore

enum StructuredControlError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedAction
    case invalidURL
    case invalidTarget
    case postHandoffTargetMismatch
    case cancelled
    case openFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedAction: "This structured action is not available on this Mac."
        case .invalidURL: "The URL is not safe to open."
        case .invalidTarget: "The selected browser is not registered for URL handoff."
        case .postHandoffTargetMismatch: "The selected browser did not become frontmost after the handoff."
        case .cancelled: "The reviewed action was cancelled."
        case .openFailed: "The reviewed handoff could not be opened."
        }
    }
}

struct StructuredControlResult: Equatable, Sendable {
    let kind: NativePlanActionKind
    let url: URL
    let targetBundleIdentifier: String?
}

final class StructuredControlGeneration: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0

    func begin() -> UInt64 {
        lock.lock()
        generation &+= 1
        let value = generation
        lock.unlock()
        return value
    }

    func invalidate() {
        lock.lock()
        generation &+= 1
        lock.unlock()
    }

    func isCurrent(_ value: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generation == value
    }
}

struct StructuredControlExecutor: Sendable {
    typealias Launcher = @Sendable (URL, String?) async throws -> Bool
    typealias HandoffVerifier = @Sendable (String, URL) async -> Bool

    private let launcher: Launcher
    private let verifier: HandoffVerifier

    init(launcher: @escaping Launcher, verifier: @escaping HandoffVerifier = { _, _ in true }) {
        self.launcher = launcher
        self.verifier = verifier
    }

    func execute(
        _ action: NativePlanAction,
        targetBundleIdentifier: String? = nil,
        isCurrent: @escaping @Sendable () -> Bool
    ) async throws -> StructuredControlResult {
        guard action.route == .structuredIntegration,
              action.executor == "service",
              action.riskClass != .unsupported else {
            throw StructuredControlError.unsupportedAction
        }
        guard isCurrent(), !Task.isCancelled else { throw StructuredControlError.cancelled }
        let url: URL
        switch action.parameters {
        case let .openURL(value):
            url = try Self.safeURL(value)
        case let .draftMessage(recipient, subject, body):
            let draft = try GmailDraft(recipient: recipient, subject: subject, body: body)
            url = try draft.composeURL()
        default:
            throw StructuredControlError.unsupportedAction
        }
        guard let target = targetBundleIdentifier ?? action.targetBundleIdentifier,
              Self.browserBundleIdentifiers.contains(target) else {
            throw StructuredControlError.invalidTarget
        }
        guard Self.canonicalServiceAction(action) else {
            throw StructuredControlError.unsupportedAction
        }
        guard isCurrent(), !Task.isCancelled else { throw StructuredControlError.cancelled }
        guard try await launcher(url, target) else { throw StructuredControlError.openFailed }
        guard isCurrent(), !Task.isCancelled else { throw StructuredControlError.cancelled }
        guard await verifier(target, url) else { throw StructuredControlError.postHandoffTargetMismatch }
        guard isCurrent(), !Task.isCancelled else { throw StructuredControlError.cancelled }
        return StructuredControlResult(kind: action.kind, url: url, targetBundleIdentifier: target)
    }

    static func system() -> Self {
        Self(launcher: { url, target in
            guard !Task.isCancelled else { return false }
            guard let target,
                  let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: target) else {
                return false
            }
            return await withCheckedContinuation { continuation in
                NSWorkspace.shared.open(
                    [url],
                    withApplicationAt: applicationURL,
                    configuration: NSWorkspace.OpenConfiguration()
                ) { _, error in
                    continuation.resume(returning: error == nil)
                }
            }
        }, verifier: { target, _ in
            for _ in 0..<10 {
                guard !Task.isCancelled else { return false }
                if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == target { return true }
                try? await Task.sleep(for: .milliseconds(50))
            }
            return false
        })
    }

    @MainActor
    static func availableBrowserBundleIdentifiers(registry: ApplicationRegistry) -> Set<String> {
        Set(registry.entries.compactMap { entry in
            guard entry.integrations.contains("browser"),
                  browserBundleIdentifiers.contains(entry.bundleIdentifier),
                  NSWorkspace.shared.urlForApplication(withBundleIdentifier: entry.bundleIdentifier) != nil else {
                return nil
            }
            return entry.bundleIdentifier
        })
    }

    @MainActor
    static func availableIntegrations(registry: ApplicationRegistry) -> Set<String> {
        availableBrowserBundleIdentifiers(registry: registry).isEmpty ? [] : ["browser"]
    }

    @MainActor
    static func supportsTarget(_ targetBundleIdentifier: String?, registry: ApplicationRegistry) -> Bool {
        guard let targetBundleIdentifier else { return false }
        return availableBrowserBundleIdentifiers(registry: registry).contains(targetBundleIdentifier)
    }

    static func targetMatches(expected: String, observed: String?) -> Bool {
        observed == expected
    }

    private static func canonicalServiceAction(_ action: NativePlanAction) -> Bool {
        switch action.kind {
        case .openURL:
            return !action.requiresApproval && action.riskClass == .reversible
        case .draftMessage:
            return action.requiresApproval && action.riskClass == .confirm
        default:
            return false
        }
    }

    private static func safeURL(_ value: String) throws -> URL {
        guard value.utf8.count <= 2_000,
              let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else {
            throw StructuredControlError.invalidURL
        }
        return url
    }

    private static let browserBundleIdentifiers: Set<String> = [
        "com.brave.Browser",
        "com.apple.Safari",
        "com.google.Chrome",
    ]
}
