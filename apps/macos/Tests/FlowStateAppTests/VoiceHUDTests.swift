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
