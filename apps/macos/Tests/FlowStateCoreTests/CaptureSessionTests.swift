import CoreGraphics
import Foundation
import Testing
@testable import FlowStateCore

@Test("capture is denied while no task is active")
func captureIsDeniedWhileIdle() async {
    let controller = ScreenCaptureController(provider: ImmediateCaptureProvider())
    let grant = CaptureGrant(
        allowedBundleIdentifiers: ["com.example.Reader"],
        generation: 0,
        expiresAt: Date().addingTimeInterval(60)
    )

    let error = await captureError {
        _ = try await controller.capture(
            bundleIdentifier: "com.example.Reader",
            grant: grant
        )
    }
    #expect(error == .inactive)
}

@Test("capture is denied for an unapproved application")
func captureIsDeniedForUnapprovedApplication() async {
    let controller = ScreenCaptureController(provider: ImmediateCaptureProvider())
    let grant = await controller.beginTask(allowedBundleIdentifiers: ["com.example.Reader"])

    let error = await captureError {
        _ = try await controller.capture(
            bundleIdentifier: "com.example.Other",
            grant: grant
        )
    }
    #expect(error == .appNotApproved("com.example.Other"))
}

@Test("sensitive application identifiers fail closed")
func sensitiveApplicationsAreExcluded() async {
    let controller = ScreenCaptureController(provider: ImmediateCaptureProvider())
    let grant = await controller.beginTask(allowedBundleIdentifiers: ["com.apple.keychainaccess"])

    let error = await captureError {
        _ = try await controller.capture(
            bundleIdentifier: "com.apple.keychainaccess",
            grant: grant
        )
    }
    #expect(error == .sensitiveAppExcluded("com.apple.keychainaccess"))
}

@Test("task grants expire by default")
func taskGrantsHaveFiniteDefaultExpiry() async {
    let controller = ScreenCaptureController(provider: ImmediateCaptureProvider())
    let before = Date()
    let grant = await controller.beginTask(allowedBundleIdentifiers: ["com.example.Reader"])

    #expect(grant.expiresAt > before)
    #expect(grant.expiresAt <= before.addingTimeInterval(CaptureGrant.defaultDuration + 1))
}

@Test("expired task grants cannot capture")
func expiredTaskGrantsAreRejected() async throws {
    let controller = ScreenCaptureController(provider: ImmediateCaptureProvider())
    let grant = await controller.beginTask(
        allowedBundleIdentifiers: ["com.example.Reader"],
        duration: 0.01
    )
    try await Task.sleep(for: .milliseconds(50))

    let error = await captureError {
        _ = try await controller.capture(
            bundleIdentifier: "com.example.Reader",
            grant: grant
        )
    }
    #expect(error == .expired)
}

@Test("revoking during window enumeration prevents the screenshot")
func revokeBeforeScreenshotIsRechecked() async {
    let provider = GatedCaptureProvider()
    let controller = ScreenCaptureController(provider: provider)
    let grant = await controller.beginTask(allowedBundleIdentifiers: ["com.example.Reader"])
    let task = Task {
        try await controller.capture(bundleIdentifier: "com.example.Reader", grant: grant)
    }

    await provider.waitForEnumeration()
    await controller.revoke()
    await provider.releaseEnumeration()

    let error = await captureError {
        _ = try await task.value
    }
    #expect(error == .staleGeneration)
    #expect(await provider.didStartScreenshot() == false)
}

@Test("a late provider result is rejected by final actor validation")
func lateProviderResultIsRejected() async {
    let provider = LateResultCaptureProvider()
    let controller = ScreenCaptureController(provider: provider)
    let grant = await controller.beginTask(allowedBundleIdentifiers: ["com.example.Reader"])
    let task = Task {
        try await controller.capture(bundleIdentifier: "com.example.Reader", grant: grant)
    }

    await provider.waitForScreenshotStart()
    await controller.revoke()
    await provider.releaseResult()

    let error = await captureError {
        _ = try await task.value
    }
    #expect(error == .staleGeneration)
}

private struct ImmediateCaptureProvider: ScreenCaptureProvider {
    func capture(
        request: CaptureRequest,
        beforeCapture: @escaping @Sendable () async -> Bool
    ) async throws -> CapturedImage {
        guard await beforeCapture() else {
            throw CaptureError.staleGeneration
        }
        return CapturedImage(image: makeTestImage())
    }
}

private actor GatedCaptureProvider: ScreenCaptureProvider {
    private var enumerated = false
    private var enumerationReleased = false
    private var screenshotStarted = false

    func capture(
        request: CaptureRequest,
        beforeCapture: @escaping @Sendable () async -> Bool
    ) async throws -> CapturedImage {
        enumerated = true
        while !enumerationReleased {
            try await Task.sleep(for: .milliseconds(1))
        }
        guard await beforeCapture() else {
            throw CaptureError.staleGeneration
        }
        screenshotStarted = true
        return CapturedImage(image: makeTestImage())
    }

    func waitForEnumeration() async {
        while !enumerated {
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    func releaseEnumeration() {
        enumerationReleased = true
    }

    func didStartScreenshot() -> Bool {
        screenshotStarted
    }
}

private actor LateResultCaptureProvider: ScreenCaptureProvider {
    private var screenshotStarted = false
    private var resultReleased = false

    func capture(
        request: CaptureRequest,
        beforeCapture: @escaping @Sendable () async -> Bool
    ) async throws -> CapturedImage {
        guard await beforeCapture() else {
            throw CaptureError.staleGeneration
        }
        screenshotStarted = true
        while !resultReleased {
            try await Task.sleep(for: .milliseconds(1))
        }
        return CapturedImage(image: makeTestImage())
    }

    func waitForScreenshotStart() async {
        while !screenshotStarted {
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    func releaseResult() {
        resultReleased = true
    }
}

private func makeTestImage() -> CGImage {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(
        data: nil,
        width: 1,
        height: 1,
        bitsPerComponent: 8,
        bytesPerRow: 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    return context.makeImage()!
}

private func captureError(
    _ operation: () async throws -> Void
) async -> CaptureError? {
    do {
        _ = try await operation()
        return nil
    } catch let error as CaptureError {
        return error
    } catch {
        return nil
    }
}
