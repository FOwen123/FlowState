import FlowStateCore
import FlowStateCloud
import Testing
@testable import FlowStateApp

private let registryActions: Set<DesktopActionKind> = [.openApplication, .scroll, .focus, .select, .press]

@Test("installed app names derive only safe generic-suffix aliases")
func applicationRegistryDerivesGenericSuffixAliases() {
    #expect(ApplicationRegistry.derivedAliases(for: "Brave Browser") == ["Brave"])
    #expect(ApplicationRegistry.derivedAliases(for: "Example App") == ["Example"])
    #expect(ApplicationRegistry.derivedAliases(for: "Mail") == [])
    #expect(ApplicationRegistry.derivedAliases(for: "Microsoft Word") == [])
}

@Test("registry resolves a closed Brave entry through an exact alias")
func applicationRegistryResolvesClosedAlias() {
    let brave = ApplicationRegistryEntry(
        bundleIdentifier: "com.brave.Browser",
        displayName: "Brave Browser",
        aliases: ["Brave"],
        isRunning: false,
        supportedActions: registryActions,
        integrations: ["browser"]
    )
    let registry = ApplicationRegistry(entries: [brave])

    #expect(registry.resolve("Brave") == .resolved(brave))
    #expect(registry.resolve("com.brave.Browser") == .resolved(brave))
    #expect(registry.resolve("Brave Browser") == .resolved(brave))
    #expect(registry.candidates(for: "Open Brave").first == brave)
    #expect(brave.isRunning == false)
    #expect(brave.integrations == ["browser"])
}

@Test("duplicate display names and aliases require clarification")
func applicationRegistryRejectsAmbiguousNames() {
    let first = ApplicationRegistryEntry(
        bundleIdentifier: "com.example.one",
        displayName: "Notes",
        aliases: ["scratch"],
        isRunning: true,
        supportedActions: registryActions
    )
    let second = ApplicationRegistryEntry(
        bundleIdentifier: "com.example.two",
        displayName: "Notes",
        aliases: ["scratch"],
        isRunning: false,
        supportedActions: registryActions
    )
    let registry = ApplicationRegistry(entries: [second, first])

    guard case let .ambiguous(matches) = registry.resolve("notes") else {
        Issue.record("Expected duplicate display names to require clarification")
        return
    }
    #expect(matches.map(\.bundleIdentifier) == ["com.example.one", "com.example.two"])
    guard case let .ambiguous(aliasMatches) = registry.resolve("scratch") else {
        Issue.record("Expected duplicate aliases to require clarification")
        return
    }
    #expect(aliasMatches.map(\.bundleIdentifier) == ["com.example.one", "com.example.two"])
}

@Test("unknown names never resolve to the foreground app")
func applicationRegistryRejectsUnknownName() {
    let registry = ApplicationRegistry(entries: [ApplicationRegistryEntry(
        bundleIdentifier: "com.example.editor",
        displayName: "Editor",
        aliases: [],
        isRunning: true,
        supportedActions: registryActions
    )])

    #expect(registry.resolve("Definitely Missing") == .unknown)
}

@Test("candidate prefilter is deterministic and bounded")
func applicationRegistryPrefilterIsBounded() {
    let entries = (0..<260).map { index in
        ApplicationRegistryEntry(
            bundleIdentifier: "com.example.app\(index)",
            displayName: "Project App \(index)",
            aliases: ["project \(index)"],
            isRunning: index == 42,
            supportedActions: registryActions
        )
    }
    let registry = ApplicationRegistry(entries: entries)
    let candidates = registry.candidates(for: "project", limit: 99)

    #expect(candidates.count == 99)
    #expect(candidates == registry.candidates(for: "project", limit: 99))
}

@Test("normalization makes punctuation and case equivalent")
func applicationRegistryNormalizesAliases() {
    let app = ApplicationRegistryEntry(
        bundleIdentifier: "com.example.writer",
        displayName: "My Writer",
        aliases: ["My-Writer"],
        isRunning: false,
        supportedActions: registryActions
    )
    let registry = ApplicationRegistry(entries: [app])

    #expect(registry.resolve("  my_writer  ") == .resolved(app))
}

@Test("registered open commands resolve before any target grant")
func registeredApplicationCommandResolution() {
    let brave = ApplicationRegistryEntry(
        bundleIdentifier: "com.brave.Browser",
        displayName: "Brave Browser",
        aliases: ["Brave"],
        supportedActions: registryActions
    )
    let registry = ApplicationRegistry(entries: [brave])
    guard case let .resolved(entry) = registry.resolveApplicationCommand("Open Brave") else {
        Issue.record("Expected an exact registered app command")
        return
    }
    #expect(entry.bundleIdentifier == brave.bundleIdentifier)

    guard case .notAnApplicationCommand = registry.resolveApplicationCommand("Scroll down") else {
        Issue.record("Non-app commands should remain on the normal control route")
        return
    }
}

@Test("unknown and ambiguous registered app commands clarify without a fallback target")
func registeredApplicationCommandClarification() {
    let registry = ApplicationRegistry(entries: [
        ApplicationRegistryEntry(bundleIdentifier: "com.example.one", displayName: "Notes", supportedActions: registryActions),
        ApplicationRegistryEntry(bundleIdentifier: "com.example.two", displayName: "Notes", supportedActions: registryActions)
    ])
    guard case .ambiguous = registry.resolveApplicationCommand("Switch to Notes") else {
        Issue.record("Duplicate app names must clarify")
        return
    }
    guard case .unknown("missing") = registry.resolveApplicationCommand("Open Missing") else {
        Issue.record("Unknown app names must clarify")
        return
    }
}

@Test("unknown applications receive only the launch capability")
func applicationRegistryCapabilitiesFailClosed() {
    let actions = ApplicationRegistry.nativeSupportedActions(
        for: "com.example.Unknown",
        integrations: ["launchServices"]
    )

    #expect(actions == [.openApplication])
    #expect(!actions.contains(.insertText))
}

@Test("registered browser capabilities are explicit and exclude generic insertion")
func browserRegistryCapabilitiesAreExplicit() {
    let actions = ApplicationRegistry.nativeSupportedActions(
        for: "com.brave.Browser",
        integrations: ["launchServices", "browser"]
    )

    #expect(actions == registryActions)
    #expect(!actions.contains(.insertText))
}

@Test("plan candidates preserve one bounded registry snapshot")
func applicationPlanCandidatesAreBoundedAndTyped() {
    let brave = ApplicationRegistryEntry(
        bundleIdentifier: "com.brave.Browser",
        displayName: "Brave Browser",
        aliases: ["Brave"],
        isRunning: false,
        supportedActions: registryActions,
        integrations: ["launchServices", "browser"]
    )
    let editor = ApplicationRegistryEntry(
        bundleIdentifier: "com.example.Editor",
        displayName: "Editor",
        supportedActions: registryActions
    )
    let candidates = cloudApplicationCandidates(
        for: ApplicationRegistry(entries: [brave, editor]),
        command: "Open Brave",
        targetBundleIdentifier: editor.bundleIdentifier
    )

    #expect(candidates.count == 2)
    #expect(candidates.first?.bundleIdentifier == brave.bundleIdentifier)
    #expect(candidates.first?.normalizedNames.contains("brave") == true)
    #expect(candidates.first?.supportedActions.contains("scroll") == true)
    #expect(candidates.first?.supportedActions.contains("openURL") == true)
    #expect(candidates.first?.supportedActions.contains("draftMessage") == true)
    #expect(candidates.last?.supportedActions.contains("openURL") == false)
    #expect(candidates.last?.supportedActions.contains("draftMessage") == false)
    #expect(candidates.first?.integrations == ["browser", "launchServices"])
}
