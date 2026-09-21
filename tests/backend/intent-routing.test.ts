import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

import {
  parseStrictTypeSafeResponse,
  type StrictTypeSafeQuestion,
} from "../../convex/lib/typesafe";
import {
  ACTION_KINDS,
  buildIntentQuestions,
  validateIntentRouteRequest,
  type IntentRouteRequest,
} from "../../convex/lib/intent_contract";
import {
  DEFAULT_INTENT_POLICY,
  buildActionProposal,
  decideFallback,
  parseFallbackDecision,
  decideIntent,
  splitIntentScenarios,
} from "../../convex/lib/intent_policy";

const questionChoices: Record<string, StrictTypeSafeQuestion> = {
  intent: { choices: ["action", "clarify", "unsupported"] },
  app: { choices: ["none", "focused", "reader"] },
  action: { choices: ["none", "scroll"] },
  tool: { choices: ["none", "nativeAccessibility"] },
  target: { choices: ["none", "reader"] },
  requiredSlots: { choices: ["complete", "missing"] },
  risk: { choices: ["reversible", "confirm", "unsupported"] },
  clarification: { choices: ["notNeeded", "needed", "abstain"] },
};

function strictResponse(
  answers: Record<string, Record<string, unknown>> = {
    intent: {
      type: "choice",
      questionId: "intent",
      choice: "action",
      probabilities: {
        action: 0.94,
        clarify: 0.04,
        unsupported: 0.02,
      },
      confidence: 0.94,
    },
    action: {
      type: "choice",
      questionId: "action",
      choice: "scroll",
      probabilities: { none: 0.04, scroll: 0.96 },
      confidence: 0.96,
    },
    app: {
      type: "choice",
      questionId: "app",
      choice: "focused",
      probabilities: { none: 0.01, focused: 0.96, reader: 0.03 },
      confidence: 0.96,
    },
    tool: {
      type: "choice",
      questionId: "tool",
      choice: "nativeAccessibility",
      probabilities: { none: 0.01, nativeAccessibility: 0.99 },
      confidence: 0.99,
    },
    target: {
      type: "choice",
      questionId: "target",
      choice: "reader",
      probabilities: { none: 0.01, reader: 0.99 },
      confidence: 0.99,
    },
    requiredSlots: {
      type: "choice",
      questionId: "requiredSlots",
      choice: "complete",
      probabilities: { complete: 0.99, missing: 0.01 },
      confidence: 0.99,
    },
    risk: {
      type: "choice",
      questionId: "risk",
      choice: "reversible",
      probabilities: { reversible: 0.99, confirm: 0.005, unsupported: 0.005 },
      confidence: 0.99,
    },
    clarification: {
      type: "choice",
      questionId: "clarification",
      choice: "notNeeded",
      probabilities: { notNeeded: 0.99, needed: 0.005, abstain: 0.005 },
      confidence: 0.99,
    },
  },
): unknown {
  return { model: "jev-test", answers };
}

describe("strict Jev response validation", () => {
  it("requires complete independent answers and preserves distribution metrics", () => {
    const parsed = parseStrictTypeSafeResponse(
      strictResponse(),
      questionChoices,
    );
    expect(parsed.answers.intent.choice).toBe("action");
    expect(parsed.answers.intent.selectedProbability).toBe(0.94);
    expect(parsed.answers.intent.topTwoMargin).toBeCloseTo(0.90);
    expect(parsed.answers.action.confidence).toBe(0.96);
  });

  it.each([
    ["missing confidence", { confidence: undefined }, "confidence"],
    ["unknown choice", { choice: "other" }, "choice"],
    [
      "malformed probabilities",
      { probabilities: { none: 0.5, scroll: 0.5 } },
      "probabilities",
    ],
    ["mismatched question ID", { questionId: "target" }, "question"],
  ])("rejects %s", (_label, change, message) => {
    const response = strictResponse();
    const answer = (
      response as { answers: Record<string, Record<string, unknown>> }
    ).answers.intent;
    Object.assign(answer, change);
    expect(() =>
      parseStrictTypeSafeResponse(response, questionChoices),
    ).toThrow(message);
  });

  it("rejects extra answers and contradictory answer fields", () => {
    const extraAnswer = strictResponse({
      ...(
        strictResponse() as { answers: Record<string, Record<string, unknown>> }
      ).answers,
      extra: {
        type: "choice",
        questionId: "extra",
        choice: "none",
        probabilities: { none: 1 },
        confidence: 1,
      },
    });
    expect(() =>
      parseStrictTypeSafeResponse(extraAnswer, questionChoices),
    ).toThrow("question");

    const contradictory = strictResponse();
    const answer = (
      contradictory as { answers: Record<string, Record<string, unknown>> }
    ).answers.intent;
    answer.choice = "dictation";
    expect(() =>
      parseStrictTypeSafeResponse(contradictory, questionChoices),
    ).toThrow(/choice/);

    const extraField = strictResponse();
    const answerWithExtra = (
      extraField as { answers: Record<string, Record<string, unknown>> }
    ).answers.intent;
    answerWithExtra.providerNote = "untrusted";
    expect(() =>
      parseStrictTypeSafeResponse(extraField, questionChoices),
    ).toThrow("unknown fields");
  });
});

describe("intent request contract and policy", () => {
const request: IntentRouteRequest = {
    deviceId: "device-intent-1",
    sessionId: "session-1",
    utteranceId: "utterance-1",
    contextRevision: 1,
    utterance: "Scroll down",
    mode: "auto",
    context: {
      focusedAppBundleIdentifier: "com.example.Reader",
      focusedRole: "AXWebArea",
      editable: false,
      targetCandidates: [
        {
          id: "reader",
          label: "Reader",
          bundleIdentifier: "com.example.Reader",
          kind: "app",
        },
      ],
    },
    supportedActions: ["scroll"],
    supportedTools: ["nativeAccessibility"],
    supportedCapabilities: ["app.control"],
  policyVersion: DEFAULT_INTENT_POLICY.version,
};

const answer = (choice: string) => ({
  choice,
  confidence: 0.99,
  selectedProbability: 0.99,
  topTwoMargin: 0.98,
});

  it("never promotes app candidates to controls or guesses unnamed launch targets", () => {
    const broad: IntentRouteRequest = {
      ...request,
      supportedActions: [...ACTION_KINDS],
    };
    expect(
      buildActionProposal(
        { ...broad, utterance: "Open it" },
        "openApplication",
        "reader",
      ),
    ).toBeNull();
    expect(
      buildActionProposal(
        { ...broad, utterance: "Open Reader" },
        "openApplication",
        "reader",
      ),
    ).not.toBeNull();
    expect(
      buildActionProposal(
        { ...broad, utterance: "Select the highlighted item" },
        "select",
        "reader",
      ),
    ).toBeNull();
    expect(
      buildActionProposal(
        { ...broad, utterance: "Focus the search field" },
        "focus",
        "reader",
      ),
    ).toBeNull();
    const otherApp = {
      ...broad,
      context: {
        ...broad.context,
        focusedAppBundleIdentifier: "com.example.Other",
      },
    };
    expect(buildActionProposal(otherApp, "scroll", "reader")).toBeNull();
  });

  it("preserves shortcut semantics instead of typing bare A, C or V", () => {
    const broad = { ...request, supportedActions: [...ACTION_KINDS] };
    for (const [utterance, key] of [
      ["select all", "A"],
      ["copy", "C"],
      ["paste", "V"],
    ]) {
      expect(
        buildActionProposal({ ...broad, utterance }, "press", "reader")
          ?.parameters,
      ).toEqual({ key, modifiers: "Command" });
    }
    expect(
      buildActionProposal(broad, "press", "reader", {
        key: "C",
        modifiers: "Shift",
      }),
    ).toBeNull();
  });

  it("binds visual context to finite window geometry and rejects expired observations", () => {
    const observation = {
      id: "obs-1",
      displayId: "1",
      windowId: "2",
      observedAt: Date.now(),
      geometry: { x: 0, y: 10, width: 800, height: 600, scale: 2 },
      imageDataUrl: "data:image/png;base64,AAAA",
    };
    expect(
      validateIntentRouteRequest({ ...request, observation }).observation,
    ).toEqual(observation);
    expect(() =>
      validateIntentRouteRequest({
        ...request,
        observation: {
          ...observation,
          geometry: { ...observation.geometry, scale: 0 },
        },
      }),
    ).toThrow();
    expect(() =>
      validateIntentRouteRequest({
        ...request,
        observation: { ...observation, observedAt: Date.now() - 31_000 },
      }),
    ).toThrow();
    expect(() =>
      validateIntentRouteRequest({
        ...request,
        observation: { ...observation, geometry: undefined },
      }),
    ).toThrow();
  });

  it("validates the CloudSession request shape and rejects unsafe revisions", () => {
    expect(validateIntentRouteRequest(request)).toEqual(request);
    expect(() =>
      validateIntentRouteRequest({ ...request, utteranceId: "bad id" }),
    ).toThrow("utteranceId");
    expect(() =>
      validateIntentRouteRequest({ ...request, contextRevision: -1 }),
    ).toThrow("contextRevision");
    expect(() =>
      validateIntentRouteRequest({
        ...request,
        context: {
          ...request.context,
          targetCandidates: [
            {
              id: "reader",
              label: "Reader",
              kind: "app",
              bundleIdentifier: "com.example.Reader",
            },
            {
              id: "reader",
              label: "Duplicate",
              kind: "app",
            },
          ],
        },
      }),
    ).toThrow("candidate");
  });

  it("keeps all registered controls in the bounded action vocabulary", () => {
    expect(ACTION_KINDS).toEqual([
      "openApplication",
      "scroll",
      "focus",
      "select",
      "press",
    ]);
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
    expect(questions.action.choices).toEqual(["none", "scroll"]);
  });

  it("shares the English-only ambiguity and control semantics with live evaluation", () => {
    const questions = buildIntentQuestions({
      ...request,
      supportedActions: [...ACTION_KINDS],
    });
    const prompt = JSON.stringify(questions);
    expect(prompt).toContain("English");
    expect(prompt).toContain("sole candidate");
    expect(prompt).toContain("without activating");
    expect(prompt).toContain("allowlisted");
    expect(prompt).toContain("intent-questions-v3");
  });

  it("abstains while the policy is unmeasured, even with a high-confidence proposal", () => {
    expect(
      decideIntent({
        request,
        answers: {
          intent: {
            choice: "action",
            confidence: 0.99,
            selectedProbability: 0.99,
            topTwoMargin: 0.98,
          },
          action: {
            choice: "scroll",
            confidence: 0.99,
            selectedProbability: 0.99,
            topTwoMargin: 0.98,
          },
          target: {
            choice: "reader",
            confidence: 0.99,
            selectedProbability: 0.99,
            topTwoMargin: 0.98,
          },
        },
        grants: [
          {
            capability: "app.control",
            target: "com.example.Reader",
            expiresAt: Date.now() + 1000,
          },
        ],
        policy: { ...DEFAULT_INTENT_POLICY, status: "unmeasured" },
      }),
    ).toMatchObject({ decision: "abstain", reason: "policy_unmeasured" });
  });

  it("keeps the Mac Control request free of a legacy dictation mode", () => {
    const commandRequest: IntentRouteRequest = {
      ...request,
      mode: "commands",
      supportedCapabilities: ["app.control"],
    };
    expect(() =>
      validateIntentRouteRequest({ ...commandRequest, mode: "dictation" }),
    ).toThrow("intent mode");
    expect(
      decideFallback({
        request: commandRequest,
        grants: [],
        intent: "unsupported",
      }),
    ).toMatchObject({ decision: "unsupported", action: null });
  });

  it("normalizes fallback key actions to the native key vocabulary", () => {
    const pressRequest: IntentRouteRequest = {
      ...request,
      utterance: "Press arrow down",
      supportedActions: ["press"],
      supportedCapabilities: ["app.input"],
    };
    expect(buildActionProposal(pressRequest, "press", "reader")).toMatchObject({
      kind: "press",
      parameters: { key: "ArrowDown" },
      capability: "app.input",
    });
    expect(
      parseFallbackDecision({
        intent: "action",
        actionKind: "press",
        targetId: "reader",
        parameters: { key: "A", modifiers: "Command" },
      }),
    ).toMatchObject({ parameters: { key: "A", modifiers: "Command" } });
  });

  it("rejects fallback fields that can smuggle arbitrary execution parameters", () => {
    expect(() =>
      parseFallbackDecision({
        intent: "action",
        actionKind: "press",
        targetId: "reader",
        parameters: { key: "rm -rf /" },
      }),
    ).toThrow("fallback key is invalid");
    expect(() =>
      parseFallbackDecision({
        intent: "action",
        actionKind: "press",
        targetId: "reader",
        parameters: { command: "rm -rf /" },
      }),
    ).toThrow("not allowed");
    expect(() =>
      parseFallbackDecision({
        intent: "action",
        actionKind: "runShellCommand",
        targetId: "reader",
      }),
    ).toThrow("action");
  });

  it("keeps text fallback inside the supported action and grant boundary", () => {
    const pressRequest: IntentRouteRequest = {
      ...request,
      utterance: "Press arrow down",
      supportedActions: ["press"],
      supportedCapabilities: ["app.input"],
    };
    const grants = [
      {
        capability: "app.input",
        target: "com.example.Reader",
        expiresAt: Date.now() + 60_000,
      },
    ];
    expect(
      decideFallback({
        request: pressRequest,
        intent: "action",
        actionKind: "press",
        targetId: "reader",
        grants,
      }),
    ).toMatchObject({
      decision: "execute",
      action: { parameters: { key: "ArrowDown" } },
    });
    expect(
      decideFallback({
        request: pressRequest,
        intent: "action",
        actionKind: "press",
        targetId: "reader",
        grants: [],
      }),
    ).toMatchObject({ decision: "clarify", action: null });
  });

  it("does not propose an action absent from the selected app registry metadata", () => {
    const advertised = {
      ...request,
      context: {
        ...request.context,
        targetCandidates: [
          {
            ...request.context.targetCandidates[0],
            kind: "app" as const,
            supportedActions: ["openApplication" as const],
          },
        ],
      },
    };
    expect(buildActionProposal(advertised, "scroll", "reader")).toBeNull();
  });

  it("requires the advertised tool route before executing a Jev choice", () => {
    const withoutNative = {
      ...request,
      supportedTools: ["structuredIntegration" as const],
    };
    expect(
      decideIntent({
        request: withoutNative,
        answers: {
          intent: answer("action"),
          app: answer("focused"),
          action: answer("scroll"),
          tool: answer("nativeAccessibility"),
          target: answer("reader"),
          requiredSlots: answer("complete"),
          risk: answer("reversible"),
          clarification: answer("notNeeded"),
        },
        grants: [
          {
            capability: "app.control",
            target: "com.example.Reader",
            expiresAt: Date.now() + 60_000,
          },
        ],
        policy: DEFAULT_INTENT_POLICY,
      }),
    ).toMatchObject({
      decision: "unsupported",
      reason: "tool_not_supported",
    });
  });

  it("rejects generic text entry instead of treating it as a control action", () => {
    const controlRequest: IntentRouteRequest = {
      ...request,
      utterance: "Type open Brave",
      supportedActions: ["press"],
      supportedCapabilities: ["app.input"],
    };
    expect(
      decideFallback({
        request: controlRequest,
        intent: "unsupported",
        grants: [],
      }),
    ).toMatchObject({ decision: "unsupported", action: null });
  });
});

describe("intent fixture coverage", () => {
  function fixtureAction(expected: {
    intent: string;
    action?: string;
  }): string | undefined {
    return expected.action;
  }

  it("contains at least 300 grouped English scenarios covering every registered control", () => {
    const fixture = JSON.parse(
      readFileSync(
        resolve(process.cwd(), "tests/fixtures/intent/en.json"),
        "utf8",
      ),
    ) as {
      groups: Array<{
        id: string;
        scenarios: Array<{
          expected: { intent: string; action?: string };
          supportedActions: string[];
        }>;
      }>;
    };
    const scenarios = fixture.groups.flatMap((group) => group.scenarios);
    expect(fixture.groups.length).toBeGreaterThanOrEqual(10);
    expect(scenarios.length).toBeGreaterThanOrEqual(300);
    for (const action of ACTION_KINDS) {
      expect(
        scenarios.some(
          (scenario) => fixtureAction(scenario.expected) === action,
        ),
      ).toBe(true);
    }
    for (const scenario of scenarios) {
      expect(scenario.supportedActions.length).toBeGreaterThan(0);
      if (scenario.expected.action !== undefined) {
        expect(scenario.supportedActions).toContain(scenario.expected.action);
      }
    }
    expect(
      new Set(scenarios.map((scenario) => fixtureAction(scenario.expected)))
        .size,
    ).toBeGreaterThanOrEqual(ACTION_KINDS.length);
  });

  it("rejects duplicate scenario content while allowing distinct IDs", () => {
    const fixture = JSON.parse(
      readFileSync(
        resolve(process.cwd(), "tests/fixtures/intent/en.json"),
        "utf8",
      ),
    ) as { groups: Array<{ scenarios: Array<Record<string, unknown>> }> };
    const scenarios = fixture.groups.flatMap((group) => group.scenarios);
    const content = scenarios.map((scenario) => {
      const { id: _id, ...withoutId } = scenario;
      return JSON.stringify(withoutId);
    });
    expect(new Set(content).size).toBe(content.length);
  });

  it("keeps scenario families together in deterministic development/calibration/holdout splits", () => {
    const fixture = JSON.parse(
      readFileSync(
        resolve(process.cwd(), "tests/fixtures/intent/en.json"),
        "utf8",
      ),
    ) as {
      groups: Array<{
        id: string;
        category: string;
        scenarios: Array<{ id: string }>;
      }>;
    };
    const first = splitIntentScenarios(fixture.groups, 17);
    const second = splitIntentScenarios(fixture.groups, 17);
    expect(second).toEqual(first);
    const byGroup = new Map<string, string>();
    for (const split of ["development", "calibration", "holdout"] as const) {
      for (const scenario of first[split]) {
        const groupId = scenario.id.split("/")[0];
        const previous = byGroup.get(groupId);
        if (previous !== undefined) expect(previous).toBe(split);
        byGroup.set(groupId, split);
      }
    }
    expect(first.development).toHaveLength(160);
    expect(first.calibration).toHaveLength(80);
    expect(first.holdout).toHaveLength(80);

    for (const split of ["development", "calibration", "holdout"] as const) {
      const categories = new Set(
        fixture.groups
          .filter((group) => byGroup.get(group.id) === split)
          .map((group) => group.category),
      );
      expect(categories.size).toBeGreaterThanOrEqual(10);
    }
  });
});
