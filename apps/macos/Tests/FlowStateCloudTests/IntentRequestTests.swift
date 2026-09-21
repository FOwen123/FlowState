import Foundation
import Testing
import FlowStateCore
@testable import FlowStateCloud

@Test func intentContextContainsMetadataButNoFieldValuesOrScreenshot() throws {
    let context = CloudIntentContext(focusedAppBundleIdentifier: "com.apple.TextEdit", focusedRole: "AXTextArea", editable: true, targetCandidates: [.init(id: "app:editor", label: "TextEdit", bundleIdentifier: "com.apple.TextEdit", kind: "app")])
    let data = try JSONEncoder().encode(context)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["editable"] as? Bool == true)
    #expect(object["value"] == nil)
    #expect(object["imageDataUrl"] == nil)
    #expect(object["focusedRole"] as? String == "AXTextArea")
}

@Test func intentCandidatesEncodeRoutingMetadata() throws {
    let candidate = CloudIntentCandidate(
        id: "app:com.brave.Browser",
        label: "Brave Browser",
        bundleIdentifier: "com.brave.Browser",
        kind: "app",
        normalizedNames: ["brave browser", "brave"],
        isRunning: false,
        supportedActions: ["openApplication", "scroll"],
        integrations: ["launchServices", "browser"]
    )
    let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(candidate)) as? [String: Any])

    #expect(object["normalizedNames"] as? [String] == ["brave browser", "brave"])
    #expect(object["isRunning"] as? Bool == false)
    #expect(object["supportedActions"] as? [String] == ["openApplication", "scroll"])
    #expect(object["integrations"] as? [String] == ["launchServices", "browser"])
}

@Test("intent routing advertises only actions and tools supported by the intent endpoint")
func intentRoutingExcludesStructuredServiceActions() {
    let grant = DesktopExecutionGrant(
        allowedBundleIdentifiers: ["com.brave.Browser"],
        allowedActions: Set(DesktopActionKind.allCases),
        generation: 1,
        expiresAt: Date().addingTimeInterval(60)
    )

    let actions = intentSupportedActionNames(for: grant)
    #expect(Set(actions) == Set(["openApplication", "scroll", "focus", "select", "press"]))
    #expect(!actions.contains("openURL"))
    #expect(!actions.contains("draftMessage"))
    #expect(intentSupportedTools(["nativeAccessibility", "structuredIntegration"]) == ["nativeAccessibility"])
    #expect(intentSupportedTools(["structuredIntegration"]).isEmpty)
}

@Test func planApplicationCandidatesEncodeOnlyTheBackendRegistryContract() throws {
    let candidate = CloudApplicationCandidate(
        bundleIdentifier: "com.brave.Browser",
        displayName: "Brave Browser",
        normalizedNames: ["brave browser", "brave"],
        supportedActions: ["openApplication", "openURL"],
        integrations: ["browser"]
    )
    let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(candidate)) as? [String: Any])
    #expect(Set(object.keys) == ["bundleIdentifier", "displayName", "normalizedNames", "supportedActions", "integrations"])
}

@Test func intentContextRedactsRecentPrivateContentBeforeEncoding() throws {
    let context = CloudIntentContext(
        focusedAppBundleIdentifier: "com.apple.TextEdit",
        focusedRole: "AXTextArea",
        editable: true,
        targetCandidates: [],
        recentInteraction: "Draft to owner@example.com with body: \"private quarterly results\" at https://private.example/account?token=secret"
    )
    let encoded = String(decoding: try JSONEncoder().encode(context), as: UTF8.self)
    #expect(!encoded.contains("owner@example.com"))
    #expect(!encoded.contains("private quarterly results"))
    #expect(!encoded.contains("https://private.example/account?token=secret"))
}

@Test func staleIntentResponsesCannotCrossSessionOrFocusRevision() throws {
    try requireCurrentIntent(signedIn: true, currentGeneration: 2, requestGeneration: 2, expectedSession: "s", returnedSession: "s", expectedUtterance: "u", returnedUtterance: "u", expectedRevision: 4, returnedRevision: 4)
    #expect(throws: (any Error).self) {
        try requireCurrentIntent(signedIn: true, currentGeneration: 3, requestGeneration: 2, expectedSession: "s", returnedSession: "s", expectedUtterance: "u", returnedUtterance: "u", expectedRevision: 4, returnedRevision: 4)
    }
    #expect(throws: (any Error).self) {
        try requireCurrentIntent(signedIn: true, currentGeneration: 2, requestGeneration: 2, expectedSession: "s", returnedSession: "s", expectedUtterance: "u", returnedUtterance: "other", expectedRevision: 4, returnedRevision: 4)
    }
    #expect(throws: (any Error).self) {
        try requireCurrentIntent(signedIn: true, currentGeneration: 2, requestGeneration: 2, expectedSession: "s", returnedSession: "s", expectedUtterance: "u", returnedUtterance: "u", expectedRevision: 4, returnedRevision: 3)
    }
    #expect(throws: (any Error).self) {
        try requireCurrentIntent(signedIn: false, currentGeneration: 2, requestGeneration: 2, expectedSession: "s", returnedSession: "s", expectedUtterance: "u", returnedUtterance: "u", expectedRevision: 4, returnedRevision: 4)
    }
}

@Test func visualIntentIncludesWindowGeometry() throws {
    let observation = CloudIntentObservation(id: "o", displayId: "1", windowId: "2", observedAt: 1000,
        geometry: .init(x: 10, y: 20, width: 800, height: 600, scale: 2), imageDataUrl: "data:image/png;base64,AAAA")
    let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(observation)) as? [String: Any])
    let geometry = try #require(object["geometry"] as? [String: Double])
    #expect(geometry["scale"] == 2)
    #expect(geometry["width"] == 800)
}
