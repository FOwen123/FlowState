import Foundation
import Testing
@testable import FlowStateCore

@Test("control plans reject normalized English insert plans")
func englishInsertPlanDecodes() {
    #expect(throws: NativePlanDecodingError.self) {
        _ = try NativePlanResponse.decode(data("""
    {
      "planId": "plan-en",
      "status": "awaiting_approval",
      "fingerprint": "fp-en",
      "actions": [{
        "kind": "insertText",
        "targetBundleIdentifier": "com.apple.TextEdit",
        "parameters": {"text": "Hello from FlowState", "replaceSelection": true},
        "capability": "app.input",
        "executor": "desktop",
        "requiresApproval": true
      }],
      "capabilities": ["app.input"]
    }
    """))
    }
}

@Test("control plans reject normalized Traditional Chinese insert plans")
func traditionalChineseInsertPlanDecodes() {
    #expect(throws: NativePlanDecodingError.self) {
        _ = try NativePlanResponse.decode(data("""
    {
      "planId": "plan-zh-hant",
      "status": "awaiting_approval",
      "fingerprint": "fp-zh-hant",
      "actions": [{
        "kind": "insertText",
        "targetBundleIdentifier": "com.brave.Browser",
        "parameters": {"text": "請幫我打開這個頁面"},
        "capability": "app.input",
        "executor": "desktop",
        "requiresApproval": true
      }],
      "capabilities": ["app.input"]
    }
    """))
    }
}

@Test("open and bounded scroll plans map to native actions")
func openAndScrollPlansDecode() throws {
    let response = try NativePlanResponse.decode(data("""
    {
      "planId": "plan-navigation",
      "status": "awaiting_approval",
      "fingerprint": "fp-navigation",
      "actions": [
        {
          "kind": "openApplication",
          "targetBundleIdentifier": "com.spotify.client",
          "parameters": {},
          "capability": "app.control",
          "executor": "desktop",
          "requiresApproval": false
        },
        {
          "kind": "scroll",
          "targetBundleIdentifier": "com.spotify.client",
          "parameters": {"lines": -100},
          "capability": "app.control",
          "executor": "desktop",
          "requiresApproval": false
        }
      ],
      "capabilities": ["app.control"]
    }
    """))

    #expect(response.actions[0].desktopAction == .openApplication(bundleIdentifier: "com.spotify.client"))
    #expect(response.actions[1].desktopAction == .scroll(lines: -100))
    #expect(response.actions[0].capability == "app.control")
    #expect(response.actions[1].capability == "app.control")
    #expect(response.actions[0].executor == "desktop")
    #expect(response.actions[1].executor == "desktop")
}

@Test("plan steps retain route, preconditions, verifier, risk, reversal, and expiry")
func planStepExecutionMetadata() {
    let expiry = Date(timeIntervalSince1970: 1_800_000_000)
    let action = NativePlanAction(
        kind: .scroll,
        targetBundleIdentifier: "com.example.Reader",
        parameters: .scroll(lines: -3),
        capability: "app.control",
        requiresApproval: false,
        route: .nativeAccessibility,
        preconditions: NativePlanPreconditions(targetBundleIdentifier: "com.example.Reader", requiresFreshObservation: true),
        verifier: NativePlanVerifier(kind: .boundedAction),
        risk: .routine,
        reversalSupported: false,
        expiresAt: expiry
    )

    #expect(action.route == .nativeAccessibility)
    #expect(action.preconditions.requiresFreshObservation)
    #expect(action.preconditions.targetBundleIdentifier == "com.example.Reader")
    #expect(action.verifier.kind == .boundedAction)
    #expect(action.risk == .routine)
    #expect(!action.reversalSupported)
    #expect(action.isCurrent(at: expiry.addingTimeInterval(-1)))
    #expect(!action.isCurrent(at: expiry))
}

@Test("focus, select, and bounded key plans map to native actions")
func focusSelectAndPressPlansDecode() throws {
    let response = try NativePlanResponse.decode(data("""
    {
      "planId": "plan-controls",
      "status": "ready",
      "fingerprint": "fp-controls",
      "actions": [
        {
          "kind": "focus",
          "targetBundleIdentifier": "com.apple.TextEdit",
          "parameters": {"role": "AXTextField", "label": "Title"},
          "capability": "app.control",
          "executor": "desktop",
          "requiresApproval": false,
          "targetId": "focused-title"
        },
        {
          "kind": "select",
          "targetBundleIdentifier": "com.apple.TextEdit",
          "parameters": {"label": "Title"},
          "capability": "app.control",
          "executor": "desktop",
          "requiresApproval": false
        },
        {
          "kind": "press",
          "targetBundleIdentifier": "com.apple.TextEdit",
          "parameters": {"key": "Tab", "modifiers": "Shift"},
          "capability": "app.input",
          "executor": "desktop",
          "requiresApproval": true
        }
      ],
      "capabilities": ["app.control", "app.input"]
    }
    """))

    #expect(response.actions[0].desktopAction == .focus(role: "AXTextField", label: "Title"))
    #expect(response.actions[1].desktopAction == .select(label: "Title"))
    #expect(response.actions[2].desktopAction == .press(key: "Tab", modifiers: "Shift"))
}

@Test("a labeled click maps to a generic native Accessibility action")
func labeledClickPlanDecodes() throws {
    let response = try NativePlanResponse.decode(data("""
    {
      "planId": "plan-click",
      "status": "ready",
      "fingerprint": "fp-click",
      "actions": [{
        "kind": "click",
        "targetBundleIdentifier": "com.apple.PhotoBooth",
        "parameters": {"label": "Take Photo"},
        "capability": "app.control",
        "executor": "desktop",
        "requiresApproval": true,
        "route": "nativeAccessibility"
      }],
      "capabilities": ["app.control"]
    }
    """))

    #expect(response.actions[0].desktopAction == .click(label: "Take Photo"))
}

@Test("a visual click retains bounded geometry for the approved capture")
func visualClickPlanDecodes() throws {
    let response = try NativePlanResponse.decode(data("""
    {
      "planId": "plan-visual-click",
      "status": "ready",
      "fingerprint": "fp-visual-click",
      "actions": [{
        "kind": "click",
        "targetBundleIdentifier": "com.example.Canvas",
        "parameters": {"label": "Visible control"},
        "capability": "app.control",
        "executor": "desktop",
        "requiresApproval": true,
        "route": "visualComputerUse",
        "visualTarget": {
          "observationId": "00000000-0000-0000-0000-000000000042",
          "displayId": "7",
          "windowId": "42",
          "x": 0,
          "y": 0,
          "width": 0.1,
          "height": 0.13333333333333333,
          "observedAt": 1800000000000
        }
      }],
      "capabilities": ["app.control"]
    }
    """))

    let target = try response.actions[0].validatedVisualTarget()
    #expect(response.actions[0].route == .visualComputerUse)
    #expect(target.displayID == 7)
    #expect(target.windowID == 42)
    #expect(target.bounds == CGRect(x: 0, y: 0, width: 0.1, height: 0.13333333333333333))

    let capture = CaptureObservation(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000042")!,
        bundleIdentifier: "com.example.Canvas",
        windowID: 42,
        displayID: 7,
        capturedAt: Date(timeIntervalSince1970: 1_800_000_000),
        windowFrame: CGRect(x: 100, y: 200, width: 400, height: 300),
        scale: 2,
        security: .clear
    )
    #expect(try target.screenPoint(in: capture) == CGPoint(x: 120, y: 220))
}

@Test("visual target coordinates must remain inside the exact captured window")
func visualClickRejectsCoordinatesOutsideCapture() {
    #expect(throws: NativePlanDecodingError.self) {
        _ = try NativePlanResponse.decode(data("""
        {
          "planId": "plan-visual-click-bounds",
          "status": "ready",
          "fingerprint": "fp-visual-click-bounds",
          "actions": [{
            "kind": "click",
            "targetBundleIdentifier": "com.example.Canvas",
            "parameters": {"label": "Visible control"},
            "capability": "app.control",
            "executor": "desktop",
            "requiresApproval": true,
            "route": "visualComputerUse",
            "visualTarget": {
              "observationId": "00000000-0000-0000-0000-000000000042",
              "displayId": "7", "windowId": "42", "x": 0.99, "y": 0.1,
              "width": 0.02, "height": 0.2, "observedAt": 1800000000000
            }
          }],
          "capabilities": ["app.control"]
        }
        """))
    }
}

@Test("labeled clicks cannot bypass confirmation")
func labeledClickRequiresApproval() {
    #expect(throws: NativePlanDecodingError.self) {
        _ = try NativePlanResponse.decode(data("""
        {
          "planId": "plan-click-unapproved",
          "status": "ready",
          "fingerprint": "fp-click-unapproved",
          "actions": [{
            "kind": "click",
            "targetBundleIdentifier": "com.example.Canvas",
            "parameters": {"label": "Delete"},
            "capability": "app.control",
            "executor": "desktop",
            "requiresApproval": false,
            "route": "nativeAccessibility"
          }],
          "capabilities": ["app.control"]
        }
        """))
    }
}

@Test("native plan accepts an app.open capability only for open application")
func appOpenCapabilityIsScoped() throws {
    let response = try NativePlanResponse.decode(data("""
    {
      "planId": "plan-app-open",
      "status": "ready",
      "fingerprint": "fp-app-open",
      "actions": [{
        "kind": "openApplication",
        "targetBundleIdentifier": "com.brave.Browser",
        "parameters": {},
        "capability": "app.open",
        "executor": "desktop",
        "requiresApproval": false
      }],
      "capabilities": ["app.open"]
    }
    """))

    #expect(response.actions[0].capability == "app.open")
}

@Test("native plan rejects an unknown target field even when targetId is known")
func unknownTargetFieldIsRejected() {
    #expect(throws: NativePlanDecodingError.self) {
        _ = try NativePlanResponse.decode(data(validInsertJSON.replacingOccurrences(
            of: "\"requiresApproval\": true",
            with: "\"requiresApproval\": true, \"targetId\": \"target-1\", \"targetLabel\": \"unexpected\""
        )))
    }
}

@Test("execution metadata is accepted separately from the normalized response")
func executionMetadataWrapper() throws {
    let response = try NativePlanResponse.decode(data(validScrollJSON))
    let expiry = Date(timeIntervalSince1970: 1_800_000_000)
    let context = NativePlanExecutionContext(
        plan: response,
        expiresAt: expiry,
        cancellationGeneration: 12
    )

    #expect(context.plan.planId == response.planId)
    #expect(context.expiresAt == expiry)
    #expect(context.cancellationGeneration == 12)
}

@Test("unknown top-level fields are rejected")
func unknownTopLevelFieldIsRejected() {
    #expect(throws: NativePlanDecodingError.self) {
        _ = try NativePlanResponse.decode(data(validInsertJSON.replacingOccurrences(
            of: "\"planId\": \"plan-test\"",
            with: "\"model\": \"unexpected\", \"planId\": \"plan-test\""
        )))
    }
}

@Test("unknown action and parameter fields are rejected")
func unknownNestedFieldsAreRejected() {
    let actionUnknown = validInsertJSON.replacingOccurrences(
        of: "\"requiresApproval\": true",
        with: "\"requiresApproval\": true, \"unexpected\": true"
    )
    #expect(throws: NativePlanDecodingError.self) {
        _ = try NativePlanResponse.decode(data(actionUnknown))
    }

    let parameterUnknown = validInsertJSON.replacingOccurrences(
        of: "\"replaceSelection\": true",
        with: "\"replaceSelection\": true, \"mode\": \"append\""
    )
    #expect(throws: NativePlanDecodingError.self) {
        _ = try NativePlanResponse.decode(data(parameterUnknown))
    }
}

@Test("service and unsupported actions are rejected")
func serviceAndUnsupportedActionsAreRejected() {
    let service = validInsertJSON.replacingOccurrences(
        of: "\"kind\": \"insertText\"",
        with: "\"kind\": \"sendEmail\""
    ).replacingOccurrences(of: "desktop.insertText", with: "email.send")
    #expect(throws: NativePlanDecodingError.self) {
        _ = try NativePlanResponse.decode(data(service))
    }

    let nonNative = validInsertJSON.replacingOccurrences(
        of: "\"executor\": \"desktop\"",
        with: "\"executor\": \"service\""
    )
    #expect(throws: NativePlanDecodingError.self) {
        _ = try NativePlanResponse.decode(data(nonNative))
    }
}

@Test("malformed parameters and unsupported visual targets are rejected")
func malformedParametersAreRejected() {
    let malformed = validInsertJSON.replacingOccurrences(
        of: "\"parameters\": {\"text\": \"Hello\", \"replaceSelection\": true}",
        with: "\"parameters\": [\"Hello\"]"
    )
    #expect(throws: NativePlanDecodingError.self) {
        _ = try NativePlanResponse.decode(data(malformed))
    }

    let visual = validInsertJSON.replacingOccurrences(
        of: "\"requiresApproval\": true",
        with: "\"requiresApproval\": true, \"visualTarget\": {\"x\": 10}"
    )
    #expect(throws: NativePlanDecodingError.self) {
        _ = try NativePlanResponse.decode(data(visual))
    }
}

@Test("normalized plans contain between one and twelve native actions")
func actionCountIsBounded() {
    let zeroActions = """
    {
      "planId": "plan-zero",
      "status": "awaiting_approval",
      "fingerprint": "fp-zero",
      "actions": [],
      "capabilities": ["app.input"]
    }
    """
    #expect(throws: NativePlanDecodingError.self) {
        _ = try NativePlanResponse.decode(data(zeroActions))
    }

    let action = """
    {
      "kind": "insertText",
      "targetBundleIdentifier": "com.apple.TextEdit",
      "parameters": {"text": "Hello", "replaceSelection": true},
      "capability": "app.input",
      "executor": "desktop",
      "requiresApproval": true
    }
    """
    let tooManyActions = """
    {
      "planId": "plan-too-many",
      "status": "awaiting_approval",
      "fingerprint": "fp-too-many",
      "actions": [
    """ + Array(repeating: action, count: 13).joined(separator: ",") + """
      ],
      "capabilities": ["app.input"]
    }
    """
    #expect(throws: NativePlanDecodingError.self) {
        _ = try NativePlanResponse.decode(data(tooManyActions))
    }
}

@Test("fractional scroll values are rejected")
func fractionalScrollIsRejected() {
    let json = validScrollJSON.replacingOccurrences(of: "\"lines\": -3", with: "\"lines\": -3.5")
    #expect(throws: NativePlanDecodingError.self) {
        _ = try NativePlanResponse.decode(data(json))
    }
}

@Test("oversize and non-replacing text are rejected")
func invalidInsertParametersAreRejected() {
    let oversized = validInsertJSON.replacingOccurrences(
        of: "Hello",
        with: String(repeating: "x", count: 20_001)
    )
    #expect(throws: NativePlanDecodingError.self) {
        _ = try NativePlanResponse.decode(data(oversized))
    }

    let nonReplacing = validInsertJSON.replacingOccurrences(
        of: "\"replaceSelection\": true",
        with: "\"replaceSelection\": false"
    )
    #expect(throws: NativePlanDecodingError.self) {
        _ = try NativePlanResponse.decode(data(nonReplacing))
    }
}

private let validInsertJSON = """
{
  "planId": "plan-test",
  "status": "awaiting_approval",
  "fingerprint": "fp-test",
  "actions": [{
    "kind": "insertText",
    "targetBundleIdentifier": "com.apple.TextEdit",
    "parameters": {"text": "Hello", "replaceSelection": true},
    "capability": "app.input",
    "executor": "desktop",
    "requiresApproval": true
  }],
  "capabilities": ["app.input"]
}
"""

private let validScrollJSON = """
{
  "planId": "plan-scroll",
  "status": "awaiting_approval",
  "fingerprint": "fp-scroll",
  "actions": [{
    "kind": "scroll",
    "targetBundleIdentifier": "com.apple.TextEdit",
    "parameters": {"lines": -3},
    "capability": "app.control",
    "executor": "desktop",
    "requiresApproval": false
  }],
  "capabilities": ["app.control"]
}
"""

private func data(_ value: String) -> Data {
    Data(value.utf8)
}

@Test("a stricter cloud review policy may require approval for navigation")
func stricterNavigationReviewPolicyDecodes() throws {
    let action = try JSONDecoder().decode(NativePlanAction.self, from: Data("""
    {"kind":"scroll","targetBundleIdentifier":"com.apple.TextEdit","parameters":{"lines":-3},
     "capability":"app.control","executor":"desktop","requiresApproval":true}
    """.utf8))
    #expect(action.requiresApproval)
    #expect(action.desktopAction == .scroll(lines: -3))
}

@Test("canonical backend plan payload decodes structured and native steps")
func canonicalBackendPlanPayloadDecodes() throws {
    let response = try NativePlanResponse.decode(data("""
    {
      "planId": "plan-canonical",
      "status": "awaiting_approval",
      "fingerprint": "fp-canonical",
      "actions": [
        {
          "kind": "openApplication",
          "targetBundleIdentifier": "com.brave.Browser",
          "parameters": {},
          "capability": "app.open",
          "executor": "desktop",
          "requiresApproval": false,
          "route": "nativeAccessibility",
          "riskClass": "reversible",
          "preconditions": {"targetBundleIdentifier": "com.brave.Browser", "requiresFreshObservation": false},
          "verifier": {"kind": "boundedAction"},
          "reversal": {"kind": "none", "supported": false}
        },
        {
          "kind": "openURL",
          "targetBundleIdentifier": "com.brave.Browser",
          "parameters": {"url": "https://example.com"},
          "capability": "app.control",
          "executor": "service",
          "requiresApproval": false,
          "route": "structuredIntegration",
          "riskClass": "reversible",
          "preconditions": {"targetBundleIdentifier": "com.brave.Browser", "requiresFreshObservation": false},
          "verifier": {"kind": "externalEffectReconciled"},
          "reversal": {"kind": "reconcile", "supported": false}
        }
      ],
      "capabilities": ["app.open", "app.control"]
    }
    """))

    #expect(response.actions.count == 2)
    #expect(response.actions[0].route == .nativeAccessibility)
    #expect(response.actions[0].preconditions.requiresFreshObservation == false)
    #expect(response.actions[1].kind == .openURL)
    #expect(response.actions[1].riskClass == .reversible)
    #expect(response.actions[1].verifier.kind == .externalEffectReconciled)
    #expect(response.actions[1].targetBundleIdentifier == "com.brave.Browser")
}

@Test("canonical draftMessage actions decode without becoming desktop typing")
func canonicalDraftMessageDecodesAsServiceAction() throws {
    let response = try NativePlanResponse.decode(data("""
    {
      "planId": "plan-draft",
      "status": "awaiting_approval",
      "fingerprint": "fp-draft",
      "actions": [{
        "kind": "draftMessage",
        "targetBundleIdentifier": "com.brave.Browser",
        "parameters": {"recipient": "person@example.com", "subject": "Hello", "body": "Draft only"},
        "capability": "mail.draft",
        "executor": "service",
        "requiresApproval": true,
        "route": "structuredIntegration",
        "riskClass": "confirm",
        "preconditions": {"targetBundleIdentifier": "com.brave.Browser", "requiresFreshObservation": false},
        "verifier": {"kind": "externalEffectReconciled"},
        "reversal": {"kind": "reconcile", "supported": false}
      }],
      "capabilities": ["mail.draft"]
    }
    """))

    #expect(response.actions[0].kind == .draftMessage)
    #expect(response.actions[0].desktopAction == nil)
    #expect(response.actions[0].route == .structuredIntegration)
    #expect(response.actions[0].requiresApproval)
}

@Test("canonical service actions preserve backend approval")
func reversibleStructuredActionsDecodeWithBackendRisk() throws {
    let response = try NativePlanResponse.decode(data("""
    {
      "planId": "plan-reversible-structured",
      "status": "awaiting_approval",
      "fingerprint": "fp-reversible-structured",
      "actions": [
        {
          "kind": "openURL",
          "targetBundleIdentifier": "com.brave.Browser",
          "parameters": {"url": "https://example.com/project"},
          "capability": "app.control",
          "executor": "service",
          "requiresApproval": false,
          "route": "structuredIntegration",
          "riskClass": "reversible",
          "preconditions": {"targetBundleIdentifier": "com.brave.Browser", "requiresFreshObservation": false},
          "verifier": {"kind": "externalEffectReconciled"},
          "reversal": {"kind": "none", "supported": false}
        },
        {
          "kind": "draftMessage",
          "targetBundleIdentifier": "com.brave.Browser",
          "parameters": {"recipient": "person@example.com", "subject": "Project", "body": "See the page."},
          "capability": "mail.draft",
          "executor": "service",
          "requiresApproval": true,
          "route": "structuredIntegration",
          "riskClass": "confirm",
          "preconditions": {"targetBundleIdentifier": "com.brave.Browser", "requiresFreshObservation": false},
          "verifier": {"kind": "externalEffectReconciled"},
          "reversal": {"kind": "reconcile", "supported": false}
        }
      ],
      "capabilities": ["app.control", "mail.draft"]
    }
    """))

    #expect(response.actions.map(\.requiresApproval) == [false, true])
    #expect(response.actions.map(\.riskClass) == [.reversible, .confirm])
}

@Test("canonical draftMessage rejects a reversible unapproved payload")
func canonicalDraftMessageRejectsReversiblePayload() {
    #expect(throws: NativePlanDecodingError.self) {
        _ = try NativePlanResponse.decode(data("""
        {
          "planId": "plan-draft-rejected",
          "status": "awaiting_approval",
          "fingerprint": "fp-draft-rejected",
          "actions": [{
            "kind": "draftMessage",
            "targetBundleIdentifier": "com.brave.Browser",
            "parameters": {"recipient": "person@example.com", "subject": "Hello", "body": "Draft only"},
            "capability": "mail.draft",
            "executor": "service",
            "requiresApproval": false,
            "route": "structuredIntegration",
            "riskClass": "reversible",
            "preconditions": {"targetBundleIdentifier": "com.brave.Browser", "requiresFreshObservation": false},
            "verifier": {"kind": "externalEffectReconciled"},
            "reversal": {"kind": "reconcile", "supported": false}
          }],
          "capabilities": ["mail.draft"]
        }
        """))
    }
}

@Test("control plans reject the legacy generic insertText action")
func controlPlanRejectsGenericInsertText() {
    #expect(throws: NativePlanDecodingError.self) {
        _ = try NativePlanResponse.decode(data(validInsertJSON))
    }
}
