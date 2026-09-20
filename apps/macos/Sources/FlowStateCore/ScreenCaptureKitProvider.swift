@preconcurrency import ScreenCaptureKit
import ApplicationServices
import Foundation

@available(macOS 14.0, *)
struct ScreenCaptureKitProvider: ScreenCaptureProvider {
    init() {}

    func capture(
        request: CaptureRequest,
        beforeCapture: @escaping @Sendable () async -> Bool
    ) async throws -> CapturedImage {
        let content = try await shareableContent()
        let window = selectWindow(in: content, request: request)
        guard let window else {
            throw CaptureError.noWindow(request.bundleIdentifier)
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        configuration.showsCursor = false
        let scale = safeScale(filter.pointPixelScale)
        let dimensions = boundedDimensions(for: window.frame, scale: scale)
        configuration.width = dimensions.width
        configuration.height = dimensions.height

        let observation = try makeObservation(
            for: window,
            in: content,
            scale: scale,
            capturedAt: Date()
        )

        // Enumeration can take time. Recheck authorization and cancellation
        // immediately before asking ScreenCaptureKit for pixels.
        guard await beforeCapture() else {
            throw CaptureError.staleGeneration
        }
        guard observation.uploadSafe else { throw CaptureError.sensitiveContent }
        let image = try await captureImage(filter: filter, configuration: configuration)
        return CapturedImage(image: image, observation: observation)
    }

    func currentObservation(
        request: CaptureRequest,
        beforeCapture: @escaping @Sendable () async -> Bool
    ) async throws -> CaptureObservation {
        let content = try await shareableContent()
        guard let window = selectWindow(in: content, request: request) else {
            throw CaptureError.windowClosed
        }
        guard await beforeCapture() else {
            throw CaptureError.staleGeneration
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        return try makeObservation(
            for: window,
            in: content,
            scale: safeScale(filter.pointPixelScale),
            capturedAt: Date()
        )
    }

    private func selectWindow(
        in content: SCShareableContent,
        request: CaptureRequest
    ) -> SCWindow? {
        let candidates = content.windows.filter { window in
            guard window.isOnScreen,
                  window.owningApplication?.bundleIdentifier == request.bundleIdentifier
            else { return false }
            return request.windowID == nil || window.windowID == request.windowID
        }
        if request.windowID != nil {
            return candidates.first
        }
        if let activeWindow = candidates.first(where: \.isActive) {
            return activeWindow
        }
        guard candidates.count == 1 else {
            // Do not guess between multiple windows when macOS has not marked one active.
            return nil
        }
        return candidates[0]
    }

    private func makeObservation(
        for window: SCWindow,
        in content: SCShareableContent,
        scale: CGFloat,
        capturedAt: Date
    ) throws -> CaptureObservation {
        let security = CaptureSecurityScanner.scan(window: window)
        return CaptureObservation(
            bundleIdentifier: window.owningApplication?.bundleIdentifier ?? "",
            windowID: window.windowID,
            displayID: try displayID(for: window.frame, in: content),
            capturedAt: capturedAt,
            windowFrame: window.frame,
            scale: scale,
            security: security
        )
    }

    private func displayID(for frame: CGRect, in content: SCShareableContent) throws -> UInt32 {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        if let display = content.displays.first(where: { $0.frame.contains(center) }) {
            guard display.displayID != 0 else { throw CaptureError.displayUnavailable }
            return display.displayID
        }
        if let display = content.displays.max(by: {
            frame.intersection($0.frame).area < frame.intersection($1.frame).area
        }), frame.intersection(display.frame).isNull == false {
            guard display.displayID != 0 else { throw CaptureError.displayUnavailable }
            return display.displayID
        }
        throw CaptureError.displayUnavailable
    }

    private func safeScale(_ value: Float) -> CGFloat {
        guard value.isFinite, value > 0 else { return 1 }
        return CGFloat(value)
    }

    private func boundedDimensions(
        for frame: CGRect,
        scale: CGFloat
    ) -> (width: Int, height: Int) {
        let pixelWidth = max(1, Int((frame.width * scale).rounded(.up)))
        let pixelHeight = max(1, Int((frame.height * scale).rounded(.up)))
        let largest = max(pixelWidth, pixelHeight)
        let ratio = min(1, CGFloat(CaptureImageBounds.defaultMaximumDimension) / CGFloat(largest))
        return (
            max(1, Int((CGFloat(pixelWidth) * ratio).rounded(.down))),
            max(1, Int((CGFloat(pixelHeight) * ratio).rounded(.down)))
        )
    }

    private func shareableContent() async throws -> SCShareableContent {
        try await withCheckedThrowingContinuation { continuation in
            SCShareableContent.getExcludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            ) { content, error in
                if let content {
                    continuation.resume(returning: content)
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(throwing: CaptureError.permissionDenied)
                }
            }
        }
    }

    private func captureImage(
        filter: SCContentFilter,
        configuration: SCStreamConfiguration
    ) async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            ) { image, error in
                if let image {
                    continuation.resume(returning: image)
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(throwing: CaptureError.permissionDenied)
                }
            }
        }
    }
}

private enum CaptureSecurityScanner {
    private static let maxElements = 512

    static func scan(window: SCWindow) -> CaptureSecurity {
        guard let application = window.owningApplication,
              AXIsProcessTrusted()
        else { return .unknown }

        let applicationElement = AXUIElementCreateApplication(application.processID)
        let windows = attribute(applicationElement, kAXWindowsAttribute as CFString)
        guard windows.status == .success,
              let windowElements = windows.value as? [AXUIElement]
        else { return .unknown }

        let matchingWindows = windowElements.filter { axWindow in
            guard let frame = frame(of: axWindow) else { return false }
            return frame == window.frame
        }
        guard matchingWindows.count == 1, let matchingWindow = matchingWindows.first else {
            return .unknown
        }

        var queue = [matchingWindow]
        var index = 0
        while index < queue.count {
            guard queue.count <= maxElements else { return .unknown }
            let element = queue[index]
            index += 1

            let roleResult = attribute(element, kAXRoleAttribute as CFString)
            guard roleResult.status == .success,
                  let role = roleResult.value as? String
            else { return .unknown }
            let subroleResult = attribute(element, kAXSubroleAttribute as CFString)
            let subrole: String?
            switch subroleResult.status {
            case .success:
                guard let value = subroleResult.value as? String else { return .unknown }
                subrole = value
            case .noValue, .attributeUnsupported:
                subrole = nil
            default:
                return .unknown
            }
            if role == "AXSecureTextField" || subrole == "AXSecureTextField" {
                return .secureContent
            }

            let children = attribute(element, kAXChildrenAttribute as CFString)
            switch children.status {
            case .success:
                guard let values = children.value as? [AXUIElement] else { return .unknown }
                queue.append(contentsOf: values)
            case .noValue, .attributeUnsupported:
                break
            default:
                return .unknown
            }
        }
        return .clear
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        let position = attribute(element, kAXPositionAttribute as CFString)
        let size = attribute(element, kAXSizeAttribute as CFString)
        guard position.status == .success,
              size.status == .success,
              let positionRef = position.value,
              let sizeRef = size.value
        else { return nil }
        guard CFGetTypeID(positionRef) == AXValueGetTypeID(), CFGetTypeID(sizeRef) == AXValueGetTypeID() else { return nil }
        let positionValue = positionRef as! AXValue
        let sizeValue = sizeRef as! AXValue
        guard AXValueGetType(positionValue) == .cgPoint,
              AXValueGetType(sizeValue) == .cgSize
        else { return nil }

        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &point),
              AXValueGetValue(sizeValue, .cgSize, &dimensions)
        else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    private static func attribute(
        _ element: AXUIElement,
        _ name: CFString
    ) -> (status: AXError, value: CFTypeRef?) {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, name, &value)
        return (status, value)
    }
}

private extension CGRect {
    var area: CGFloat {
        guard !isNull, !isInfinite else { return 0 }
        return max(0, width) * max(0, height)
    }
}
