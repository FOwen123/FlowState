import { describe, expect, it } from "vitest";

import {
  ACTION_KINDS,
  TOOL_KINDS,
  buildIntentQuestions,
  validateIntentRouteRequest,
  type IntentRouteRequest,
} from "../../convex/lib/intent_contract";
import {
  DEFAULT_INTENT_POLICY,
  decideIntent,
  parseFallbackDecision,
} from "../../convex/lib/intent_policy";
import { normalizeModelPlan } from "../../convex/lib/action_plan";

const request: IntentRouteRequest = {
  deviceId: "device-1",
  sessionId: "session-1",
  utteranceId: "utterance-1",
  contextRevision: 0,
  utterance: "Open Brave",
  mode: "control",
  context: {
    focusedAppBundleIdentifier: "com.example.Reader",
    focusedRole: "AXWebArea",
    editable: false,
    targetCandidates: [
      {
        id: "brave",
        label: "Brave",
        kind: "app",
        bundleIdentifier: "com.brave.Browser",
      },
    ],
  },
  supportedActions: ["openApplication", "scroll", "press"],
  supportedTools: ["nativeAccessibility", "structuredIntegration"],
  supportedCapabilities: ["app.open", "app.control", "app.input", "mail.send"],
  policyVersion: DEFAULT_INTENT_POLICY.version,
};

const answer = (
  choice: string,
  selectedProbability = 0.99,
  confidence = 0.99,
) => ({
  choice,
  confidence,
  selectedProbability,
  topTwoMargin: 0.98,
});

describe("Mac Control contract", () => {
  it("keeps structured service actions in createActionPlan rather than routeIntent", () => {
    expect(ACTION_KINDS).toEqual([
      "openApplication",
      "scroll",
      "focus",
      "select",
      "press",
      "click",
    ]);
    expect(() =>
      validateIntentRouteRequest({
        ...request,
        supportedActions: ["openURL"],
      }),
    ).toThrow(/action/i);
  });

  it("does not expose dictation or generic insertText", () => {
    expect(ACTION_KINDS).not.toContain("insertText");
    expect(() =>
      parseFallbackDecision({ intent: "dictation" }),
    ).toThrow(/intent/);
    expect(() =>
      normalizeModelPlan({
        actions: [
          {
            kind: "insertText",
            targetBundleIdentifier: "com.example.Reader",
            parameters: { text: "hello", replaceSelection: true },
          },
        ],
        explanation: "type text",
      }),
    ).toThrow(/registered|unsupported/);
  });

  it("asks bounded questions for app, action, tool, target, slots, risk, and clarification", () => {
    const questions = buildIntentQuestions(request);
    expect(Object.keys(questions)).toEqual([
      "intent",
      "app",
      "action",
      "tool",
      "target",
      "requiredSlots",
      "risk",
      "clarification",
    ]);
    expect(questions.intent.choices).toEqual([
      "action",
      "clarify",
      "unsupported",
    ]);
    expect(questions.app.choices).toContain("brave");
    expect(questions.tool.choices).toEqual([
      "none",
      "nativeAccessibility",
      "structuredIntegration",
    ]);
    expect(questions.requiredSlots.choices).toEqual(["complete", "missing"]);
    expect(questions.risk.choices).toEqual([
      "reversible",
      "confirm",
      "unsupported",
    ]);
    expect(questions.clarification.choices).toEqual([
      "notNeeded",
      "needed",
      "abstain",
    ]);
  });

  it("rejects a legacy dictation mode and requires the bounded tool list", () => {
    expect(() =>
      validateIntentRouteRequest({
        ...request,
        mode: "dictation",
      }),
    ).toThrow("intent mode");
    expect(() => {
      const { supportedTools: _supportedTools, ...legacy } = request;
      validateIntentRouteRequest(legacy);
    }).toThrow("supportedTools");
  });

  it("accepts bounded native application metadata for closed apps", () => {
    const validated = validateIntentRouteRequest({
      ...request,
      context: {
        ...request.context,
        targetCandidates: [
          {
            id: "brave",
            label: "Brave Browser",
            bundleIdentifier: "com.brave.Browser",
            kind: "app",
            isRunning: false,
            supportedActions: ["openApplication", "scroll"],
            integrations: ["nativeAccessibility", "structuredIntegration"],
          },
        ],
      },
    });
    expect(validated.context.targetCandidates[0]).toMatchObject({
      isRunning: false,
      supportedActions: ["openApplication", "scroll"],
      integrations: ["nativeAccessibility", "structuredIntegration"],
    });
  });

  it("rejects unbounded native application metadata", () => {
    expect(() =>
      validateIntentRouteRequest({
        ...request,
        context: {
          ...request.context,
          targetCandidates: [
            {
              id: "brave",
              label: "Brave Browser",
              bundleIdentifier: "com.brave.Browser",
              kind: "app",
              isRunning: "no",
              supportedActions: ["runShellCommand"],
              integrations: Array.from({ length: 17 }, () => "mail"),
            },
          ],
        },
      }),
    ).toThrow(/candidate|supportedActions|isRunning|integrations/);
  });

  it("keeps structured text-bearing actions in the plan contract", () => {
    const plan = normalizeModelPlan({
      actions: [
        {
          kind: "openURL",
          targetBundleIdentifier: "com.example.Reader",
          parameters: { url: "https://example.com/search?q=hello" },
        },
        {
          kind: "sendEmail",
          parameters: {
            recipient: "owner@example.com",
            subject: "Status",
            body: "The link is ready.",
          },
        },
      ],
      explanation: "Open the URL and prepare the reviewed message.",
      clarificationNeeded: false,
    });
    expect(plan.actions.map((action) => action.kind)).toEqual([
      "openURL",
      "sendEmail",
    ]);
  });

  it("keeps Jev risk and tool suggestions subordinate to deterministic policy", () => {
    const decision = decideIntent({
      request,
      answers: {
        intent: answer("action"),
        app: answer("brave"),
        action: answer("openApplication"),
        tool: answer("nativeAccessibility"),
        target: answer("brave"),
        requiredSlots: answer("complete"),
        risk: answer("reversible"),
        clarification: answer("notNeeded"),
      },
      grants: [
        {
          capability: "app.open",
          target: "com.brave.Browser",
          expiresAt: Date.now() + 60_000,
        },
      ],
      policy: DEFAULT_INTENT_POLICY,
    });
    expect(decision).toMatchObject({
      decision: "execute",
      action: { kind: "openApplication", requiresApproval: true },
    });

    const unsafeSuggestion = decideIntent({
      request,
      answers: {
        intent: answer("action"),
        app: answer("brave"),
        action: answer("openApplication"),
        tool: answer("nativeAccessibility"),
        target: answer("brave"),
        requiredSlots: answer("missing"),
        risk: answer("unsupported"),
        clarification: answer("notNeeded"),
      },
      grants: [],
      policy: DEFAULT_INTENT_POLICY,
    });
    expect(unsafeSuggestion.decision).toBe("clarify");
    expect(unsafeSuggestion.action).toBeNull();
  });

  it("abstains when Jev explicitly abstains and clarifies when required slots are missing", () => {
    const common = {
      request,
      grants: [],
      policy: DEFAULT_INTENT_POLICY,
      answers: {
        intent: answer("action"),
        app: answer("brave"),
        action: answer("openApplication"),
        tool: answer("nativeAccessibility"),
        target: answer("brave"),
        requiredSlots: answer("complete"),
        risk: answer("reversible"),
        clarification: answer("abstain"),
      },
    };
    expect(decideIntent(common)).toMatchObject({
      decision: "abstain",
      reason: "model_abstained",
    });
    expect(
      decideIntent({
        ...common,
        answers: {
          ...common.answers,
          requiredSlots: answer("missing"),
          clarification: answer("needed"),
        },
      }),
    ).toMatchObject({ decision: "clarify" });
  });

  it("uses a bounded registry name when the display label contains extra words", () => {
    const resolvedRequest: IntentRouteRequest = {
      ...request,
      context: {
        ...request.context,
        targetCandidates: [
          {
            id: "brave",
            label: "Brave Browser",
            normalizedNames: ["brave", "brave browser"],
            kind: "app",
            bundleIdentifier: "com.brave.Browser",
          },
        ],
      },
    };
    const answers = {
        intent: answer("action"),
        app: answer("brave"),
        action: answer("openApplication"),
        tool: answer("nativeAccessibility"),
        target: answer("brave"),
        requiredSlots: answer("complete"),
        risk: answer("reversible"),
        clarification: answer("notNeeded"),
      };
    const decision = decideIntent({
      request: resolvedRequest,
      answers,
      grants: [
        {
          capability: "app.open",
          target: "com.brave.Browser",
          expiresAt: Date.now() + 60_000,
        },
      ],
      policy: DEFAULT_INTENT_POLICY,
    });
    expect(decision).toMatchObject({ decision: "execute" });

    const noResolvedRequest: IntentRouteRequest = {
        ...resolvedRequest,
        context: {
          ...resolvedRequest.context,
          targetCandidates: [
            {
              id: "brave",
              label: "Brave Browser",
              kind: "app",
              bundleIdentifier: "com.brave.Browser",
            },
          ],
        },
      };
    const noResolvedName = decideIntent({
      request: noResolvedRequest,
      answers,
      grants: [
        {
          capability: "app.open",
          target: "com.brave.Browser",
          expiresAt: Date.now() + 60_000,
        },
      ],
      policy: DEFAULT_INTENT_POLICY,
    });
    expect(noResolvedName).toMatchObject({
      decision: "clarify",
      reason: "required_slots_invalid",
    });

    expect(
      validateIntentRouteRequest(resolvedRequest).context.targetCandidates[0],
    ).toMatchObject({
      normalizedNames: ["brave", "brave browser"],
    });
    expect(() =>
      validateIntentRouteRequest({
        ...resolvedRequest,
        context: {
          ...resolvedRequest.context,
          targetCandidates: [
            {
              ...resolvedRequest.context.targetCandidates[0],
              normalizedNames: Array.from({ length: 17 }, (_, index) => `name-${index}`),
            },
          ],
        },
      }),
    ).toThrow("normalizedNames");
  });
});
