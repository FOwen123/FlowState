import Foundation
import Testing
@testable import FlowStateCore

@Test("normalized English insert plan maps to a native action")
func englishInsertPlanDecodes() throws {
    let response = try NativePlanResponse.decode(data("""
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

    #expect(response.planId == "plan-en")
    #expect(response.actions[0].desktopAction == .insertText("Hello from FlowState"))
    #expect(response.actions[0].targetBundleIdentifier == "com.apple.TextEdit")
    #expect(response.actions[0].capability == "app.input")
    #expect(response.actions[0].executor == "desktop")
    #expect(response.actions[0].summary == "Insert text into com.apple.TextEdit: Hello from FlowState")
}

@Test("normalized Traditional Chinese insert plan defaults to replacing selection")
func traditionalChineseInsertPlanDecodes() throws {
    let response = try NativePlanResponse.decode(data("""
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

    #expect(response.actions[0].desktopAction == .insertText("請幫我打開這個頁面"))
    #expect(response.actions[0].requiresApproval == true)
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

@Test("execution metadata is accepted separately from the normalized response")
func executionMetadataWrapper() throws {
    let response = try NativePlanResponse.decode(data(validInsertJSON))
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
