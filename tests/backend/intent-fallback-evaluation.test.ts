import { describe, expect, it, vi } from "vitest";

import {
  FALLBACK_EVALUATION_LIMITS,
  INTENT_FALLBACK_INSTRUCTIONS,
  buildIntentFallbackRequest,
  parseIntentFallbackOutput,
  validateFallbackEvaluationBudget,
} from "../../convex/lib/intent_fallback";
import {
  compareEvaluationPrediction,
  frozenJevGate,
  summarizeEvaluationRows,
} from "../../scripts/evaluate-intent-fallback";
import { createOpenAIClient } from "../../convex/lib/openai";

describe("intent fallback prompt and parser", () => {
  it("keeps the fallback prompt identical to the frozen runtime envelope", () => {
    const request = buildIntentFallbackRequest({
      utterance: "Scroll down",
      context: { targetCandidates: [{ id: "reader", label: "Reader" }] },
    });
    expect(request.instructions).toBe(INTENT_FALLBACK_INSTRUCTIONS);
    expect(request.input).toEqual([
      {
        role: "user",
        content: [
          {
            type: "input_text",
            text: 'Utterance: Scroll down\nContext: {"targetCandidates":[{"id":"reader","label":"Reader"}]}\nChoose only a registered Mac Control action and supplied target. Generic dictation or text entry belongs to the separate Dictation shortcut and is unsupported. Return JSON {"intent":"action|clarify|unsupported","actionKind":"...","targetId":"...","parameters":{}}. For clarify and unsupported, return only the intent and omit actionKind, targetId, and parameters. For scroll parameters use only direction up|down and amount 1-100; for focus use only role and label; for select use only label; for press use only ArrowUp, ArrowDown, ArrowLeft, ArrowRight, PageUp, PageDown, Home, End, Tab, Escape, Enter, A, C, or V with optional Shift or Command. Do not return parameters for other actions. Never include confidence, permissions, shell commands, URLs, file IDs, email content, or generic typed text.',
          },
        ],
      },
    ]);
  });

  it("adds an image as a separate input part without changing the text prompt", () => {
    const request = buildIntentFallbackRequest({
      utterance: "Focus the Save button",
      context: { targetCandidates: [{ id: "save", label: "Save" }] },
      imageDataUrl: "data:image/png;base64,synthetic",
    });
    const content = request.input[0]?.content;
    expect(content).toHaveLength(2);
    expect(content?.[1]).toEqual({
      type: "input_image",
      image_url: "data:image/png;base64,synthetic",
    });
  });

  it.each([
    '{"intent":"clarify"}',
    '```json\n{"intent":"unsupported"}\n```',
    '{"intent":"action","actionKind":"scroll","targetId":"reader","parameters":{"direction":"down","amount":5}}',
  ])("parses bounded JSON output: %s", (output) => {
    expect(parseIntentFallbackOutput(output)).toBeDefined();
  });

  it.each([
    "not json",
    '{"intent":"clarify","targetId":"reader"}',
    '{"intent":"action","actionKind":"runShellCommand","targetId":"reader"}',
    '{"intent":"action","actionKind":"press","targetId":"reader","parameters":{"key":"rm -rf /"}}',
    '{"intent":"action","actionKind":"scroll","targetId":"reader","parameters":{"amount":101}}',
    '{"intent":"unsupported","permissions":"grant"}',
  ])("rejects unsafe or malformed output: %s", (output) => {
    expect(() => parseIntentFallbackOutput(output)).toThrow();
  });
});

describe("intent fallback evaluation bounds", () => {
  it("exposes the requested hard limits", () => {
    expect(FALLBACK_EVALUATION_LIMITS).toEqual({
      maxCases: 24,
      maxCalls: 24,
      maxTokens: 60_000,
    });
  });

  it("accepts bounded positive budgets and rejects larger or non-positive values", () => {
    expect(
      validateFallbackEvaluationBudget(FALLBACK_EVALUATION_LIMITS),
    ).toEqual(FALLBACK_EVALUATION_LIMITS);
    expect(() =>
      validateFallbackEvaluationBudget({
        maxCases: 25,
        maxCalls: 24,
        maxTokens: 60_000,
      }),
    ).toThrow("maxCases");
    expect(() =>
      validateFallbackEvaluationBudget({
        maxCases: 24,
        maxCalls: 25,
        maxTokens: 60_000,
      }),
    ).toThrow("maxCalls");
    expect(() =>
      validateFallbackEvaluationBudget({
        maxCases: 24,
        maxCalls: 24,
        maxTokens: 60_001,
      }),
    ).toThrow("maxTokens");
    expect(() =>
      validateFallbackEvaluationBudget({
        maxCases: 0,
        maxCalls: 40,
        maxTokens: 100_000,
      }),
    ).toThrow("positive");
  });
});

describe("fallback provider accounting", () => {
  it("returns usage and forwards the bounded output budget", async () => {
    const fetch = vi.fn<typeof globalThis.fetch>().mockResolvedValue(
      new Response(
        JSON.stringify({
          id: "resp_synthetic",
          output_text: '{"intent":"clarify"}',
          usage: { input_tokens: 12, output_tokens: 4, total_tokens: 16 },
        }),
      ),
    );
    const client = createOpenAIClient({
      apiKey: "test-key",
      model: "gpt-test",
      fetch,
    });
    await expect(
      client.createResponse({
        input: "synthetic",
        maxOutputTokens: 1_024,
      }),
    ).resolves.toMatchObject({
      usage: { input_tokens: 12, output_tokens: 4, total_tokens: 16 },
    });
    expect(JSON.parse(String(fetch.mock.calls[0]?.[1]?.body))).toMatchObject({
      max_output_tokens: 1_024,
    });
  });
});

describe("frozen Jev gate and report metrics", () => {
  const pass = {
    actual: { intent: "action", action: "scroll", target: "reader" },
    probabilities: { intent: 0.9, action: 0.95, target: 0.92 },
    topTwoMargin: { intent: 0.85, action: 0.86, target: 0.84 },
    confidence: { intent: 0.9, action: 0.91, target: 0.88 },
  };

  it("requires all three stages for an action and only intent otherwise", () => {
    expect(frozenJevGate(pass)).toBe(true);
    expect(
      frozenJevGate({
        ...pass,
        topTwoMargin: { ...pass.topTwoMargin, target: 0.79 },
      }),
    ).toBe(false);
    expect(
      frozenJevGate({
        ...pass,
        actual: { intent: "clarify", action: "none", target: "none" },
        topTwoMargin: { intent: 0.8, action: 0, target: 0 },
        probabilities: { intent: 0.8, action: 0, target: 0 },
        confidence: { intent: 0.8, action: 0, target: 0 },
      }),
    ).toBe(true);
  });

  it("compares expected intent and action/target without treating review as execution", () => {
    expect(
      compareEvaluationPrediction(
        { expected: { intent: "action", action: "scroll", target: "reader" } },
        {
          intent: "action",
          action: "scroll",
          target: "reader",
          decision: "execute",
          requiresApproval: true,
        },
      ),
    ).toBe(true);
    expect(
      compareEvaluationPrediction(
        { expected: { intent: "clarify", requiredClarification: true } },
        { intent: "clarify", decision: "clarify" },
      ),
    ).toBe(true);
    expect(
      compareEvaluationPrediction(
        { expected: { intent: "action", action: "scroll", target: "reader" } },
        { intent: "action", action: "scroll", target: "other" },
      ),
    ).toBe(false);
  });

  it("reports measured rows and leaves missing predictions unmeasured", () => {
    expect(
      summarizeEvaluationRows([
        {
          expected: { intent: "clarify", requiredClarification: true },
          baseline: { prediction: { intent: "clarify", decision: "clarify" } },
          cascade: {
            prediction: { intent: "clarify", decision: "clarify" },
            source: "jev",
          },
        },
        {
          expected: { intent: "action", action: "scroll", target: "reader" },
          baseline: { error: "provider_error" },
          cascade: { skipped: "provider_error" },
        },
      ]),
    ).toMatchObject({
      samples: 2,
      baseline: { predictions: 1, correct: 1, accuracy: 1 },
      cascade: { predictions: 1, correct: 1, accuracy: 1 },
    });
  });
});
