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
  });

  it("supports an app-agnostic labeled click on the native route", () => {
    const plan = normalizeModelPlan(
      {
        actions: [
          {
            kind: "click",
            targetBundleIdentifier: "com.apple.PhotoBooth",
            parameters: { label: "Take Photo" },
          },
        ],
        explanation: "Click the labeled control.",
        clarificationNeeded: false,
      },
      {
        supportedTools: ["nativeAccessibility"],
        integrations: [],
        applicationCandidates: [
          {
            bundleIdentifier: "com.apple.PhotoBooth",
            displayName: "Photo Booth",
            normalizedNames: ["photo booth"],
            supportedActions: ["openApplication", "click"],
            integrations: [],
          },
        ],
      },
    );

    expect(plan.actions[0]).toMatchObject({
      kind: "click",
      parameters: { label: "Take Photo" },
      capability: "app.control",
      executor: "desktop",
      requiresApproval: true,
      route: "nativeAccessibility",
      riskClass: "confirm",
      preconditions: {
        targetBundleIdentifier: "com.apple.PhotoBooth",
        requiresFreshObservation: false,
      },
      verifier: { kind: "boundedAction" },
    });
  });

  it("routes the same labeled click through visual computer use when advertised", () => {
    const observedAt = Date.now();
    const observation = {
      id: "observation-1",
      bundleIdentifier: "com.apple.PhotoBooth",
      displayId: "display-1",
      windowId: "window-1",
      observedAt,
      geometry: { x: 0, y: 0, width: 1200, height: 900, scale: 1 },
      imageDataUrl: "data:image/png;base64,AAAA",
    };
    const plan = normalizeModelPlan(
      {
        actions: [
          {
            kind: "click",
            targetBundleIdentifier: "com.apple.PhotoBooth",
            parameters: { label: "Take Photo" },
            visualTarget: {
              observationId: observation.id,
              displayId: "display-1",
              windowId: "window-1",
              x: 0.01,
              y: 0.02,
              width: 0.67,
              height: 0.66,
              observedAt,
            },
          },
        ],
        explanation: "Click the labeled control in the fresh view.",
        clarificationNeeded: false,
      },
      {
        supportedTools: ["visualComputerUse"],
        integrations: [],
        visualObservation: observation,
        applicationCandidates: [
          {
            bundleIdentifier: "com.apple.PhotoBooth",
            displayName: "Photo Booth",
            normalizedNames: ["photo booth"],
            supportedActions: ["openApplication", "click"],
            integrations: [],
          },
        ],
      },
    );

    expect(plan.actions[0]).toMatchObject({
      kind: "click",
      route: "visualComputerUse",
      requiresApproval: true,
      riskClass: "confirm",
      preconditions: { requiresFreshObservation: true },
      verifier: { kind: "visualObservation" },
      visualTarget: expect.objectContaining({ observationId: observation.id, observedAt }),
    });
  });

  it("allows at most one visual action for one observation", () => {
    const visualTarget = {
      observationId: "observation-1",
      displayId: "display-1",
      windowId: "window-1",
      x: 0.01,
      y: 0.02,
      width: 0.67,
      height: 0.66,
      observedAt: Date.now(),
    };

    expect(() =>
      normalizeModelPlan(
        {
          actions: [
            {
              kind: "click",
              targetBundleIdentifier: "com.apple.PhotoBooth",
              parameters: { label: "Take Photo" },
              visualTarget,
            },
            {
              kind: "click",
              targetBundleIdentifier: "com.apple.PhotoBooth",
              parameters: { label: "Shutter" },
              visualTarget,
            },
          ],
          explanation: "Use one fresh observation per visual action.",
          clarificationNeeded: false,
        },
      {
        supportedTools: ["visualComputerUse"],
        integrations: [],
        visualObservation: {
          id: "observation-1",
          bundleIdentifier: "com.apple.PhotoBooth",
          displayId: "display-1",
          windowId: "window-1",
          observedAt: visualTarget.observedAt,
          geometry: { x: 0, y: 0, width: 1200, height: 900, scale: 1 },
          imageDataUrl: "data:image/png;base64,AAAA",
        },
          applicationCandidates: [
            {
              bundleIdentifier: "com.apple.PhotoBooth",
              displayName: "Photo Booth",
              normalizedNames: ["photo booth"],
              supportedActions: ["openApplication", "click", "press"],
              integrations: [],
            },
          ],
        },
      ),
    ).toThrow("one visual action per observation");
  });

  it("binds a visual target to the supplied observation metadata", () => {
    const observedAt = Date.now();
    const availability: PlanAvailability = {
      supportedTools: ["visualComputerUse"],
      integrations: [],
      visualObservation: {
        id: "observation-1",
        bundleIdentifier: "com.apple.PhotoBooth",
        displayId: "display-1",
        windowId: "window-1",
        observedAt,
        geometry: { x: 0, y: 0, width: 1200, height: 900, scale: 1 },
        imageDataUrl: "data:image/png;base64,AAAA",
      },
    };
    expect(() =>
      normalizeModelPlan(
        {
          actions: [
            {
              kind: "click",
              targetBundleIdentifier: "com.example.Reader",
              parameters: { label: "Continue" },
              visualTarget: {
                observationId: "different-observation",
                displayId: "display-1",
                windowId: "window-1",
                x: 0.1,
                y: 0.2,
                width: 0.1,
                height: 0.1,
                observedAt,
              },
            },
          ],
          explanation: "Click the current control.",
          clarificationNeeded: false,
        },
        availability,
      ),
    ).toThrow("observation");
  });

  it("rejects visual actions without an advertised observation", () => {
    expect(() =>
      normalizeModelPlan({
        actions: [
          {
            kind: "click",
            targetBundleIdentifier: "com.example.Reader",
            parameters: { label: "Continue" },
            visualTarget: {
              observationId: "observation-1",
              displayId: "display-1",
              windowId: "window-1",
              x: 0.1,
              y: 0.2,
              width: 0.1,
              height: 0.1,
              observedAt: Date.now(),
            },
          },
        ],
        explanation: "Click the current control.",
        clarificationNeeded: false,
      }),
    ).toThrow("visual observation is required");
  });

  it("rejects a visual action after an earlier plan step", () => {
    const observedAt = Date.now();
    const observation = {
      id: "observation-1",
      bundleIdentifier: "com.example.Reader",
      displayId: "display-1",
      windowId: "window-1",
      observedAt,
      geometry: { x: 0, y: 0, width: 1200, height: 900, scale: 1 },
      imageDataUrl: "data:image/png;base64,AAAA",
    };
    expect(() =>
      normalizeModelPlan(
        {
          actions: [
            {
              kind: "openApplication",
              targetBundleIdentifier: "com.example.Reader",
              parameters: {},
            },
            {
              kind: "click",
              targetBundleIdentifier: "com.example.Reader",
              parameters: { label: "Continue" },
              visualTarget: {
                observationId: observation.id,
                displayId: observation.displayId,
                windowId: observation.windowId,
                x: 0.1,
                y: 0.2,
                width: 0.1,
                height: 0.1,
                observedAt,
              },
            },
          ],
          explanation: "Open and click.",
          clarificationNeeded: false,
        },
        {
          supportedTools: ["nativeAccessibility", "visualComputerUse"],
          integrations: [],
          visualObservation: observation,
          applicationCandidates: [
            {
              bundleIdentifier: "com.example.Reader",
              displayName: "Reader",
              normalizedNames: ["reader"],
              supportedActions: ["openApplication", "click"],
              integrations: [],
            },
          ],
        },
      ),
    ).toThrow("visual action must be the first step");
  });

  it("rejects visual target coordinates outside normalized window bounds", () => {
    const observedAt = Date.now();
    expect(() =>
      normalizeModelPlan(
        {
          actions: [
            {
              kind: "click",
              targetBundleIdentifier: "com.example.Reader",
              parameters: { label: "Continue" },
              visualTarget: {
                observationId: "observation-1",
                displayId: "display-1",
                windowId: "window-1",
                x: 0.9,
                y: 0.2,
                width: 0.2,
                height: 0.1,
                observedAt,
              },
            },
          ],
          explanation: "Click the current control.",
          clarificationNeeded: false,
        },
        {
          supportedTools: ["visualComputerUse"],
          integrations: [],
          visualObservation: {
            id: "observation-1",
            bundleIdentifier: "com.apple.PhotoBooth",
            displayId: "display-1",
            windowId: "window-1",
            observedAt,
            geometry: { x: 0, y: 0, width: 1200, height: 900, scale: 1 },
            imageDataUrl: "data:image/png;base64,AAAA",
          },
        },
      ),
    ).toThrow("visual target");
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
              kind: "click",
              targetBundleIdentifier: "com.example.Reader",
              parameters: { label: "Continue" },
              visualTarget: {
                observationId: "observation-1",
                displayId: "display-1",
                windowId: "window-1",
                x: 0,
                y: 0,
                width: 1,
                height: 1,
                observedAt: Date.now(),
              },
            },
          ],
          explanation: "Click in the current view.",
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
