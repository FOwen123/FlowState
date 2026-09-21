import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

import {
  normalizeModelPlan,
  type PlanAvailability,
  selectActionRoute,
} from "../../convex/lib/action_plan";

describe("multi-step control plan contracts", () => {
  it("decodes the canonical native compound-plan payload with per-step targets", () => {
    const payload = JSON.parse(
      readFileSync(
        resolve(process.cwd(), "tests/fixtures/control-plan-payload.json"),
        "utf8",
      ),
    ) as {
      availability: PlanAvailability;
      request: unknown;
      response: {
        planId: string;
        status: string;
        fingerprint: string;
        actions: unknown;
        capabilities: string[];
      };
    };
    const plan = normalizeModelPlan(payload.request, payload.availability);
    expect(payload.response).toMatchObject({
      planId: "plan-native-fixture",
      status: "awaiting_approval",
      capabilities: plan.capabilities,
      fingerprint: plan.fingerprint,
    });
    expect(payload.response.actions).toEqual(plan.actions);
    expect(plan.actions).toHaveLength(2);
    expect(plan.actions).toEqual([
      expect.objectContaining({
        kind: "openApplication",
        targetBundleIdentifier: "com.brave.Browser",
        parameters: {},
        capability: "app.open",
        executor: "desktop",
        requiresApproval: false,
        route: "nativeAccessibility",
        riskClass: "reversible",
        preconditions: {
          targetBundleIdentifier: "com.brave.Browser",
          requiresFreshObservation: false,
        },
        verifier: { kind: "boundedAction" },
        reversal: { kind: "none", supported: false },
      }),
      expect.objectContaining({
        kind: "scroll",
        targetBundleIdentifier: "com.brave.Browser",
        parameters: { lines: -3 },
        route: "nativeAccessibility",
      }),
    ]);
  });

  it("derives bounded route, risk, precondition, verifier, and reversal metadata per step", () => {
    const plan = normalizeModelPlan({
      actions: [
        {
          kind: "scroll",
          targetBundleIdentifier: "com.example.Reader",
          parameters: { lines: -3 },
        },
        {
          kind: "sendEmail",
          parameters: {
            recipient: "owner@example.com",
            subject: "Ready",
            body: "The project page is ready.",
          },
        },
        {
          kind: "scroll",
          targetBundleIdentifier: "com.example.Reader",
          parameters: { lines: 2 },
          visualTarget: {
            displayId: "display-1",
            windowId: "window-1",
            x: 10,
            y: 20,
            width: 800,
            height: 600,
            observedAt: Date.now(),
          },
        },
      ],
      explanation: "Scroll, prepare a message, and verify the current view.",
      clarificationNeeded: false,
    });

    expect(plan.actions[0]).toMatchObject({
      route: "nativeAccessibility",
      riskClass: "reversible",
      preconditions: {
        targetBundleIdentifier: "com.example.Reader",
        requiresFreshObservation: false,
      },
      verifier: { kind: "boundedAction" },
      reversal: { supported: false, kind: "none" },
    });
    expect(plan.actions[1]).toMatchObject({
      route: "structuredIntegration",
      riskClass: "confirm",
      requiresApproval: true,
      verifier: { kind: "externalEffectReconciled" },
      reversal: { supported: false, kind: "reconcile" },
    });
    expect(plan.actions[2]).toMatchObject({
      route: "visualComputerUse",
      preconditions: { requiresFreshObservation: true },
    });
  });

  it("uses the dedicated app.open grant for opening an application", () => {
    const plan = normalizeModelPlan({
      actions: [
        {
          kind: "openApplication",
          targetBundleIdentifier: "com.brave.Browser",
          parameters: {},
        },
      ],
      explanation: "Open the selected app.",
      clarificationNeeded: false,
    });

    expect(plan.actions[0]?.capability).toBe("app.open");
  });

  it("keeps route precedence deterministic", () => {
    expect(selectActionRoute("sendEmail", {})).toBe("structuredIntegration");
    expect(
      selectActionRoute("scroll", {
        structuredIntegration: true,
        nativeAccessibility: true,
        visualComputerUse: true,
      }),
    ).toBe("nativeAccessibility");
    expect(
      selectActionRoute("scroll", {
        nativeAccessibility: false,
        visualComputerUse: true,
      }),
    ).toBe("visualComputerUse");
    expect(() =>
      selectActionRoute("scroll", {
        nativeAccessibility: false,
        visualComputerUse: false,
      }),
    ).toThrow("execution route");
  });

  it("rejects service and visual routes that were not advertised", () => {
    expect(() =>
      normalizeModelPlan(
        {
          actions: [
            {
              kind: "sendEmail",
              parameters: {
                recipient: "owner@example.com",
                subject: "Ready",
                body: "The project is ready.",
              },
            },
          ],
          explanation: "Prepare the approved message.",
          clarificationNeeded: false,
        },
        {
          supportedTools: ["nativeAccessibility"],
          integrations: [],
        },
      ),
    ).toThrow(/structuredIntegration|integration/);

    expect(() =>
      normalizeModelPlan(
        {
          actions: [
            {
              kind: "scroll",
              targetBundleIdentifier: "com.example.Reader",
              parameters: { lines: -2 },
              visualTarget: {
                displayId: "display-1",
                windowId: "window-1",
                x: 0,
                y: 0,
                width: 800,
                height: 600,
                observedAt: Date.now(),
              },
            },
          ],
          explanation: "Scroll in the current view.",
          clarificationNeeded: false,
        },
        {
          supportedTools: ["nativeAccessibility"],
          integrations: [],
        },
      ),
    ).toThrow("visualComputerUse");
  });

  it("requires a concrete target for openURL plans", () => {
    expect(() =>
      normalizeModelPlan({
        actions: [
          {
            kind: "openURL",
            parameters: { url: "https://example.com" },
          },
        ],
        explanation: "Open the URL.",
        clarificationNeeded: false,
      }),
    ).toThrow(/target bundle/i);
  });

  it("rejects app targets that are not in the bounded application registry", () => {
    const availability: PlanAvailability = {
      supportedTools: ["nativeAccessibility"],
      integrations: [],
      applicationCandidates: [
        {
          bundleIdentifier: "com.brave.Browser",
          displayName: "Brave Browser",
          normalizedNames: ["brave", "brave browser"],
          supportedActions: ["openApplication", "scroll"],
          integrations: [],
        },
      ],
    };
    const browserNotAdvertised: PlanAvailability = {
      ...availability,
      supportedTools: ["structuredIntegration"],
      integrations: ["browser"],
    };

    expect(() =>
      normalizeModelPlan(
        {
          actions: [
            {
              kind: "openApplication",
              targetBundleIdentifier: "com.evil.Invented",
              parameters: {},
            },
          ],
          explanation: "Open an app.",
          clarificationNeeded: false,
        },
        availability,
      ),
    ).toThrow(/application candidate|advertised/i);

    expect(
      normalizeModelPlan(
        {
          actions: [
            {
              kind: "openApplication",
              targetBundleIdentifier: "com.brave.Browser",
              parameters: {},
            },
          ],
          explanation: "Open the advertised app.",
          clarificationNeeded: false,
        },
        availability,
      ).actions[0],
    ).toMatchObject({
      kind: "openApplication",
      targetBundleIdentifier: "com.brave.Browser",
    });

    expect(() =>
      normalizeModelPlan(
        {
          actions: [
            {
              kind: "openURL",
              targetBundleIdentifier: "com.brave.Browser",
              parameters: { url: "https://example.com" },
            },
          ],
          explanation: "Open the URL in Brave.",
          clarificationNeeded: false,
        },
        browserNotAdvertised,
      ),
    ).toThrow(/action.*advertised/i);

    const browserAvailability: PlanAvailability = {
      ...availability,
      supportedTools: ["structuredIntegration"],
      integrations: ["browser"],
      applicationCandidates: [
        {
          bundleIdentifier: "com.brave.Browser",
          displayName: "Brave Browser",
          normalizedNames: ["brave", "brave browser"],
          supportedActions: ["openApplication", "scroll", "openURL"],
          integrations: ["browser"],
        },
      ],
    };
    expect(
      normalizeModelPlan(
        {
          actions: [
            {
              kind: "openURL",
              targetBundleIdentifier: "com.brave.Browser",
              parameters: { url: "https://example.com" },
            },
          ],
          explanation: "Open the URL in Brave.",
          clarificationNeeded: false,
        },
        browserAvailability,
      ).actions[0],
    ).toMatchObject({
      kind: "openURL",
      riskClass: "reversible",
      requiresApproval: false,
    });
    expect(() =>
      normalizeModelPlan(
        {
          actions: [
            {
              kind: "openURL",
              targetBundleIdentifier: "com.brave.Browser",
              parameters: { url: "https://example.com" },
            },
          ],
          explanation: "Open the URL in Brave.",
          clarificationNeeded: false,
        },
        {
          ...browserAvailability,
          applicationCandidates: [
            {
              bundleIdentifier: "com.brave.Browser",
              displayName: "Brave Browser",
              normalizedNames: ["brave", "brave browser"],
              supportedActions: ["openURL"],
              integrations: [],
            },
          ],
        },
      ),
    ).toThrow(/structured integration.*target application/i);
  });

  it("supports typed draftMessage without exposing a send executor", () => {
    const plan = normalizeModelPlan({
      actions: [
        {
          kind: "draftMessage",
          targetBundleIdentifier: "com.example.Mail",
          parameters: {
            recipient: "owner@example.com",
            subject: "Ready",
            body: "The project is ready.",
          },
        },
      ],
      explanation: "Prepare a draft for review.",
      clarificationNeeded: false,
    }, {
      supportedTools: ["structuredIntegration"],
      integrations: ["mail"],
      applicationCandidates: [
        {
          bundleIdentifier: "com.example.Mail",
          displayName: "Mail",
          normalizedNames: ["mail"],
          supportedActions: ["draftMessage"],
          integrations: ["mail"],
        },
      ],
    });
    expect(plan.actions[0]).toMatchObject({
      kind: "draftMessage",
      executor: "service",
      capability: "mail.draft",
      route: "structuredIntegration",
      requiresApproval: true,
      riskClass: "confirm",
    });
    expect(plan.actions[0]?.kind).not.toBe("sendEmail");
  });

  it("requires approval and an advertised app target for draftMessage", () => {
    const availability: PlanAvailability = {
      supportedTools: ["structuredIntegration"],
      integrations: ["mail"],
      applicationCandidates: [
        {
          bundleIdentifier: "com.example.Mail",
          displayName: "Mail",
          normalizedNames: ["mail"],
          supportedActions: ["draftMessage"],
          integrations: ["mail"],
        },
      ],
    };
    expect(() =>
      normalizeModelPlan(
        {
          actions: [
            {
              kind: "draftMessage",
              parameters: {
                recipient: "owner@example.com",
                subject: "Ready",
                body: "The project is ready.",
              },
            },
          ],
          explanation: "Prepare a draft.",
          clarificationNeeded: false,
        },
        availability,
      ),
    ).toThrow(/target bundle/i);

    const plan = normalizeModelPlan(
      {
        actions: [
          {
            kind: "draftMessage",
            targetBundleIdentifier: "com.example.Mail",
            parameters: {
              recipient: "owner@example.com",
              subject: "Ready",
              body: "The project is ready.",
            },
          },
        ],
        explanation: "Prepare a draft.",
        clarificationNeeded: false,
      },
      availability,
    );
    expect(plan.actions[0]).toMatchObject({
      requiresApproval: true,
      riskClass: "confirm",
      targetBundleIdentifier: "com.example.Mail",
    });
    expect(() =>
      normalizeModelPlan(
        {
          actions: [
            {
              kind: "draftMessage",
              targetBundleIdentifier: "com.example.OtherMail",
              parameters: {
                recipient: "owner@example.com",
                subject: "Ready",
                body: "The project is ready.",
              },
            },
          ],
          explanation: "Prepare a draft.",
          clarificationNeeded: false,
        },
        availability,
      ),
    ).toThrow(/application candidate|advertised/i);
  });
});
