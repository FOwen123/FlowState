@preconcurrency import ScreenCaptureKit
import Foundation

@available(macOS 14.0, *)
struct ScreenCaptureKitProvider: ScreenCaptureProvider {
    init() {}

    func capture(
        request: CaptureRequest,
        beforeCapture: @escaping @Sendable () async -> Bool
    ) async throws -> CapturedImage {
        let content = try await shareableContent()
        let candidates = content.windows.filter { window in
            guard window.isOnScreen,
                  window.owningApplication?.bundleIdentifier == request.bundleIdentifier
            else {
                return false
            }
            return request.windowID == nil || window.windowID == request.windowID
        }
        let window: SCWindow?
        if let requestedWindowID = request.windowID {
            window = candidates.first { $0.windowID == requestedWindowID }
        } else if let activeWindow = candidates.first(where: \.isActive) {
            window = activeWindow
        } else if candidates.count == 1 {
            window = candidates[0]
        } else {
            // Do not guess between multiple windows when macOS has not marked one active.
            window = nil
        }
        guard let window else {
            throw CaptureError.noWindow(request.bundleIdentifier)
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        configuration.showsCursor = false
        configuration.width = max(1, Int(window.frame.width * CGFloat(filter.pointPixelScale)))
        configuration.height = max(1, Int(window.frame.height * CGFloat(filter.pointPixelScale)))

        // Enumeration can take time. Recheck authorization and cancellation
        // immediately before asking ScreenCaptureKit for pixels.
        guard await beforeCapture() else {
            throw CaptureError.staleGeneration
        }
        let image = try await captureImage(filter: filter, configuration: configuration)
        return CapturedImage(image: image)
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
