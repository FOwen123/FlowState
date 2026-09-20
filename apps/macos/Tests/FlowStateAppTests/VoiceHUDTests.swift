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
