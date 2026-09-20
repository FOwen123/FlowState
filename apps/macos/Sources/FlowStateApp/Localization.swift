import AppKit
import Foundation
import FlowStateCore
import SwiftUI

enum InterfaceLanguage: String, CaseIterable, Sendable {
    case system
    case english = "en"
    case traditionalChinese = "zh-Hant"

    static let defaultsKey = "FlowState.interfaceLanguage"
    static func resolve(_ selection: Self, preferredLanguages: [String] = Locale.preferredLanguages) -> Self {
        guard selection == .system else { return selection }
        return preferredLanguages.first?.lowercased().hasPrefix("zh") == true ? .traditionalChinese : .english
    }
    var displayName: String {
        switch self {
        case .system: L10n.text("Use system language")
        case .english: "English"
        case .traditionalChinese: "繁體中文"
        }
    }
}

@MainActor
final class UILocalization: ObservableObject {
    static let shared = UILocalization()
    private let defaults: UserDefaults
    @Published var language: InterfaceLanguage {
        didSet { defaults.set(language.rawValue, forKey: InterfaceLanguage.defaultsKey) }
    }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        language = InterfaceLanguage(rawValue: defaults.string(forKey: InterfaceLanguage.defaultsKey) ?? "system") ?? .system
    }
}

enum L10n {
    static func appName(_ bundleIdentifier: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return text("Selected app")
        }
        return FileManager.default.displayName(atPath: url.path)
    }

    static func planSummary(_ parameters: NativePlanParameters, appName: String, language selection: InterfaceLanguage? = nil) -> String {
        let locale = Locale(identifier: (selection ?? language).rawValue)
        switch parameters {
        case .openApplication:
            return String(format: text("Open %@", language: selection), locale: locale, appName)
        case let .scroll(lines):
            let key = lines < 0 ? "Scroll down %d lines in %@" : "Scroll up %d lines in %@"
            return String(format: text(key, language: selection), locale: locale, Int64(lines).magnitude, appName)
        case let .insertText(value, _):
            return String(format: text("Insert text into %@: %@", language: selection), locale: locale, appName, value)
        }
    }

    static func actionName(_ action: DesktopActionKind) -> String {
        switch action {
        case .openApplication: text("Open app")
        case .scroll: text("Scroll")
        case .focus: text("Focus")
        case .select: text("Select")
        case .press: text("Press")
        case .insertText: text("Insert text")
        }
    }

    static var language: InterfaceLanguage {
        InterfaceLanguage.resolve(InterfaceLanguage(rawValue: UserDefaults.standard.string(forKey: InterfaceLanguage.defaultsKey) ?? "system") ?? .system)
    }
    static func text(_ key: String, table: String = "Localizable", language selection: InterfaceLanguage? = nil) -> String {
        let language = InterfaceLanguage.resolve(selection ?? language)
        guard let url = Bundle.module.url(forResource: language.rawValue, withExtension: "lproj"),
              let bundle = Bundle(url: url) else { return key }
        return bundle.localizedString(forKey: key, value: key, table: table)
    }
    static func format(_ key: String, _ arguments: CVarArg..., table: String = "Localizable") -> String {
        String(format: text(key, table: table), locale: Locale(identifier: language.rawValue), arguments: arguments)
    }
}
