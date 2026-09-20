import CoreGraphics
import Foundation
import ImageIO

/// The result of a conservative Accessibility scan performed for an approved
/// window. An unknown result is allowed for local context, but never for a
/// PNG data URL intended to leave the Mac.
public enum CaptureSecurity: Equatable, Sendable {
    case clear
    case secureContent
    case unknown
}

/// The screen geometry attached to one in-memory capture.
public struct CaptureObservation: Equatable, Sendable {
    public let id: UUID
    public let bundleIdentifier: String
    public let windowID: UInt32
    public let displayID: UInt32
    public let capturedAt: Date
    public let windowFrame: CGRect
    public let scale: CGFloat
    public let security: CaptureSecurity

    public var frame: CGRect { windowFrame }
    public var windowId: UInt32 { windowID }
    public var displayId: UInt32 { displayID }
    public var observedAt: Date { capturedAt }
    public var secureContentDetected: Bool { security == .secureContent }
    public var uploadSafe: Bool { security == .clear }

    public init(
        id: UUID = UUID(),
        bundleIdentifier: String,
        windowID: UInt32,
        displayID: UInt32,
        capturedAt: Date,
        windowFrame: CGRect,
        scale: CGFloat,
        security: CaptureSecurity = .unknown
    ) {
        self.id = id
        self.bundleIdentifier = bundleIdentifier
        self.windowID = windowID
        self.displayID = displayID
        self.capturedAt = capturedAt
        self.windowFrame = windowFrame
        self.scale = scale
        self.security = security
    }
}

public enum CaptureImageBounds {
    public static let defaultMaximumDimension = 2_048
    public static let defaultMaximumBytes = 512 * 1_024
}

public extension CapturedImage {
    /// Encodes a bounded PNG data URL in memory. No file URL is created or
    /// written. Callers must pass their explicit upload grant at this boundary.
    func pngDataURL(
        uploadApproved: Bool = false,
        maximumDimension: Int = CaptureImageBounds.defaultMaximumDimension,
        maximumBytes: Int = CaptureImageBounds.defaultMaximumBytes
    ) throws -> String {
        guard uploadApproved else { throw CaptureError.uploadNotApproved }
        guard observation.uploadSafe else { throw CaptureError.sensitiveContent }
        guard maximumDimension > 0, maximumBytes > 0 else {
            throw CaptureError.invalidImageBounds
        }

        let sourceWidth = image.width
        let sourceHeight = image.height
        guard sourceWidth > 0, sourceHeight > 0 else {
            throw CaptureError.invalidImageBounds
        }

        let largestSide = max(sourceWidth, sourceHeight)
        let initialScale = min(1, Double(maximumDimension) / Double(largestSide))
        var width = max(1, Int((Double(sourceWidth) * initialScale).rounded(.down)))
        var height = max(1, Int((Double(sourceHeight) * initialScale).rounded(.down)))

        for _ in 0..<32 {
            guard let resized = resizedImage(width: width, height: height),
                  let png = pngData(for: resized)
            else { throw CaptureError.imageEncodingFailed }

            let dataURL = "data:image/png;base64,\(png.base64EncodedString())"
            if dataURL.utf8.count <= maximumBytes {
                return dataURL
            }

            let ratio = sqrt(Double(maximumBytes) / Double(max(dataURL.utf8.count, 1)))
            let nextWidth = max(1, Int((Double(width) * min(0.8, max(0.1, ratio))).rounded(.down)))
            let nextHeight = max(1, Int((Double(height) * min(0.8, max(0.1, ratio))).rounded(.down)))
            guard nextWidth < width || nextHeight < height else {
                throw CaptureError.imageTooLarge
            }
            width = nextWidth
            height = nextHeight
        }

        throw CaptureError.imageTooLarge
    }

    private func resizedImage(width: Int, height: Int) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private func pngData(for image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData,
            "public.png" as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
