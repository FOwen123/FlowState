import AppKit
import SwiftUI
import Testing
@testable import FlowStateApp

@Test("settings navigation follows the Paper screen order")
func settingsNavigationFollowsPaperOrder() {
    #expect(FlowStateSettingsSection.allCases.map(\.title) == ["General", "Models", "History", "Memory", "Permissions", "Account"])
}

@Test("personal mail keeps a readable message editor")
@MainActor func personalMailKeepsReadableMessageEditor() {
    let view = NSHostingView(rootView: PersonalMailView())
    #expect(view.fittingSize.width >= 640)
    #expect(view.fittingSize.height >= 480)
}
