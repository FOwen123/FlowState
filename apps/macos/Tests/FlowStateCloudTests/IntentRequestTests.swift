import Foundation
import Testing
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
