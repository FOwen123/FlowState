import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import FlowStateCore

@Test("visual verification detects a changed window image")
func visualVerificationDetectsChangedPixels() {
    let before = CapturedImage(image: makeTestImage(color: .black))
    let same = CapturedImage(image: makeTestImage(color: .black))
    let after = CapturedImage(image: makeTestImage(color: .white))

    #expect(!before.visuallyDiffers(from: same))
    #expect(before.visuallyDiffers(from: after))
}

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

@Test("capture returns window metadata and a bounded in-memory PNG data URL")
func captureReturnsObservationMetadataAndBoundedPNG() async throws {
    let capturedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let observation = CaptureObservation(
        id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
        bundleIdentifier: "com.example.Reader",
        windowID: 41,
        displayID: 7,
        capturedAt: capturedAt,
        windowFrame: CGRect(x: 12, y: 24, width: 200, height: 100),
        scale: 2,
        security: .clear
    )
    let provider = MetadataCaptureProvider(observation: observation, image: makeLargeTestImage())
    let controller = ScreenCaptureController(provider: provider, now: { capturedAt })
    let grant = await controller.beginTask(allowedBundleIdentifiers: ["com.example.Reader"])

    let result = try await controller.capture(
        bundleIdentifier: "com.example.Reader",
        grant: grant
    )

    #expect(result.observation == observation)
    #expect(result.observation.windowID == 41)
    #expect(result.observation.displayID == 7)
    #expect(result.observation.windowFrame == CGRect(x: 12, y: 24, width: 200, height: 100))
    #expect(result.observation.scale == 2)

    let url = try result.pngDataURL(
        uploadApproved: true,
        maximumDimension: 32,
        maximumBytes: 20_000
    )
    #expect(url.hasPrefix("data:image/png;base64,"))
    #expect(url.utf8.count <= 20_000)
    let encoded = String(url.drop(while: { $0 != "," })).dropFirst()
    let data = try #require(Data(base64Encoded: String(encoded)))
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    #expect(max(image.width, image.height) <= 32)
}

@Test("revalidation rejects a moved or resized window")
func revalidationRejectsGeometryChange() async throws {
    let capturedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let original = testObservation(capturedAt: capturedAt, frame: CGRect(x: 0, y: 0, width: 100, height: 100))
    let changed = testObservation(capturedAt: capturedAt, frame: CGRect(x: 10, y: 0, width: 100, height: 100))
    let provider = RevalidationCaptureProvider(captured: original, current: changed)
    let controller = ScreenCaptureController(provider: provider, now: { capturedAt })
    let grant = await controller.beginTask(allowedBundleIdentifiers: [original.bundleIdentifier])
    let captured = try await controller.capture(bundleIdentifier: original.bundleIdentifier, grant: grant)

    let error = await captureError {
        _ = try await controller.revalidate(captured.observation, grant: grant)
    }
    #expect(error == .windowMoved)
}

@Test("revalidation rejects a closed or replaced window")
func revalidationRejectsClosedOrWrongWindow() async throws {
    let capturedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let original = testObservation(capturedAt: capturedAt)
    let closedProvider = RevalidationCaptureProvider(captured: original, currentError: .windowClosed)
    let closedController = ScreenCaptureController(provider: closedProvider, now: { capturedAt })
    let closedGrant = await closedController.beginTask(allowedBundleIdentifiers: [original.bundleIdentifier])
    let closedCapture = try await closedController.capture(bundleIdentifier: original.bundleIdentifier, grant: closedGrant)
    let closedError = await captureError {
        _ = try await closedController.revalidate(closedCapture.observation, grant: closedGrant)
    }
    #expect(closedError == .windowClosed)

    let replacement = testObservation(capturedAt: capturedAt, windowID: original.windowID + 1)
    let wrongProvider = RevalidationCaptureProvider(captured: original, current: replacement)
    let wrongController = ScreenCaptureController(provider: wrongProvider, now: { capturedAt })
    let wrongGrant = await wrongController.beginTask(allowedBundleIdentifiers: [original.bundleIdentifier])
    let wrongCapture = try await wrongController.capture(bundleIdentifier: original.bundleIdentifier, grant: wrongGrant)
    let wrongError = await captureError {
        _ = try await wrongController.revalidate(wrongCapture.observation, grant: wrongGrant)
    }
    #expect(wrongError == .wrongWindow)
}

@Test("revalidation rejects revocation and cancellation while the provider awaits")
func revalidationRejectsRevocationAndCancellationDuringAwait() async throws {
    let capturedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let original = testObservation(capturedAt: capturedAt)
    let provider = GatedRevalidationCaptureProvider(observation: original)
    let controller = ScreenCaptureController(provider: provider, now: { capturedAt })
    let grant = await controller.beginTask(allowedBundleIdentifiers: [original.bundleIdentifier])
    let captured = try await controller.capture(bundleIdentifier: original.bundleIdentifier, grant: grant)

    let task = Task {
        try await controller.revalidate(captured.observation, grant: grant)
    }
    await provider.waitForRevalidation()
    await controller.revoke()
    await provider.releaseRevalidation()
    let revokedError = await captureError {
        _ = try await task.value
    }
    #expect(revokedError == .staleGeneration)

    let secondProvider = GatedRevalidationCaptureProvider(observation: original)
    let secondController = ScreenCaptureController(provider: secondProvider, now: { capturedAt })
    let secondGrant = await secondController.beginTask(allowedBundleIdentifiers: [original.bundleIdentifier])
    let secondCapture = try await secondController.capture(bundleIdentifier: original.bundleIdentifier, grant: secondGrant)
    let cancelledTask = Task {
        try await secondController.revalidate(secondCapture.observation, grant: secondGrant)
    }
    await secondProvider.waitForRevalidation()
    cancelledTask.cancel()
    await secondProvider.releaseRevalidation()
    let cancelledError = await captureError {
        _ = try await cancelledTask.value
    }
    #expect(cancelledError == .cancelled)
}

@Test("switching capture targets invalidates the previous observation and grant")
func switchingCaptureTargetsInvalidatesPreviousObservationAndGrant() async throws {
    let capturedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let targetA = testObservation(capturedAt: capturedAt)
    let provider = RevalidationCaptureProvider(captured: targetA, current: targetA)
    let controller = ScreenCaptureController(provider: provider, now: { capturedAt })
    let grantA = await controller.beginTask(allowedBundleIdentifiers: [targetA.bundleIdentifier])
    let capturedA = try await controller.capture(
        bundleIdentifier: targetA.bundleIdentifier,
        grant: grantA
    )

    let targetB = "com.example.Writer"
    let grantB = await controller.beginTask(allowedBundleIdentifiers: [targetB])

    let uploadError = await captureError {
        _ = try await controller.revalidate(capturedA.observation, grant: grantA, forUpload: true)
    }
    #expect(uploadError == .staleObservation)

    let captureError = await captureError {
        _ = try await controller.capture(bundleIdentifier: targetA.bundleIdentifier, grant: grantA)
    }
    #expect(captureError == .staleGeneration)
    #expect(grantB.generation != grantA.generation)
}

@Test("restarting an unexpired same-target task reuses its grant and observations")
func restartingSameTargetTaskReusesGrantAndObservations() async throws {
    let capturedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let target = testObservation(capturedAt: capturedAt)
    let provider = RevalidationCaptureProvider(captured: target, current: target)
    let controller = ScreenCaptureController(provider: provider, now: { capturedAt })
    let grant = await controller.beginTask(
        allowedBundleIdentifiers: [target.bundleIdentifier],
        duration: 60
    )
    let captured = try await controller.capture(
        bundleIdentifier: target.bundleIdentifier,
        grant: grant
    )

    let reusedGrant = await controller.beginTask(
        allowedBundleIdentifiers: [target.bundleIdentifier],
        duration: 300
    )

    #expect(reusedGrant == grant)
    #expect(reusedGrant.expiresAt == capturedAt.addingTimeInterval(60))
    try await controller.revalidate(captured.observation, grant: reusedGrant, forUpload: true)
}

@Test("a stale automatic revoke cannot invalidate a newer target grant")
func staleAutomaticRevokeCannotInvalidateNewerTargetGrant() async throws {
    let controller = ScreenCaptureController(provider: ImmediateCaptureProvider())
    let grantA = try await controller.beginAutomaticTask(
        allowedBundleIdentifiers: ["com.example.Reader"],
        lifecycleEpoch: 1
    )
    let grantB = try await controller.beginAutomaticTask(
        allowedBundleIdentifiers: ["com.example.Writer"],
        lifecycleEpoch: 2
    )

    await controller.revoke(lifecycleEpoch: 1)

    _ = try await controller.capture(bundleIdentifier: "com.example.Writer", grant: grantB)
    let staleBeginError = await captureError {
        _ = try await controller.beginAutomaticTask(
            allowedBundleIdentifiers: ["com.example.Reader"],
            lifecycleEpoch: 1
        )
    }
    #expect(staleBeginError == .staleGeneration)
    #expect(grantB.generation != grantA.generation)
}

@Test("a stale automatic begin cannot resurrect capture after revoke")
func staleAutomaticBeginCannotResurrectCaptureAfterRevoke() async throws {
    let controller = ScreenCaptureController(provider: ImmediateCaptureProvider())
    let grant = try await controller.beginAutomaticTask(
        allowedBundleIdentifiers: ["com.example.Reader"],
        lifecycleEpoch: 2
    )
    await controller.revoke(lifecycleEpoch: 2)

    let staleBeginError = await captureError {
        _ = try await controller.beginAutomaticTask(
            allowedBundleIdentifiers: ["com.example.Writer"],
            lifecycleEpoch: 1
        )
    }
    #expect(staleBeginError == .staleGeneration)

    let revokedCaptureError = await captureError {
        _ = try await controller.capture(bundleIdentifier: "com.example.Reader", grant: grant)
    }
    #expect(revokedCaptureError == .staleGeneration)
}

@Test("expired grant is rejected by revalidation using an injected clock")
func revalidationRejectsExpiredGrant() async throws {
    let now = LockedDate(Date(timeIntervalSince1970: 1_700_000_000))
    let observation = testObservation(capturedAt: now.value)
    let provider = RevalidationCaptureProvider(captured: observation, current: observation)
    let controller = ScreenCaptureController(provider: provider, now: { now.value })
    let grant = await controller.beginTask(
        allowedBundleIdentifiers: [observation.bundleIdentifier],
        duration: 10
    )
    let captured = try await controller.capture(bundleIdentifier: observation.bundleIdentifier, grant: grant)
    now.value = now.value.addingTimeInterval(11)

    let error = await captureError {
        _ = try await controller.revalidate(captured.observation, grant: grant)
    }
    #expect(error == .expired)
}

@Test("uncertain or secure content cannot cross the upload boundary")
func uploadBoundaryRejectsUncertainContentAndMissingApproval() async throws {
    let capturedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let uncertain = testObservation(capturedAt: capturedAt)
    let current = CaptureObservation(
        id: uncertain.id,
        bundleIdentifier: uncertain.bundleIdentifier,
        windowID: uncertain.windowID,
        displayID: uncertain.displayID,
        capturedAt: capturedAt,
        windowFrame: uncertain.windowFrame,
        scale: uncertain.scale,
        security: .unknown
    )
    let provider = RevalidationCaptureProvider(captured: uncertain, current: current)
    let controller = ScreenCaptureController(provider: provider, now: { capturedAt })
    let grant = await controller.beginTask(allowedBundleIdentifiers: [uncertain.bundleIdentifier])
    let captured = try await controller.capture(bundleIdentifier: uncertain.bundleIdentifier, grant: grant)

    let missingApproval = await captureError {
        _ = try captured.pngDataURL(uploadApproved: false)
    }
    #expect(missingApproval == .uploadNotApproved)

    let uncertainError = await captureError {
        _ = try await controller.revalidate(captured.observation, grant: grant, forUpload: true)
    }
    #expect(uncertainError == .sensitiveContent)
}

@Test("secure content is rejected by upload revalidation")
func uploadRevalidationRejectsSecureContent() async throws {
    let capturedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let original = testObservation(capturedAt: capturedAt)
    let secure = CaptureObservation(
        id: original.id,
        bundleIdentifier: original.bundleIdentifier,
        windowID: original.windowID,
        displayID: original.displayID,
        capturedAt: capturedAt,
        windowFrame: original.windowFrame,
        scale: original.scale,
        security: .secureContent
    )
    let provider = RevalidationCaptureProvider(captured: original, current: secure)
    let controller = ScreenCaptureController(provider: provider, now: { capturedAt })
    let grant = await controller.beginTask(allowedBundleIdentifiers: [original.bundleIdentifier])
    let captured = try await controller.capture(bundleIdentifier: original.bundleIdentifier, grant: grant)

    let error = await captureError {
        _ = try await controller.revalidate(captured.observation, grant: grant, forUpload: true)
    }
    #expect(error == .sensitiveContent)
}

@Test("legacy captured images default to unknown security and require upload approval")
func legacyCapturedImageFailsClosed() async {
    let captured = CapturedImage(image: makeTestImage())
    #expect(captured.observation.security == .unknown)

    let error = await captureError {
        _ = try captured.pngDataURL()
    }
    #expect(error == .uploadNotApproved)
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

private struct MetadataCaptureProvider: ScreenCaptureProvider {
    let observation: CaptureObservation
    let image: CGImage

    func capture(
        request: CaptureRequest,
        beforeCapture: @escaping @Sendable () async -> Bool
    ) async throws -> CapturedImage {
        guard await beforeCapture() else { throw CaptureError.staleGeneration }
        return CapturedImage(image: image, observation: observation)
    }

    func currentObservation(
        request: CaptureRequest,
        beforeCapture: @escaping @Sendable () async -> Bool
    ) async throws -> CaptureObservation {
        guard await beforeCapture() else { throw CaptureError.staleGeneration }
        return observation
    }
}

private struct RevalidationCaptureProvider: ScreenCaptureProvider {
    let captured: CaptureObservation
    var current: CaptureObservation?
    var currentError: CaptureError?

    init(captured: CaptureObservation, current: CaptureObservation) {
        self.captured = captured
        self.current = current
        self.currentError = nil
    }

    init(captured: CaptureObservation, currentError: CaptureError) {
        self.captured = captured
        self.current = nil
        self.currentError = currentError
    }

    func capture(
        request: CaptureRequest,
        beforeCapture: @escaping @Sendable () async -> Bool
    ) async throws -> CapturedImage {
        guard await beforeCapture() else { throw CaptureError.staleGeneration }
        return CapturedImage(image: makeTestImage(), observation: captured)
    }

    func currentObservation(
        request: CaptureRequest,
        beforeCapture: @escaping @Sendable () async -> Bool
    ) async throws -> CaptureObservation {
        guard await beforeCapture() else { throw CaptureError.staleGeneration }
        if let currentError { throw currentError }
        return current!
    }
}

private actor GatedRevalidationCaptureProvider: ScreenCaptureProvider {
    let observation: CaptureObservation
    private var revalidationStarted = false
    private var revalidationReleased = false

    init(observation: CaptureObservation) {
        self.observation = observation
    }

    func capture(
        request: CaptureRequest,
        beforeCapture: @escaping @Sendable () async -> Bool
    ) async throws -> CapturedImage {
        guard await beforeCapture() else { throw CaptureError.staleGeneration }
        return CapturedImage(image: makeTestImage(), observation: observation)
    }

    func currentObservation(
        request: CaptureRequest,
        beforeCapture: @escaping @Sendable () async -> Bool
    ) async throws -> CaptureObservation {
        revalidationStarted = true
        while !revalidationReleased {
            try await Task.sleep(for: .milliseconds(1))
        }
        guard await beforeCapture() else { throw CaptureError.staleGeneration }
        return observation
    }

    func waitForRevalidation() async {
        while !revalidationStarted {
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    func releaseRevalidation() {
        revalidationReleased = true
    }
}

private func testObservation(
    capturedAt: Date,
    frame: CGRect = CGRect(x: 0, y: 0, width: 100, height: 100),
    windowID: UInt32 = 41
) -> CaptureObservation {
    CaptureObservation(
        id: UUID(),
        bundleIdentifier: "com.example.Reader",
        windowID: windowID,
        displayID: 7,
        capturedAt: capturedAt,
        windowFrame: frame,
        scale: 2,
        security: .clear
    )
}

private final class LockedDate: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ date: Date) {
        self.date = date
    }

    var value: Date {
        get {
            lock.lock()
            defer { lock.unlock() }
            return date
        }
        set {
            lock.lock()
            date = newValue
            lock.unlock()
        }
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

private func makeTestImage(color: CGColor = .clear) -> CGImage {
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
    context.setFillColor(color)
    context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
    return context.makeImage()!
}

private func makeLargeTestImage() -> CGImage {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let width = 200
    let height = 100
    let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(CGColor(red: 0.15, green: 0.35, blue: 0.65, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
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
