import CoreGraphics
import Foundation

public enum CaptureError: Error, Equatable, LocalizedError, Sendable {
    case inactive
    case appNotApproved(String)
    case sensitiveAppExcluded(String)
    case staleGeneration
    case staleObservation
    case expired
    case noWindow(String)
    case windowClosed
    case windowMoved
    case windowResized
    case wrongWindow
    case displayUnavailable
    case revalidationUnavailable
    case permissionDenied
    case cancelled
    case uploadNotApproved
    case sensitiveContent
    case invalidImageBounds
    case imageEncodingFailed
    case imageTooLarge

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
        case .staleObservation:
            "The screen observation is no longer valid for this task."
        case .expired:
            "The screen-capture grant has expired."
        case let .noWindow(bundleIdentifier):
            "No visible window was found for \(bundleIdentifier)."
        case .windowClosed:
            "The captured window is no longer available."
        case .windowMoved:
            "The captured window moved before it could be used."
        case .windowResized:
            "The captured window changed size or display scale."
        case .wrongWindow:
            "The captured window is no longer the approved target."
        case .displayUnavailable:
            "The captured window is not associated with a visible display."
        case .revalidationUnavailable:
            "The capture provider could not revalidate the approved window."
        case .permissionDenied:
            "macOS denied Screen Recording access."
        case .cancelled:
            "The capture was cancelled."
        case .uploadNotApproved:
            "Uploading a captured window requires an explicit approval."
        case .sensitiveContent:
            "The approved window may contain secure content and cannot be uploaded."
        case .invalidImageBounds:
            "The requested image bounds are invalid."
        case .imageEncodingFailed:
            "The captured image could not be encoded in memory."
        case .imageTooLarge:
            "The captured image exceeds the in-memory upload limit."
        }
    }
}

public struct CaptureGrant: Equatable, Sendable {
    public static let defaultDuration: TimeInterval = 5 * 60

    public let allowedBundleIdentifiers: Set<String>
    public let generation: UInt64
    public let expiresAt: Date

    public init(
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
    public let observation: CaptureObservation

    public init(
        image: CGImage,
        capturedAt: Date = Date(),
        observation: CaptureObservation? = nil
    ) {
        self.image = image
        self.capturedAt = capturedAt
        self.observation = observation ?? CaptureObservation(
            bundleIdentifier: "",
            windowID: 0,
            displayID: 0,
            capturedAt: capturedAt,
            windowFrame: .zero,
            scale: 1,
            security: .unknown
        )
    }

    public init(image: CGImage, observation: CaptureObservation) {
        self.image = image
        self.capturedAt = observation.capturedAt
        self.observation = observation
    }

    public func visuallyDiffers(from other: CapturedImage) -> Bool {
        guard image.width == other.image.width,
              image.height == other.image.height,
              let left = image.dataProvider?.data,
              let right = other.image.dataProvider?.data else { return true }
        return left != right
    }
}

struct CaptureRequest: Equatable, Sendable {
    let bundleIdentifier: String
    let generation: UInt64
    let windowID: UInt32?
    let requestedAt: Date

    init(
        bundleIdentifier: String,
        generation: UInt64,
        windowID: UInt32? = nil,
        requestedAt: Date = Date()
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.generation = generation
        self.windowID = windowID
        self.requestedAt = requestedAt
    }
}

protocol ScreenCaptureProvider: Sendable {
    func capture(
        request: CaptureRequest,
        beforeCapture: @escaping @Sendable () async -> Bool
    ) async throws -> CapturedImage

    func currentObservation(
        request: CaptureRequest,
        beforeCapture: @escaping @Sendable () async -> Bool
    ) async throws -> CaptureObservation
}

extension ScreenCaptureProvider {
    func currentObservation(
        request: CaptureRequest,
        beforeCapture: @escaping @Sendable () async -> Bool
    ) async throws -> CaptureObservation {
        throw CaptureError.revalidationUnavailable
    }
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
    private let now: @Sendable () -> Date
    private var generation: UInt64 = 0
    private var latestLifecycleEpoch: UInt64 = 0
    private var activeGrant: CaptureGrant?
    private var issuedObservations: [UUID: CaptureObservation] = [:]

    public init() {
        provider = ScreenCaptureKitProvider()
        now = { Date() }
    }

    // Test-only injection. The concrete provider and request remain internal.
    init(
        provider: any ScreenCaptureProvider,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.provider = provider
        self.now = now
    }

    public func beginTask(
        allowedBundleIdentifiers: Set<String>,
        duration: TimeInterval = CaptureGrant.defaultDuration
    ) -> CaptureGrant {
        let currentDate = now()
        if let activeGrant,
           activeGrant.expiresAt > currentDate,
           activeGrant.allowedBundleIdentifiers == allowedBundleIdentifiers {
            return activeGrant
        }

        generation &+= 1
        issuedObservations.removeAll(keepingCapacity: true)
        let safeDuration = duration.isFinite && duration > 0
            ? duration
            : CaptureGrant.defaultDuration
        let grant = CaptureGrant(
            allowedBundleIdentifiers: allowedBundleIdentifiers,
            generation: generation,
            expiresAt: currentDate.addingTimeInterval(safeDuration)
        )
        activeGrant = grant
        return grant
    }

    /// Starts an automatic capture task only if its lifecycle epoch is current.
    /// Older queued starts cannot resurrect a task after a newer revoke.
    public func beginAutomaticTask(
        allowedBundleIdentifiers: Set<String>,
        duration: TimeInterval = CaptureGrant.defaultDuration,
        lifecycleEpoch: UInt64
    ) throws -> CaptureGrant {
        guard acceptLifecycleEpoch(lifecycleEpoch) else {
            throw CaptureError.staleGeneration
        }
        return beginTask(
            allowedBundleIdentifiers: allowedBundleIdentifiers,
            duration: duration
        )
    }

    public func revoke(lifecycleEpoch: UInt64? = nil) {
        guard acceptLifecycleEpoch(lifecycleEpoch) else { return }
        generation &+= 1
        activeGrant = nil
        issuedObservations.removeAll(keepingCapacity: true)
    }

    private func acceptLifecycleEpoch(_ lifecycleEpoch: UInt64?) -> Bool {
        guard let lifecycleEpoch else { return true }
        guard lifecycleEpoch >= latestLifecycleEpoch else { return false }
        latestLifecycleEpoch = lifecycleEpoch
        return true
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
            windowID: windowID,
            requestedAt: now()
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
        } catch let error as CaptureError where error == .staleGeneration && Task.isCancelled {
            throw CaptureError.cancelled
        }

        // There is no await between this validation and returning the image.
        // A revoke therefore cannot interleave after validation and before return.
        try validate(request)
        try validate(image: image, for: request)
        if !image.observation.bundleIdentifier.isEmpty {
            issuedObservations[image.observation.id] = image.observation
        }
        return image
    }

    /// Rechecks the exact captured window before upload or coordinate-based
    /// execution. The returned Boolean is convenient for predicate-style
    /// callers, while all failures remain typed and fail closed.
    @discardableResult
    public func revalidate(
        _ observation: CaptureObservation,
        grant: CaptureGrant,
        forUpload: Bool = false
    ) async throws -> Bool {
        guard !Task.isCancelled else { throw CaptureError.cancelled }
        guard issuedObservations[observation.id] == observation else {
            throw CaptureError.staleObservation
        }

        let request = try makeRequest(
            bundleIdentifier: observation.bundleIdentifier,
            generation: grant.generation,
            windowID: observation.windowID,
            requestedAt: now()
        )

        let current: CaptureObservation
        do {
            current = try await provider.currentObservation(request: request) { [weak self] in
                guard !Task.isCancelled, let self else { return false }
                return await self.isCurrent(request)
            }
            try Task.checkCancellation()
        } catch is CancellationError {
            throw CaptureError.cancelled
        } catch let error as CaptureError where error == .staleGeneration && Task.isCancelled {
            throw CaptureError.cancelled
        }

        try validate(request)
        try compare(observation, with: current)
        if forUpload, !current.uploadSafe {
            throw CaptureError.sensitiveContent
        }
        return true
    }

    private func makeRequest(
        bundleIdentifier: String,
        generation requestGeneration: UInt64,
        windowID: UInt32?,
        requestedAt: Date
    ) throws -> CaptureRequest {
        guard requestGeneration == generation else {
            throw CaptureError.staleGeneration
        }
        guard let activeGrant else {
            throw CaptureError.inactive
        }
        guard activeGrant.expiresAt > now() else {
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
            windowID: windowID,
            requestedAt: requestedAt
        )
    }

    private func validate(_ request: CaptureRequest) throws {
        _ = try makeRequest(
            bundleIdentifier: request.bundleIdentifier,
            generation: request.generation,
            windowID: request.windowID,
            requestedAt: request.requestedAt
        )
    }

    private func validate(image: CapturedImage, for request: CaptureRequest) throws {
        let observation = image.observation
        guard observation.bundleIdentifier.isEmpty || observation.bundleIdentifier == request.bundleIdentifier else {
            throw CaptureError.wrongWindow
        }
        if let requestedWindowID = request.windowID,
           observation.windowID != 0,
           observation.windowID != requestedWindowID {
            throw CaptureError.wrongWindow
        }
    }

    private func compare(
        _ expected: CaptureObservation,
        with current: CaptureObservation
    ) throws {
        guard current.bundleIdentifier == expected.bundleIdentifier,
              current.windowID == expected.windowID
        else { throw CaptureError.wrongWindow }
        guard current.displayID == expected.displayID,
              current.windowFrame.origin == expected.windowFrame.origin
        else { throw CaptureError.windowMoved }
        guard current.windowFrame.size == expected.windowFrame.size,
              current.scale == expected.scale
        else { throw CaptureError.windowResized }
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
