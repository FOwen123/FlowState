import Foundation
import FlowStateCore
import Testing
@testable import FlowStateApp

@Test @MainActor func legacyInterfaceLanguageMigratesWithoutChangingUserData() throws {
    let name = "FlowState.LocalizationTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    defaults.set("zh-Hant", forKey: InterfaceLanguage.defaultsKey)
    defaults.set("你好 — draft", forKey: "draft")
    let settings = UILocalization(defaults: defaults)
    #expect(settings.language == .english)
    #expect(defaults.string(forKey: InterfaceLanguage.defaultsKey) == "en")
    #expect(defaults.string(forKey: "draft") == "你好 — draft")
    #expect(L10n.text("account.signed_out.title", table: "Account") == "Sign in to Flow State")
}

@Test func englishPlanSummaryPreservesUnicodeAndFormatCharacters() {
    let literal = "Hello / 你好 — 100% %@"
    #expect(L10n.planSummary(.insertText(text: literal, replaceSelection: false), appName: "TextEdit") == "Insert text into TextEdit: " + literal)
}
