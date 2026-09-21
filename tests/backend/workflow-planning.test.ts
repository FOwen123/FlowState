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
