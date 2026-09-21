import AppKit
import SwiftUI
import Testing
@testable import FlowStateApp

@Test("settings navigation follows the Paper screen order")
func settingsNavigationFollowsPaperOrder() {
    #expect(FlowStateSettingsSection.allCases.map(\.title) == ["Account", "General", "Models", "History", "Memory", "Permissions"])
}

@Test("models settings distinguishes the active engine from the planned download")
func modelsSettingsDistinguishesAvailableEngines() {
    #expect(SettingsSpeechModel.allCases.map(\.title) == ["Apple Speech", "Parakeet Unified English"])
    #expect(SettingsSpeechModel.appleSpeech.isSelected)
    #expect(!SettingsSpeechModel.parakeet.isSelected)
    #expect(SettingsSpeechModel.parakeet.source == "Hugging Face")
}

@Test("models settings uses status dedicated to speech assets")
@MainActor func modelsSettingsUsesDedicatedSpeechAssetStatus() {
    let model = FlowStateAppModel()
    #expect(model.speechModelStatus == "Apple Speech is selected")
}

@Test("personal mail keeps a readable message editor")
@MainActor func personalMailKeepsReadableMessageEditor() {
    let view = NSHostingView(rootView: PersonalMailView())
    #expect(view.fittingSize.width >= 640)
    #expect(view.fittingSize.height >= 480)
}
