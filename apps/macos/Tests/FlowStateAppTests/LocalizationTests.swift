import Foundation
import FlowStateCore
import Testing
@testable import FlowStateApp

@Test func interfaceLanguageIsIndependentAndUsesTraditionalChinese() throws {
    #expect(InterfaceLanguage.resolve(.system, preferredLanguages: ["zh-TW", "en"]) == .traditionalChinese)
    #expect(InterfaceLanguage.resolve(.system, preferredLanguages: ["id", "en"]) == .english)
    #expect(InterfaceLanguage.resolve(.english, preferredLanguages: ["zh-TW"]) == .english)
    #expect(L10n.text("Account", language: .english) == "Account")
    #expect(L10n.text("Account", language: .traditionalChinese) == "帳戶")
    #expect(L10n.text("account.signed_out.title", table: "Account", language: .traditionalChinese) == "登入 Flow State")
    #expect(L10n.text("untranslated fallback", language: .traditionalChinese) == "untranslated fallback")
}

@Test @MainActor func interfaceLanguagePersistsSeparatelyFromSpeechSettings() throws {
    let name = "FlowState.LocalizationTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    defaults.set("en-US", forKey: "speechLanguage")
    let settings = UILocalization(defaults: defaults)
    settings.language = .traditionalChinese
    #expect(UILocalization(defaults: defaults).language == .traditionalChinese)
    #expect(defaults.string(forKey: "speechLanguage") == "en-US")
}

@Test func nativeCatalogsHaveMatchingKeysAndFormatArguments() throws {
    func catalog(_ language: String) throws -> [String: String] {
        let url = try #require(Bundle.module.url(forResource: "Localizable", withExtension: "strings", subdirectory: "\(language).lproj"))
        return try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: String])
    }
    let english = try catalog("en")
    let chinese = try catalog("zh-Hant")
    #expect(Set(english.keys) == Set(chinese.keys))
    let placeholders = try NSRegularExpression(pattern: #"%(?:\d+\$)?[@diuf]"#)
    for (key, value) in english {
        let translated = try #require(chinese[key])
        func arguments(_ string: String) -> [String] {
            placeholders.matches(in: string, range: NSRange(string.startIndex..., in: string)).compactMap {
                Range($0.range, in: string).map { String(string[$0]) }
            }
        }
        #expect(arguments(value) == arguments(translated), "Mismatched format arguments: \(key)")
        #expect(!translated.contains(" / "), "Combined-language copy: \(key)")
    }
}

@Test func translatedPlanSummaryPreservesExactDictatedText() {
    let literal = "Hello / 你好 — 100% %@"
    #expect(L10n.planSummary(.insertText(text: literal, replaceSelection: false), appName: "TextEdit", language: .traditionalChinese) == "在 TextEdit 輸入文字：" + literal)
    #expect(L10n.planSummary(.scroll(lines: -3), appName: "Brave", language: .traditionalChinese) == "向下捲動 3 行（Brave）")
}
