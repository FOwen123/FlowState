import AppKit
import Foundation
import FlowStateCore
import SwiftUI

enum InterfaceLanguage: String, Sendable {
    case english = "en"
    static let defaultsKey = "FlowState.interfaceLanguage"
    static func resolve(_ selection: Self) -> Self { .english }
}

@MainActor
final class UILocalization: ObservableObject {
    static let shared = UILocalization()
    let language = InterfaceLanguage.english
    init(defaults: UserDefaults = .standard) {
        defaults.set("en", forKey: InterfaceLanguage.defaultsKey)
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
        case let .focus(role, label):
            return "Focus \(label ?? role) in \(appName)"
        case let .select(label):
            return "Select \(label) in \(appName)"
        case let .press(key, modifiers):
            return "Press \(modifiers.map { $0 + "–" } ?? "")\(key) in \(appName)"
        case let .click(label):
            return "Click \(label) in \(appName)"
        case let .openURL(url):
            return "Open URL \(url)"
        case let .attachFile(fileID):
            return "Attach approved file \(fileID)"
        case let .sendEmail(recipient, subject, _):
            return "Send email to \(recipient): \(subject)"
        case let .draftMessage(recipient, subject, _):
            return "Draft email to \(recipient): \(subject)"
        }
    }

    static func actionName(_ action: DesktopActionKind) -> String {
        switch action {
        case .openApplication: text("Open app")
        case .scroll: text("Scroll")
        case .focus: text("Focus")
        case .select: text("Select")
        case .press: text("Press")
        case .click: text("Click")
        case .insertText: text("Insert text")
        }
    }

    static let language = InterfaceLanguage.english
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
