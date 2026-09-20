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
  intent: { choices: ["dictation", "action", "clarify", "unsupported"] },
  action: { choices: ["none", "scroll", "insertText"] },
};

function strictResponse(
  answers: Record<string, Record<string, unknown>> = {
    intent: {
      type: "choice",
      questionId: "intent",
      choice: "action",
      probabilities: {
        dictation: 0.02,
        action: 0.94,
        clarify: 0.03,
        unsupported: 0.01,
      },
      confidence: 0.94,
    },
    action: {
      type: "choice",
      questionId: "action",
      choice: "scroll",
      probabilities: { none: 0.01, scroll: 0.96, insertText: 0.03 },
      confidence: 0.96,
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
    expect(parsed.answers.intent.topTwoMargin).toBeCloseTo(0.91);
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
    ).toThrow(/probabilit/);

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
    supportedActions: ["scroll", "insertText"],
    supportedCapabilities: ["app.control"],
    policyVersion: DEFAULT_INTENT_POLICY.version,
  };

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
      "insertText",
      "openURL",
      "attachFile",
      "sendEmail",
    ]);
    const questions = buildIntentQuestions(request);
    expect(Object.keys(questions)).toEqual(["intent", "action", "target"]);
    expect(questions.action.choices).toEqual(["none", "scroll", "insertText"]);
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
    expect(prompt).toContain("intent-questions-v2");
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

  it("does not let model output override Commands only mode", () => {
    const commandRequest: IntentRouteRequest = {
      ...request,
      mode: "commands",
      context: { ...request.context, editable: true },
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
      decideIntent({
        request: commandRequest,
        grants,
        policy: DEFAULT_INTENT_POLICY,
        answers: {
          intent: {
            choice: "dictation",
            confidence: 1,
            selectedProbability: 1,
            topTwoMargin: 1,
          },
        },
      }).action,
    ).toBeNull();
    expect(
      decideFallback({ request: commandRequest, grants, intent: "dictation" })
        .action,
    ).toBeNull();
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

  it("preserves dictation text while replacing the current selection", () => {
    const dictationRequest: IntentRouteRequest = {
      ...request,
      utterance: "Type open Brave",
      context: { ...request.context, editable: true },
      supportedActions: ["insertText"],
      supportedCapabilities: ["app.input"],
    };
    expect(
      decideFallback({
        request: dictationRequest,
        intent: "dictation",
        grants: [
          {
            capability: "app.input",
            target: "com.example.Reader",
            expiresAt: Date.now() + 60_000,
          },
        ],
      }),
    ).toMatchObject({
      decision: "dictation",
      action: {
        kind: "insertText",
        parameters: { text: "open Brave", replaceSelection: true },
      },
    });
  });
});

describe("intent fixture coverage", () => {
  function fixtureAction(expected: {
    intent: string;
    action?: string;
  }): string | undefined {
    return (
      expected.action ??
      (expected.intent === "dictation" ? "insertText" : undefined)
    );
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
