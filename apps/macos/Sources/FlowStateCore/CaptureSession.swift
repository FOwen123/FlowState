import CoreGraphics
import Foundation

public enum CaptureError: Error, Equatable, LocalizedError, Sendable {
    case inactive
    case appNotApproved(String)
    case sensitiveAppExcluded(String)
    case staleGeneration
    case expired
    case noWindow(String)
    case permissionDenied
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .inactive:
            "Screen capture is unavailable until an active task grants it."
        case let .appNotApproved(bundleIdentifier):
            "Screen capture is not approved for \(bundleIdentifier)."
        case let .sensitiveAppExcluded(bundleIdentifier):
            "Screen capture is disabled for sensitive application \(bundleIdentifier)."
        case .staleGeneration:
            "The capture request belongs to a revoked or replaced task."
        case .expired:
            "The screen-capture grant has expired."
        case let .noWindow(bundleIdentifier):
            "No visible window was found for \(bundleIdentifier)."
        case .permissionDenied:
            "macOS denied Screen Recording access."
        case .cancelled:
            "The capture was cancelled."
        }
    }
}

public struct CaptureGrant: Equatable, Sendable {
    public static let defaultDuration: TimeInterval = 5 * 60

    public let allowedBundleIdentifiers: Set<String>
    public let generation: UInt64
    public let expiresAt: Date

    init(
        allowedBundleIdentifiers: Set<String>,
        generation: UInt64,
        expiresAt: Date
    ) {
        self.allowedBundleIdentifiers = allowedBundleIdentifiers
        self.generation = generation
        self.expiresAt = expiresAt
    }
}

/// An image returned by ScreenCaptureKit and kept in memory only.
/// No URL or file-writing operation is exposed by this type.
public final class CapturedImage: @unchecked Sendable {
    public let image: CGImage
    public let capturedAt: Date

    public init(image: CGImage, capturedAt: Date = Date()) {
        self.image = image
        self.capturedAt = capturedAt
    }
}

struct CaptureRequest: Equatable, Sendable {
    let bundleIdentifier: String
    let generation: UInt64
    let windowID: UInt32?

    init(bundleIdentifier: String, generation: UInt64, windowID: UInt32? = nil) {
        self.bundleIdentifier = bundleIdentifier
        self.generation = generation
        self.windowID = windowID
    }
}

protocol ScreenCaptureProvider: Sendable {
    func capture(
        request: CaptureRequest,
        beforeCapture: @escaping @Sendable () async -> Bool
    ) async throws -> CapturedImage
}

enum SensitiveApplicationPolicy {
    // Bundle-level exclusions are intentionally conservative. Field-level redaction
    // is not implemented, so an approved app is otherwise captured as a full window.
    static let excludedBundleIdentifiers: Set<String> = [
        "com.apple.keychainaccess",
        "com.apple.loginwindow",
        "com.apple.passwords",
        "com.apple.systempreferences",
        "com.apple.systemsettings",
        "com.agilebits.onepassword7",
        "com.1password.1password",
        "com.bitwarden.desktop",
        "com.lastpass.lastpass"
    ]

    static func isExcluded(_ bundleIdentifier: String) -> Bool {
        excludedBundleIdentifiers.contains(bundleIdentifier.lowercased())
    }
}

/// The only public entry point for capture. It owns authorization and the
/// provider lifecycle so final validation is synchronous within this actor.
public actor ScreenCaptureController {
    private let provider: any ScreenCaptureProvider
    private var generation: UInt64 = 0
    private var activeGrant: CaptureGrant?

    public init() {
        provider = ScreenCaptureKitProvider()
    }

    // Test-only injection. The concrete provider and request remain internal.
    init(provider: any ScreenCaptureProvider) {
        self.provider = provider
    }

    public func beginTask(
        allowedBundleIdentifiers: Set<String>,
        duration: TimeInterval = CaptureGrant.defaultDuration
    ) -> CaptureGrant {
        generation &+= 1
        let safeDuration = duration.isFinite && duration > 0
            ? duration
            : CaptureGrant.defaultDuration
        let grant = CaptureGrant(
            allowedBundleIdentifiers: allowedBundleIdentifiers,
            generation: generation,
            expiresAt: Date().addingTimeInterval(safeDuration)
        )
        activeGrant = grant
        return grant
    }

    public func revoke() {
        generation &+= 1
        activeGrant = nil
    }

    public func capture(
        bundleIdentifier: String,
        grant: CaptureGrant,
        windowID: UInt32? = nil
    ) async throws -> CapturedImage {
        do {
            try Task.checkCancellation()
        } catch {
            throw CaptureError.cancelled
        }

        let request = try makeRequest(
            bundleIdentifier: bundleIdentifier,
            generation: grant.generation,
            windowID: windowID
        )

        let image: CapturedImage
        do {
            image = try await provider.capture(request: request) { [weak self] in
                guard !Task.isCancelled, let self else { return false }
                return await self.isCurrent(request)
            }
            try Task.checkCancellation()
        } catch is CancellationError {
            throw CaptureError.cancelled
        }

        // There is no await between this validation and returning the image.
        // A revoke therefore cannot interleave after validation and before return.
        try validate(request)
        return image
    }

    private func makeRequest(
        bundleIdentifier: String,
        generation requestGeneration: UInt64,
        windowID: UInt32?
    ) throws -> CaptureRequest {
        guard requestGeneration == generation else {
            throw CaptureError.staleGeneration
        }
        guard let activeGrant else {
            throw CaptureError.inactive
        }
        guard activeGrant.expiresAt > Date() else {
            throw CaptureError.expired
        }
        guard !SensitiveApplicationPolicy.isExcluded(bundleIdentifier) else {
            throw CaptureError.sensitiveAppExcluded(bundleIdentifier)
        }
        guard activeGrant.allowedBundleIdentifiers.contains(bundleIdentifier) else {
            throw CaptureError.appNotApproved(bundleIdentifier)
        }
        return CaptureRequest(
            bundleIdentifier: bundleIdentifier,
            generation: requestGeneration,
            windowID: windowID
        )
    }

    private func validate(_ request: CaptureRequest) throws {
        _ = try makeRequest(
            bundleIdentifier: request.bundleIdentifier,
            generation: request.generation,
            windowID: request.windowID
        )
    }

    private func isCurrent(_ request: CaptureRequest) -> Bool {
        guard !Task.isCancelled else { return false }
        do {
            try validate(request)
            return true
        } catch {
            return false
        }
    }
}
