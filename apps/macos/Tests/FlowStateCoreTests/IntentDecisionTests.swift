import Foundation
import Testing
@testable import FlowStateCore

@Test("intent decisions decode a supported native action and expose a strict context")
func intentDecisionDecodesNativeAction() throws {
    let decision = try IntentDecision.decode(data("""
    {
      "requestId": "request-1",
      "sessionId": "session-1",
      "utteranceId": "utterance-1",
      "contextRevision": 4,
      "policyVersion": "intent-policy-1",
      "policyRevision": "unmeasured",
      "decision": "execute",
      "reason": "policy_pass",
      "intent": "navigate",
      "action": {
        "kind": "press",
        "targetId": "focused-1",
        "targetBundleIdentifier": "com.apple.TextEdit",
        "parameters": {"key": "Tab", "modifiers": "Shift"}
      },
      "textFallbackUsed": false,
      "visionFallbackUsed": false,
      "requiresObservation": false,
      "clarification": null,
      "confidence": {"intent": 0.98, "action": 0.96, "target": 0.94, "topTwoMargin": 0.8},
      "model": {"jev": "jev-1"},
      "latencyMs": 18
    }
    """))

    #expect(decision.requestID == "request-1")
    #expect(decision.policyRevision == "unmeasured")
    #expect(decision.reason == "policy_pass")
    #expect(decision.decision == .execute)
    #expect(decision.action?.nativePlanAction.desktopAction == .press(key: "Tab", modifiers: "Shift"))
    #expect(decision.action?.targetID == "focused-1")
    #expect(decision.confidence.intent == 0.98)
}

@Test("intent decisions accept app.open only for app opening")
func intentDecisionAcceptsScopedOpenCapability() throws {
    let decision = try IntentDecision.decode(data("""
    {
      "requestId": "request-open",
      "sessionId": "session-1",
      "utteranceId": "utterance-2",
      "contextRevision": 5,
      "policyVersion": "intent-policy-1",
      "decision": "execute",
      "intent": "open_application",
      "action": {
        "kind": "openApplication",
        "targetId": "app-brave",
        "targetBundleIdentifier": "com.brave.Browser",
        "parameters": {}
      },
      "textFallbackUsed": false,
      "visionFallbackUsed": false,
      "requiresObservation": false,
      "confidence": {"intent": 0.99, "action": 0.99, "target": 0.99},
      "model": {"jev": "jev-1"}
    }
    """))

    #expect(decision.action?.nativePlanAction.capability == "app.open")
}

@Test("clarification decisions cannot smuggle an executable action")
func intentDecisionRejectsActionForClarification() {
    #expect(throws: IntentDecisionDecodingError.self) {
        _ = try IntentDecision.decode(data("""
        {
          "requestId": "request-2",
          "sessionId": "session-1",
          "utteranceId": "utterance-3",
          "contextRevision": 6,
          "policyVersion": "intent-policy-1",
          "decision": "clarify",
          "intent": "navigate",
          "action": {"kind": "scroll", "targetBundleIdentifier": "com.apple.TextEdit", "parameters": {"lines": -3}},
          "textFallbackUsed": false,
          "visionFallbackUsed": false,
          "requiresObservation": true,
          "clarification": "Which window?",
          "confidence": {"intent": 0.4},
          "model": {"jev": "jev-1"}
        }
        """))
    }
}

@Test("intent decisions reject unknown fields and incomplete confidence")
func intentDecisionRejectsMalformedEnvelope() {
    let unknown = """
    {
      "requestId": "request-3", "sessionId": "session-1", "utteranceId": "utterance-4",
      "contextRevision": 1, "policyVersion": "intent-policy-1", "decision": "abstain", "intent": null,
      "action": null, "textFallbackUsed": false, "visionFallbackUsed": false,
      "requiresObservation": false, "confidence": {"intent": 0.4}, "model": {"jev": "jev-1"}, "unexpected": true
    }
    """
    #expect(throws: IntentDecisionDecodingError.self) { _ = try IntentDecision.decode(data(unknown)) }

    let invalidConfidence = unknown.replacingOccurrences(of: ", " + "\"unexpected\": true", with: "")
        .replacingOccurrences(of: "\"intent\": 0.4", with: "\"intent\": 1.2")
    #expect(throws: IntentDecisionDecodingError.self) {
        _ = try IntentDecision.decode(data(invalidConfidence))
    }
}

private func data(_ value: String) -> Data { Data(value.utf8) }
