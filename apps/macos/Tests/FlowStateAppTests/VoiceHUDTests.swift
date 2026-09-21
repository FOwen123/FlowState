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
    #expect(abs(view.fittingSize.width - 140) < 1)
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
    #expect(abs(view.fittingSize.width - 140) < 1)
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
