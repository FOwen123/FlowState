import AppKit
import Foundation
import FlowStateCore

struct ApplicationRegistryEntry: Codable, Equatable, Identifiable, Sendable {
    let bundleIdentifier: String
    let displayName: String
    let aliases: [String]
    let normalizedNames: [String]
    let isRunning: Bool
    let supportedActions: Set<DesktopActionKind>
    let integrations: Set<String>

    var id: String { bundleIdentifier }

    init(
        bundleIdentifier: String,
        displayName: String,
        aliases: [String] = [],
        isRunning: Bool = false,
        supportedActions: Set<DesktopActionKind> = [.openApplication],
        integrations: Set<String> = []
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        let names = [displayName, bundleIdentifier] + aliases
        let normalized = names.map(ApplicationRegistry.normalize).filter { !$0.isEmpty }
        self.aliases = aliases.map(ApplicationRegistry.normalize).filter { !$0.isEmpty }
        var uniqueNames: [String] = []
        for name in normalized where !uniqueNames.contains(name) {
            uniqueNames.append(name)
        }
        self.normalizedNames = uniqueNames
        self.isRunning = isRunning
        self.supportedActions = supportedActions.intersection(Set(DesktopActionKind.allCases))
        self.integrations = integrations
    }

    func supports(_ action: DesktopActionKind) -> Bool {
        supportedActions.contains(action)
    }
}

enum ApplicationResolution: Equatable, Sendable {
    case resolved(ApplicationRegistryEntry)
    case ambiguous([ApplicationRegistryEntry])
    case unknown
}

enum RegisteredApplicationCommandResolution: Equatable, Sendable {
    case notAnApplicationCommand
    case resolved(ApplicationRegistryEntry)
    case ambiguous([ApplicationRegistryEntry])
    case unknown(String)
}

struct ApplicationRegistry: Sendable {
    static let defaultCandidateLimit = 99
    static let aliasesDefaultsKey = "FlowState.applicationAliases"

    let entries: [ApplicationRegistryEntry]

    init(entries: [ApplicationRegistryEntry]) {
        var byBundle: [String: ApplicationRegistryEntry] = [:]
        for entry in entries {
            guard !entry.bundleIdentifier.isEmpty else { continue }
            if let existing = byBundle[entry.bundleIdentifier] {
                byBundle[entry.bundleIdentifier] = Self.merge(existing, entry)
            } else {
                byBundle[entry.bundleIdentifier] = entry
            }
        }
        self.entries = byBundle.values.sorted { lhs, rhs in
            lhs.bundleIdentifier.localizedStandardCompare(rhs.bundleIdentifier) == .orderedAscending
        }
    }

    func resolve(_ query: String) -> ApplicationResolution {
        let normalizedQuery = Self.normalize(query)
        guard !normalizedQuery.isEmpty else { return .unknown }
        let matches = entries.filter { $0.normalizedNames.contains(normalizedQuery) }
        switch matches.count {
        case 0: return .unknown
        case 1: return .resolved(matches[0])
        default: return .ambiguous(matches.sorted(by: Self.bundleOrder))
        }
    }

    func resolveApplicationCommand(_ transcript: String) -> RegisteredApplicationCommandResolution {
        let normalized = Self.normalize(transcript)
        let prefixes = ["open ", "switch to ", "switch ", "launch ", "start "]
        guard let prefix = prefixes.first(where: { normalized.hasPrefix($0) }) else {
            return .notAnApplicationCommand
        }
        let query = String(normalized.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return .unknown(query) }
        switch resolve(query) {
        case let .resolved(entry): return .resolved(entry)
        case let .ambiguous(entries): return .ambiguous(entries)
        case .unknown: return .unknown(query)
        }
    }

    func candidates(for query: String, limit: Int = ApplicationRegistry.defaultCandidateLimit) -> [ApplicationRegistryEntry] {
        let boundedLimit = min(max(limit, 1), Self.defaultCandidateLimit)
        let normalizedQuery = Self.normalize(query)
        let queryTokens = normalizedQuery.split(separator: " ").map(String.init).filter { $0.count > 1 }
        guard !normalizedQuery.isEmpty else { return Array(entries.prefix(boundedLimit)) }

        return entries
            .filter { entry in
                entry.normalizedNames.contains { name in
                    name == normalizedQuery || name.hasPrefix(normalizedQuery) || name.contains(normalizedQuery)
                        || queryTokens.contains(where: { name.contains($0) })
                }
            }
            .sorted { lhs, rhs in
                let leftScore = Self.matchScore(lhs, query: normalizedQuery)
                let rightScore = Self.matchScore(rhs, query: normalizedQuery)
                if leftScore != rightScore { return leftScore < rightScore }
                return Self.bundleOrder(lhs, rhs)
            }
            .prefix(boundedLimit)
            .map { $0 }
    }

    @MainActor
    static func installed(defaults: UserDefaults = .standard) -> ApplicationRegistry {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let aliases = (defaults.dictionary(forKey: aliasesDefaultsKey) as? [String: [String]]) ?? [:]
        let catalog = ApplicationCatalog.installed()
        let memoryAliases = explicitMemoryAliases(defaults: defaults)
        let entries = catalog.map { app in
            let learnedAliases = memoryAliases.compactMap { alias -> String? in
                let value = normalize(alias.value)
                let matches = catalog.filter {
                    let names = [normalize($0.bundleIdentifier), normalize($0.name)]
                    return names.contains(value) || names.contains(where: { $0.hasPrefix(value) })
                }
                return matches.count == 1 && matches[0].bundleIdentifier == app.bundleIdentifier
                    ? alias.trigger
                    : nil
            }
            let integrations = Set(Self.integrations(for: app.bundleIdentifier))
            return ApplicationRegistryEntry(
                bundleIdentifier: app.bundleIdentifier,
                displayName: app.name,
                aliases: (aliases[app.bundleIdentifier] ?? []) + learnedAliases + derivedAliases(for: app.name),
                isRunning: running.contains(app.bundleIdentifier),
                supportedActions: nativeSupportedActions(for: app.bundleIdentifier, integrations: integrations),
                integrations: integrations
            )
        }
        return ApplicationRegistry(entries: entries)
    }

    static func derivedAliases(for displayName: String) -> [String] {
        var words = displayName.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard words.count > 1,
              let suffix = words.last?.lowercased(),
              ["app", "application", "browser"].contains(suffix) else { return [] }
        words.removeLast()
        let alias = words.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return alias.isEmpty ? [] : [alias]
    }

    private static func explicitMemoryAliases(defaults: UserDefaults) -> [(trigger: String, value: String)] {
        guard let data = defaults.data(forKey: "flowstate.explicit-memory.v1"),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let preferences = root["preferences"] as? [[String: Any]] else { return [] }
        return preferences.compactMap { preference in
            guard preference["category"] as? String == "appAlias",
                  preference["source"] as? String == "explicit",
                  let trigger = preference["trigger"] as? String,
                  let value = preference["value"] as? String else { return nil }
            return (trigger: trigger, value: value)
        }
    }

    static func normalize(_ value: String) -> String {
        let folded = value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        var result = ""
        var needsSpace = false
        for character in folded {
            if character.isLetter || character.isNumber {
                if needsSpace, !result.isEmpty { result.append(" ") }
                result.append(contentsOf: character.lowercased())
                needsSpace = false
            } else {
                needsSpace = true
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func matchScore(_ entry: ApplicationRegistryEntry, query: String) -> Int {
        if entry.normalizedNames.contains(query) { return 0 }
        if entry.normalizedNames.contains(where: { $0.hasPrefix(query) }) { return 1 }
        return 2
    }

    private static func bundleOrder(_ lhs: ApplicationRegistryEntry, _ rhs: ApplicationRegistryEntry) -> Bool {
        lhs.bundleIdentifier.localizedStandardCompare(rhs.bundleIdentifier) == .orderedAscending
    }

    private static func merge(_ lhs: ApplicationRegistryEntry, _ rhs: ApplicationRegistryEntry) -> ApplicationRegistryEntry {
        ApplicationRegistryEntry(
            bundleIdentifier: lhs.bundleIdentifier,
            displayName: lhs.isRunning ? lhs.displayName : rhs.displayName,
            aliases: lhs.aliases + rhs.aliases,
            isRunning: lhs.isRunning || rhs.isRunning,
            supportedActions: lhs.supportedActions.intersection(rhs.supportedActions),
            integrations: lhs.integrations.union(rhs.integrations)
        )
    }

    private static func integrations(for bundleIdentifier: String) -> [String] {
        var result = ["launchServices"]
        if ["com.brave.Browser", "com.apple.Safari", "com.google.Chrome"].contains(bundleIdentifier) {
            result.append("browser")
        }
        return result
    }

    static func nativeSupportedActions(for bundleIdentifier: String, integrations: Set<String>) -> Set<DesktopActionKind> {
        guard integrations.contains("browser") || nativeControlBundles.contains(bundleIdentifier) else {
            return [.openApplication, .click]
        }
        return Set(DesktopActionKind.allCases)
    }

    private static let nativeControlBundles: Set<String> = [
        "com.apple.TextEdit",
        "com.apple.Notes",
        "com.apple.Preview",
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.microsoft.VSCode",
    ]
}
