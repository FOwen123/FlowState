import Foundation
import ConvexMobile
import FlowStateCore

public struct CloudIntentCandidate: Codable, Sendable {
    public let id: String
    public let label: String
    public let bundleIdentifier: String?
    public let kind: String
    public let normalizedNames: [String]
    public let isRunning: Bool?
    public let supportedActions: [String]
    public let integrations: [String]
    public init(
        id: String,
        label: String,
        bundleIdentifier: String?,
        kind: String,
        normalizedNames: [String] = [],
        isRunning: Bool? = nil,
        supportedActions: [String] = [],
        integrations: [String] = []
    ) {
        self.id = id
        self.label = label
        self.bundleIdentifier = bundleIdentifier
        self.kind = kind
        self.normalizedNames = normalizedNames
        self.isRunning = isRunning
        self.supportedActions = supportedActions
        self.integrations = integrations
    }
}

/// The bounded application snapshot sent with a reviewed control plan. The
/// normalized names include the display name and any user-approved aliases;
/// the backend deliberately receives no richer local application object.
public struct CloudApplicationCandidate: Codable, ConvexEncodable, Sendable, Equatable {
    public let bundleIdentifier: String
    public let displayName: String
    public let normalizedNames: [String]
    public let supportedActions: [String]
    public let integrations: [String]

    public init(bundleIdentifier: String, displayName: String, normalizedNames: [String],
                supportedActions: [String], integrations: [String]) {
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.normalizedNames = normalizedNames
        self.supportedActions = supportedActions
        self.integrations = integrations
    }
}

/// Metadata only: field values and screenshots are not part of ordinary routing.
public struct CloudIntentContext: Codable, ConvexEncodable, Sendable {
    public let focusedAppBundleIdentifier: String?
    public let focusedRole: String?
    public let editable: Bool
    public let targetCandidates: [CloudIntentCandidate]
    public let recentInteraction: String?
    public init(focusedAppBundleIdentifier: String?, focusedRole: String?, editable: Bool,
                targetCandidates: [CloudIntentCandidate], recentInteraction: String? = nil) {
        self.focusedAppBundleIdentifier = focusedAppBundleIdentifier
        self.focusedRole = focusedRole; self.editable = editable
        self.targetCandidates = targetCandidates
        self.recentInteraction = recentInteraction.map(ControlConversationSession.structuredSummary)
    }
}

public struct CloudIntentObservation: Codable, ConvexEncodable, Sendable {
    public let id: String
    public let bundleIdentifier: String
    public let displayId: String
    public let windowId: String
    public let observedAt: Double
    public struct Geometry: Codable, Sendable {
        public let x: Double, y: Double, width: Double, height: Double, scale: Double
        public init(x: Double, y: Double, width: Double, height: Double, scale: Double) {
            self.x = x; self.y = y; self.width = width; self.height = height; self.scale = scale
        }
    }
    public let geometry: Geometry
    public let imageDataUrl: String
    public init(id: String, bundleIdentifier: String, displayId: String, windowId: String, observedAt: Double, geometry: Geometry, imageDataUrl: String) {
        self.id = id; self.bundleIdentifier = bundleIdentifier; self.displayId = displayId; self.windowId = windowId
        self.observedAt = observedAt; self.geometry = geometry; self.imageDataUrl = imageDataUrl
    }
}

func requireCurrentIntent(signedIn: Bool, currentGeneration: UInt64, requestGeneration: UInt64,
                          expectedSession: String, returnedSession: String,
                          expectedUtterance: String, returnedUtterance: String,
                          expectedRevision: Int, returnedRevision: Int) throws {
    guard signedIn, currentGeneration == requestGeneration,
          expectedSession == returnedSession, expectedUtterance == returnedUtterance,
          expectedRevision == returnedRevision else { throw CancellationError() }
}
