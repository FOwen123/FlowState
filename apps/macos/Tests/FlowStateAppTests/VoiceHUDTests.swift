import AppKit
import SwiftUI
import Testing
@testable import FlowStateApp

@Test("voice feedback grows to show the complete recovery message")
@MainActor func voiceFeedbackDoesNotTruncateRecovery() {
    let model = VoiceHUDModel()
    model.status = "Choose an app and grant desktop control in Tasks & history before using commands. " + String(repeating: "Check your setup before trying again. ", count: 8)
    let view = NSHostingView(rootView: VoiceHUDView(model: model))
    #expect(view.fittingSize.height > 156)
}

@Test("ordinary listening uses a minimal waveform strip")
@MainActor func listeningUsesCompactStrip() {
    let model = VoiceHUDModel()
    model.isListening = true
    model.status = "Listening — say a command or press Stop"
    model.transcript = "Open Brave."
    model.lastResponse = "Previous task completed."
    let view = NSHostingView(rootView: VoiceHUDView(model: model))
    #expect(abs(view.fittingSize.width - 280) < 1)
    #expect(abs(view.fittingSize.height - 56) < 1)
}

@Test("listening stays minimal even with a long transcript")
@MainActor func longTranscriptRemainsReadable() {
    let model = VoiceHUDModel()
    model.isListening = true
    model.status = "Listening — say a command or press Stop"
    model.transcript = String(repeating: "A sentence that should stay readable. ", count: 8)
    let view = NSHostingView(rootView: VoiceHUDView(model: model))
    #expect(abs(view.fittingSize.height - 56) < 1)
    #expect(abs(view.fittingSize.width - 280) < 1)
}

@Test("the session menu stays a compact native list")
@MainActor func sessionMenuIsCompact() {
    let view = NSHostingView(rootView: FlowStateMenuView(model: FlowStateAppModel()))
    #expect(abs(view.fittingSize.width - 280) < 1)
    #expect(view.fittingSize.height <= 140)
}

@Test("a short recovery message has no settings toolbar taking up space")
@MainActor func recoveryPanelIsCompact() {
    let model = VoiceHUDModel()
    model.status = "The focused control is not editable."
    let view = NSHostingView(rootView: VoiceHUDView(model: model))
    #expect(view.fittingSize.height <= 120)
}

@Test("recovery feedback has a dark opaque surface")
@MainActor func recoverySurfaceStaysReadable() throws {
    let model = VoiceHUDModel()
    model.status = "The focused control is not editable."
    let renderer = ImageRenderer(content: VoiceHUDView(model: model))
    renderer.scale = 2
    let raster = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
    let surface = try #require(raster.colorAt(x: raster.pixelsWide / 2, y: 12)?.usingColorSpace(.deviceRGB))
    #expect(surface.alphaComponent > 0.95)
    #expect(max(surface.redComponent, surface.greenComponent, surface.blueComponent) < 0.2)
    if let path = ProcessInfo.processInfo.environment["FLOWSTATE_HUD_PREVIEW"] {
        try raster.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}

@Test("feedback ignores transcript length")
@MainActor func feedbackDoesNotRepeatDictation() {
    let model = VoiceHUDModel()
    model.status = "Done"
    let before = NSHostingView(rootView: VoiceHUDView(model: model)).fittingSize
    model.transcript = String(repeating: "Words the user dictated. ", count: 100)
    let after = NSHostingView(rootView: VoiceHUDView(model: model)).fittingSize
    #expect(before == after)
}

@Test("feedback expands upward without moving the waveform anchor")
@MainActor func feedbackAnchorIsStable() {
    let screen = NSRect(x: 100, y: 50, width: 1440, height: 900)
    let listening = VoiceHUDController.frame(size: NSSize(width: 280, height: 56), visibleFrame: screen)
    let feedback = VoiceHUDController.frame(size: NSSize(width: 280, height: 180), visibleFrame: screen)
    #expect(listening.minX == feedback.minX)
    #expect(listening.minY == feedback.minY)
    #expect(listening.midX == screen.midX)
}

@Test("the waveform fills the listening bar instead of leaving an empty center")
@MainActor func waveformFillsListeningBar() throws {
    let model = VoiceHUDModel()
    model.isListening = true
    model.status = "Listening — say a command or press Stop"
    let renderer = ImageRenderer(content: VoiceHUDView(model: model))
    renderer.scale = 1
    let raster = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
    let brightColumns = (12..<220).filter { x in
        (10..<46).contains { y in
            guard let pixel = raster.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
            return min(pixel.redComponent, pixel.greenComponent, pixel.blueComponent) > 0.8
        }
    }
    #expect(brightColumns.count >= 60)
    if let path = ProcessInfo.processInfo.environment["FLOWSTATE_WAVE_PREVIEW"] {
        try raster.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}

@Test("no-speech feedback grows gradually above the existing bar", .enabled(if: ProcessInfo.processInfo.environment["FLOWSTATE_HUD_MOTION_SMOKE"] == "1"))
@MainActor func noSpeechFeedbackAnimates() async throws {
    let existing = Set(NSApplication.shared.windows.map(\.windowNumber))
    let controller = VoiceHUDController()
    controller.show(status: "Listening — say a command or press Stop", transcript: "", isListening: true, onStop: {})
    defer { controller.hide() }
    let panel = try #require(NSApplication.shared.windows.first { !existing.contains($0.windowNumber) && $0.isVisible })
    let initial = panel.frame
    controller.show(status: "No speech detected. Try again.", transcript: "", isListening: false, onStop: {})
    #expect(abs(panel.frame.height - initial.height) < 1)
    try await Task.sleep(for: .milliseconds(150))
    let intermediate = panel.frame
    try await Task.sleep(for: .milliseconds(350))
    #expect(intermediate.height >= initial.height)
    #expect(intermediate.height <= panel.frame.height)
    #expect(panel.frame.height > initial.height)
    #expect(panel.frame.minY == initial.minY)
    #expect(panel.frame.midX == initial.midX)
    controller.show(status: "Listening — say a command or press Stop", transcript: "", isListening: true, onStop: {})
    try await Task.sleep(for: .milliseconds(450))
    #expect(panel.frame == initial)
}
