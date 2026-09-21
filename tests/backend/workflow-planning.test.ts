import { describe, expect, it } from "vitest";
import { normalizeModelPlan } from "../../convex/lib/action_plan";
import { buildPlannerRequest } from "../../convex/lib/plan_request";

describe("complete workflow planning", () => {
  it("preserves the request and advertises the full registered action contract", () => {
    const command = "Open Brave and search Hello World";
    const request = buildPlannerRequest(command, {
      supportedTools: ["nativeAccessibility", "structuredIntegration"],
      integrations: ["browser"],
      applicationCandidates: [
        {
          bundleIdentifier: "com.brave.Browser",
          displayName: "Brave",
          normalizedNames: ["brave"],
          supportedActions: ["openApplication", "openURL"],
          integrations: ["browser"],
        },
      ],
    });
    expect(JSON.stringify(request.input)).toContain(command);
    expect(JSON.stringify(request.input)).toContain("com.brave.Browser");
    expect(request.instructions).toContain("Do not drop any requested steps");
    expect(request.instructions).toContain("search query");
    expect(request.instructions).toContain("clarificationNeeded");
  });
});

it("accepts a clarification with no executable partial workflow", () => {
  expect(
    normalizeModelPlan({
      actions: [],
      explanation: "Deleting files is not supported.",
      clarificationNeeded: true,
    }),
  ).toMatchObject({ actions: [], capabilities: [], clarificationNeeded: true });
  expect(() =>
    normalizeModelPlan({
      actions: [],
      explanation: "Done",
      clarificationNeeded: false,
    }),
  ).toThrow();
  expect(() =>
    normalizeModelPlan({
      actions: [
        {
          kind: "openApplication",
          targetBundleIdentifier: "com.brave.Browser",
          parameters: {},
        },
      ],
      explanation: "Deletion is unsupported",
      clarificationNeeded: true,
    }),
  ).toThrow();
});

import { afterEach, vi } from "vitest";
import { resolveJevSingleAction } from "../../convex/lib/plan_request";

const availability = {
  supportedTools: ["nativeAccessibility" as const],
  integrations: [],
  applicationCandidates: [
    {
      bundleIdentifier: "com.example.Editor",
      displayName: "Editor",
      normalizedNames: ["editor"],
      supportedActions: [
        "openApplication" as const,
        "scroll" as const,
        "press" as const,
        "focus" as const,
      ],
      integrations: [],
    },
  ],
};
afterEach(() => {
  vi.unstubAllGlobals();
  vi.unstubAllEnvs();
});
function mockJev(route: string, action: string, probability = 0.99) {
  vi.stubEnv("TYPESAFE_API_KEY", "synthetic");
  vi.stubEnv("FLOWSTATE_JEV_MODEL", "jev-1.13.0");
  const fetch = vi.fn(async (_url: unknown, init: RequestInit | undefined) => {
    const body = JSON.parse(String(init?.body)) as {
      questions: Record<string, { criteria: Record<string, unknown> }>;
    };
    const answers = Object.fromEntries(
      Object.entries(body.questions).map(([id, q]) => {
        const choice =
          id === "route"
            ? route
            : (Object.keys(q.criteria).find((key) =>
                JSON.stringify(q.criteria[key]).includes(action),
              ) ?? "none");
        const keys = Object.keys(q.criteria);
        return [
          id,
          {
            type: "choice",
            choice,
            confidence: probability,
            probabilities: Object.fromEntries(
              keys.map((key) => [
                key,
                key === choice
                  ? probability
                  : (1 - probability) / (keys.length - 1),
              ]),
            ),
          },
        ];
      }),
    );
    return new Response(JSON.stringify({ model: "jev-1.13.0", answers }));
  });
  vi.stubGlobal("fetch", fetch);
  return fetch;
}
it.each([
  ["Hit the Escape key", "Escape", "press"],
  ["Move down a little", "Scroll down", "scroll"],
  ["Please focus the text field", "AXTextField", "focus"],
  ["Please open Editor", "Open Editor", "openApplication"],
])(
  "Jev resolves %s into a validated single action",
  async (command, candidate, kind) => {
    const fetch = mockJev("direct_action", candidate);
    const result = await resolveJevSingleAction(
      `Request: ${command}\nCurrently active application (context only): com.example.Editor`,
      availability,
    );
    expect(result?.actions).toHaveLength(1);
    expect(result?.actions[0].kind).toBe(kind);
    expect(fetch).toHaveBeenCalledTimes(1);
  },
);
it.each([
  ["workflow", 0.99],
  ["direct_action", 0.6],
])("uses the planner for %s at %s", async (route, confidence) => {
  mockJev(route, "Escape", confidence);
  expect(
    await resolveJevSingleAction(
      "Open Editor and search Hello World",
      availability,
    ),
  ).toBeNull();
});
it("falls back when Jev fails or no registered action matches", async () => {
  mockJev("direct_action", "unavailable");
  expect(
    await resolveJevSingleAction("Select the title", availability),
  ).toBeNull();
  vi.stubGlobal(
    "fetch",
    vi.fn(async () => {
      throw new Error("offline");
    }),
  );
  expect(await resolveJevSingleAction("Hit Escape", availability)).toBeNull();
});

import { anyApi } from "convex/server";
import { convexTest } from "convex-test";
import schema from "../../convex/schema";
const modules = {
  ...import.meta.glob("../../convex/**/*.ts"),
  "../../convex/_generated/test-root.ts": async () => ({}),
};
it("the production plan endpoint uses Jev's action without calling OpenAI", async () => {
  const fetch = mockJev("direct_action", "Escape");
  const user = convexTest(schema, modules).withIdentity({
    tokenIdentifier: "test|jev",
    subject: "jev",
  });
  await user.mutation(anyApi.workflows.registerDevice, {
    deviceId: "jev-device",
  });
  const { planId } = await user.mutation(anyApi.plans.createActionPlan, {
    deviceId: "jev-device",
    locale: "en",
    command:
      "Request: Hit the Escape key\nCurrently active application (context only): com.example.Editor",
    ...availability,
  });
  const plan = await user.action(anyApi.plans.resolveActionPlan, { planId });
  expect(plan.actions).toMatchObject([
    {
      kind: "press",
      parameters: { key: "Escape" },
      targetBundleIdentifier: "com.example.Editor",
    },
  ]);
  expect(fetch).toHaveBeenCalledTimes(1);
  expect(String(fetch.mock.calls[0][0])).toContain("typesafe");
});
it("a compound request reaches the planner intact after Jev selects workflow", async () => {
  const jev = mockJev("workflow", "Open Editor");
  const fetch = vi.fn(async (url: unknown, init: RequestInit | undefined) => {
    if (String(url).includes("typesafe")) return jev(url, init);
    return new Response(
      JSON.stringify({
        id: "test",
        output_text: JSON.stringify({
          actions: [
            {
              kind: "openApplication",
              targetBundleIdentifier: "com.example.Editor",
              parameters: {},
            },
            {
              kind: "scroll",
              targetBundleIdentifier: "com.example.Editor",
              parameters: { lines: -3 },
            },
          ],
          explanation: "Open and scroll",
          clarificationNeeded: false,
        }),
      }),
    );
  });
  vi.stubGlobal("fetch", fetch);
  vi.stubEnv("OPENAI_API_KEY", "synthetic");
  vi.stubEnv("FLOWSTATE_PLANNER_MODEL", "synthetic");
  const user = convexTest(schema, modules).withIdentity({
    tokenIdentifier: "test|workflow",
    subject: "workflow",
  });
  await user.mutation(anyApi.workflows.registerDevice, {
    deviceId: "workflow-device",
  });
  const command = "Open Editor and scroll down";
  const { planId } = await user.mutation(anyApi.plans.createActionPlan, {
    deviceId: "workflow-device",
    locale: "en",
    command,
    ...availability,
  });
  const plan = await user.action(anyApi.plans.resolveActionPlan, { planId });
  expect(plan.actions.map((a: { kind: string }) => a.kind)).toEqual([
    "openApplication",
    "scroll",
  ]);
  expect(fetch).toHaveBeenCalledTimes(2);
  expect(String(fetch.mock.calls[1][1]?.body)).toContain(command);
});
