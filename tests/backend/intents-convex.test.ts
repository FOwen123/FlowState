import { afterEach, describe, expect, it, vi } from "vitest";
import { anyApi } from "convex/server";
import { convexTest } from "convex-test";

import schema from "../../convex/schema";

const modules = {
  ...import.meta.glob("../../convex/**/*.ts"),
  "../../convex/_generated/test-root.ts": async () => ({}),
};

afterEach(() => {
  delete process.env.TYPESAFE_API_KEY;
  delete process.env.FLOWSTATE_JEV_MODEL;
  vi.unstubAllGlobals();
  vi.unstubAllEnvs();
});

function request(overrides: Record<string, unknown> = {}) {
  return {
    deviceId: "intent-device",
    sessionId: "intent-session",
    utteranceId: "utterance-1",
    contextRevision: 0,
    utterance: "Scroll down",
    mode: "auto" as const,
    context: {
      focusedAppBundleIdentifier: "com.example.Reader",
      focusedRole: "AXWebArea",
      editable: false,
      targetCandidates: [
        {
          id: "reader",
          label: "Reader",
          bundleIdentifier: "com.example.Reader",
          kind: "app" as const,
          isRunning: true,
          supportedActions: ["scroll" as const],
          integrations: ["nativeAccessibility"],
        },
      ],
    },
    supportedActions: ["scroll" as const],
    supportedTools: ["nativeAccessibility" as const],
    supportedCapabilities: ["app.control"],
    policyVersion: "intent-v1",
    ...overrides,
  };
}

function strictJevResponse(
  choice = "action",
  action = "scroll",
  target = "reader",
) {
  return {
    model: "jev-1.13.0",
    answers: {
      intent: {
        type: "choice",
        questionId: "intent",
        choice,
        probabilities: {
          action: 0.96,
          clarify: 0.02,
          unsupported: 0.02,
        },
        confidence: 0.96,
      },
      action: {
        type: "choice",
        questionId: "action",
        choice: action,
        probabilities: { none: 0.01, scroll: 0.99 },
        confidence: 0.99,
      },
      app: {
        type: "choice",
        questionId: "app",
        choice: "focused",
        probabilities: { none: 0.01, focused: 0.99, reader: 0 },
        confidence: 0.98,
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
        choice: target,
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
  };
}

describe("authenticated intent route", () => {
  it("requires an active device owned by the authenticated user", async () => {
    const t = convexTest(schema, modules);
    const user = t.withIdentity({
      tokenIdentifier: "intent-owner",
      subject: "intent-owner",
    });
    await expect(user.action(anyApi.intents.route, request())).rejects.toThrow(
      "device",
    );
  });

  it("returns a review-only measured proposal and never dispatches an effect", async () => {
    process.env.TYPESAFE_API_KEY = "test-key";
    process.env.FLOWSTATE_JEV_MODEL = "jev-1.13.0";
    const calls: string[] = [];
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL) => {
        calls.push(String(input));
        return new Response(JSON.stringify(strictJevResponse()), {
          status: 200,
        });
      }),
    );
    const t = convexTest(schema, modules);
    const user = t.withIdentity({
      tokenIdentifier: "intent-owner",
      subject: "intent-owner",
    });
    await user.mutation(anyApi.workflows.registerDevice, {
      deviceId: "intent-device",
    });
    await user.mutation(anyApi.grants.grant, {
      deviceId: "intent-device",
      capability: "app.control",
      target: "com.example.Reader",
      expiresAt: Date.now() + 60_000,
    });
    const result = await user.action(anyApi.intents.route, request());
    expect(result).toMatchObject({
      decision: "execute",
      policyVersion: "intent-v1",
      action: { kind: "scroll", requiresApproval: true },
      model: { jev: "jev-1.13.0", fallback: null },
    });
    expect(result).toHaveProperty("confidence.intent");
    expect(
      typeof (result as { confidence: { intent: unknown } }).confidence.intent,
    ).toBe("number");
    expect("reason" in (result as object)).toBe(false);
    expect(calls).toEqual(["https://api.typesafe.ai/v1/systemone"]);
  });

  it("rejects a legacy observation retry without a payload binding", async () => {
    const t = convexTest(schema, modules);
    const user = t.withIdentity({
      tokenIdentifier: "intent-owner-revision",
      subject: "intent-owner-revision",
    });
    await user.mutation(anyApi.workflows.registerDevice, {
      deviceId: "intent-device",
    });
    await t.run(async (ctx) => {
      await ctx.db.insert("intentRequests", {
        ownerKey: "intent-owner-revision",
        deviceId: "intent-device",
        sessionId: "intent-session",
        utteranceId: "utterance-1",
        contextRevision: 0,
        status: "requires_observation",
        createdAt: Date.now(),
        updatedAt: Date.now(),
      });
    });
    await expect(
      user.action(anyApi.intents.route, request({ contextRevision: 1 })),
    ).rejects.toThrow("stale");
  });

  it("requires observation and upload grants for a single bounded visual fallback", async () => {
    process.env.TYPESAFE_API_KEY = "test-key";
    process.env.FLOWSTATE_JEV_MODEL = "jev-1.13.0";
    vi.stubEnv("OPENAI_API_KEY", "test-openai");
    vi.stubEnv("FLOWSTATE_PLANNER_MODEL", "test-vision");
    const urls: string[] = [];
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
        const url = String(input);
        urls.push(url);
        if (url.includes("typesafe")) {
          const response = strictJevResponse();
          response.answers.intent.confidence = 0.2;
          return new Response(
            JSON.stringify({
              ...response,
              usage: { input_tokens: 10, output_tokens: 0, total_tokens: 10 },
            }),
          );
        }
        const body = JSON.parse(String(init?.body)) as {
          max_output_tokens?: number;
          input: unknown;
        };
        expect(body.max_output_tokens).toBe(1024);
        expect(JSON.stringify(body.input)).toContain(
          "omit actionKind, targetId, and parameters",
        );
        return new Response(
          JSON.stringify({
            id: "fallback-1",
            usage: { input_tokens: 20, output_tokens: 5, total_tokens: 25 },
            output_text: JSON.stringify({
              intent: "action",
              actionKind: "scroll",
              targetId: "reader",
              parameters: { direction: "down", amount: 3 },
            }),
          }),
        );
      }),
    );
    const t = convexTest(schema, modules);
    const user = t.withIdentity({
      tokenIdentifier: "visual-owner",
      subject: "visual-owner",
    });
    await user.mutation(anyApi.workflows.registerDevice, {
      deviceId: "intent-device",
    });
    const grant = async (capability: string) =>
      user.mutation(anyApi.grants.grant, {
        deviceId: "intent-device",
        capability,
        target: "com.example.Reader",
        expiresAt: Date.now() + 60_000,
      });
    await grant("app.control");
    const visual = request({ utterance: "Scroll down in this view" });
    const visualResult = await user.action(anyApi.intents.route, visual);
    expect(visualResult).toMatchObject({
      decision: "clarify",
      requiresObservation: false,
    });
    await grant("app.observe");
    await grant("app.upload");
    const authorized = { ...visual, utteranceId: "visual-2" };
    expect(await user.action(anyApi.intents.route, authorized)).toMatchObject({
      requiresObservation: true,
      action: null,
    });
    await expect(
      user.action(anyApi.intents.route, {
        ...authorized,
        contextRevision: 1,
        utterance: "Open another app",
      }),
    ).rejects.toThrow("stale");
    const imageRequest = {
      ...authorized,
      contextRevision: 1,
      observation: {
        id: "obs-1",
        displayId: "1",
        windowId: "2",
        observedAt: Date.now(),
        geometry: { x: 0, y: 0, width: 800, height: 600, scale: 2 },
        imageDataUrl: "data:image/png;base64,AAAA",
      },
    };
    expect(await user.action(anyApi.intents.route, imageRequest)).toMatchObject(
      {
        decision: "execute",
        visionFallbackUsed: true,
        usage: { inputTokens: 30, outputTokens: 5, totalTokens: 35 },
        action: { kind: "scroll", requiresApproval: true },
        requiresObservation: false,
      },
    );
    expect(urls.filter((url) => url.includes("openai"))).toHaveLength(1);
    await expect(
      user.action(anyApi.intents.route, imageRequest),
    ).rejects.toThrow("duplicate");
    const rows = await t.run((ctx) => ctx.db.query("intentRequests").collect());
    expect(JSON.stringify(rows)).not.toContain("imageDataUrl");
    expect(JSON.stringify(rows)).not.toContain("Scroll down");
    vi.unstubAllEnvs();
  });

  it("does not apply measured thresholds to a different model", async () => {
    process.env.TYPESAFE_API_KEY = "test-key";
    process.env.FLOWSTATE_JEV_MODEL = "jev-unmeasured";
    const fetchMock = vi.fn();
    vi.stubGlobal("fetch", fetchMock);
    const t = convexTest(schema, modules);
    const user = t.withIdentity({
      tokenIdentifier: "model-owner",
      subject: "model-owner",
    });
    await user.mutation(anyApi.workflows.registerDevice, {
      deviceId: "intent-device",
    });
    expect(await user.action(anyApi.intents.route, request())).toMatchObject({
      decision: "abstain",
      action: null,
    });
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("fails closed on malformed Jev distributions", async () => {
    process.env.TYPESAFE_API_KEY = "test-key";
    process.env.FLOWSTATE_JEV_MODEL = "jev-1.13.0";
    vi.stubGlobal(
      "fetch",
      vi.fn(
        async () =>
          new Response(
            JSON.stringify({
              model: "jev-1.13.0",
              answers: {
                intent: {
                  type: "choice",
                  questionId: "intent",
                  choice: "action",
                  probabilities: { action: 1 },
                },
              },
            }),
            { status: 200 },
          ),
      ),
    );
    const t = convexTest(schema, modules);
    const user = t.withIdentity({
      tokenIdentifier: "intent-owner-invalid",
      subject: "intent-owner-invalid",
    });
    await user.mutation(anyApi.workflows.registerDevice, {
      deviceId: "intent-device",
    });
    const result = await user.action(
      anyApi.intents.route,
      request({ sessionId: "invalid-session" }),
    );
    expect(result).toMatchObject({ decision: "abstain" });
  });
});
