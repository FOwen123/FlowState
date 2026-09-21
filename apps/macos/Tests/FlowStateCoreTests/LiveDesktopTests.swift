import AppKit
import ApplicationServices
import Foundation
import Testing
@testable import FlowStateCore

// Opt-in only: opens a disposable TextEdit document and exercises real AX input.
@Test(.enabled(if: ProcessInfo.processInfo.environment["FLOWSTATE_NATIVE_SMOKE"] == "1"))
@MainActor func liveTextEditOpenAndScroll() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("FlowStateSmoke-\(UUID().uuidString).txt")
    let original = "FlowState disposable native test / 測試文件\n" + (1...200).map { "Line \($0) / 第 \($0) 行" }.joined(separator: "\n")
    try original.write(to: url, atomically: true, encoding: .utf8)
    let appURL = try #require(NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit"))
    let openedApp = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NSRunningApplication, Error>) in
        NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration()) { app, error in
            if let error { continuation.resume(throwing: error) } else if let app { continuation.resume(returning: app) } else { continuation.resume(throwing: DesktopExecutionError.applicationNotFound("com.apple.TextEdit")) }
        }
    }
    _ = openedApp // The controller below must activate TextEdit itself.
    if let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first {
        let finderElement = AXUIElementCreateApplication(finder.processIdentifier)
        _ = AXUIElementSetAttributeValue(finderElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    }
    try #require(AXIsProcessTrusted(), "The test runner needs Accessibility permission independently of the app")
    let driver = AXDesktopDriver()
    let controller = DesktopAutomationController(driver: driver)
    try await controller.begin(grant: DesktopExecutionGrant(allowedBundleIdentifiers: ["com.apple.TextEdit"], allowedActions: [.openApplication, .scroll, .press], generation: 1, expiresAt: Date().addingTimeInterval(30)))
    _ = try await controller.execute(.openApplication(bundleIdentifier: "com.apple.TextEdit"), expectedBundleIdentifier: "com.apple.TextEdit")
    var ready = false
    var lastObservation: DesktopObservation?
    var observationError: String?
    for _ in 0..<50 {
        do { lastObservation = try await driver.observe() } catch { observationError = error.localizedDescription }
        if let observation = lastObservation, observation.bundleIdentifier == "com.apple.TextEdit", observation.value == original {
            ready = true
            break
        }
        try await Task.sleep(for: .milliseconds(100))
    }
    if !ready { print("Fixture focus unavailable: app=\(lastObservation?.bundleIdentifier ?? "none"), focused=\(lastObservation?.focusedElementID != nil), valueLength=\(lastObservation?.value?.count ?? -1), error=\(observationError ?? "none")") }
    try #require(ready, "Refuse live input unless the focused text is exactly our disposable fixture")
    print("Live fixture: testing select-all")
    _ = try await controller.execute(.press(key: "A", modifiers: "Command"), expectedBundleIdentifier: "com.apple.TextEdit")
    #expect(try await driver.observe().selectedTextRange == DesktopTextRange(location: 0, length: (original as NSString).length))
    print("Live fixture: testing arrow key")
    _ = try await controller.execute(.press(key: "ArrowRight", modifiers: nil), expectedBundleIdentifier: "com.apple.TextEdit")
    #expect(try await driver.observe().selectedTextRange?.length == 0)
    print("Live fixture: testing scroll")
    let appElement = AXUIElementCreateApplication(openedApp.processIdentifier)
    let window = try #require(liveAttribute(appElement, kAXFocusedWindowAttribute) as! AXUIElement?)
    let scrollbar = try #require(liveVerticalScrollbar(window), "Disposable document must expose a vertical scrollbar")
    let beforeScroll = try #require(liveAttribute(scrollbar, kAXValueAttribute) as? NSNumber).doubleValue
    _ = try await controller.execute(.scroll(lines: beforeScroll > 0.5 ? 5 : -5), expectedBundleIdentifier: "com.apple.TextEdit")
    var scrollChanged = false
    for _ in 0..<20 {
        if let latest = liveVerticalScrollbar(window), let value = liveAttribute(latest, kAXValueAttribute) as? NSNumber, value.doubleValue != beforeScroll { scrollChanged = true; break }
        try await Task.sleep(for: .milliseconds(50))
    }
    #expect(scrollChanged, "Scroll must change the approved document's visible position")
    if ProcessInfo.processInfo.environment["FLOWSTATE_CAPTURE_SMOKE"] == "1" {
        // Only the exact synthetic fixture above may be captured. No upload or file output.
        try #require(try await driver.observe().value == original)
        let capture = ScreenCaptureController()
        let captureGrant = await capture.beginTask(allowedBundleIdentifiers: ["com.apple.TextEdit"])
        let frame = try await capture.capture(bundleIdentifier: "com.apple.TextEdit", grant: captureGrant)
        try await capture.revalidate(frame.observation, grant: captureGrant, forUpload: true)
        #expect(frame.observation.bundleIdentifier == "com.apple.TextEdit")
        #expect(frame.observation.windowID != 0)
        #expect(frame.observation.uploadSafe)
        #expect(try frame.pngDataURL(uploadApproved: true).utf8.count <= CaptureImageBounds.defaultMaximumBytes)
        await capture.revoke()
        print("Synthetic TextEdit window capture, geometry revalidation and bounded in-memory encoding passed; no upload.")
    }
    // Leave the test document open for inspection; never close an unrelated document.
    print("Live TextEdit activation, select-all, arrow key and scrolling passed.")
}

private func liveAttribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}
private func liveVerticalScrollbar(_ root: AXUIElement) -> AXUIElement? {
    var queue = [root]
    var inspected = 0
    while !queue.isEmpty, inspected < 200 {
        let element = queue.removeFirst(); inspected += 1
        if liveAttribute(element, kAXRoleAttribute) as? String == kAXScrollBarRole,
           liveAttribute(element, kAXOrientationAttribute) as? String == kAXVerticalOrientationValue { return element }
        if let children = liveAttribute(element, kAXChildrenAttribute) as? [AXUIElement] { queue.append(contentsOf: children) }
    }
    return nil
}
