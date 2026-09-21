import { afterEach, describe, expect, it, vi } from "vitest";
import { anyApi, makeFunctionReference } from "convex/server";
import { convexTest } from "convex-test";

import schema from "../../convex/schema";
import { normalizeModelPlan } from "../../convex/lib/action_plan";
import { createEmailActionFingerprint } from "../../convex/lib/policy";

const modules = {
  ...import.meta.glob("../../convex/**/*.ts"),
  "../../convex/_generated/test-root.ts": async () => ({}),
};
const api = anyApi as typeof anyApi;
const ownerA = { tokenIdentifier: "clerk|core-owner-a", subject: "core-owner-a" };

afterEach(() => {
  delete process.env.FLOWSTATE_DAILY_RESEARCH_LIMIT;
  delete process.env.FLOWSTATE_DAILY_PLANNING_LIMIT;
  delete process.env.FLOWSTATE_DAILY_MAIL_LIMIT;
  delete process.env.FLOWSTATE_RETENTION_DAYS;
  delete process.env.OPENAI_API_KEY;
  delete process.env.FLOWSTATE_PLANNER_MODEL;
  vi.unstubAllGlobals();
  vi.unstubAllEnvs();
});

describe("preferences, devices, and grants", () => {
  it("syncs explicit preferences and deletes them by owner", async () => {
    const t = convexTest(schema, modules);
    const user = t.withIdentity(ownerA);
    await user.mutation(api.workflows.registerDevice, { deviceId: "core-device-a" });
    await user.mutation(api.preferences.set, {
      key: "writing.style",
      valueJson: JSON.stringify({ language: "zh-Hant", tone: "concise" }),
      deviceId: "core-device-a",
    });
    await expect(user.query(api.preferences.get, { key: "writing.style" })).resolves.toMatchObject({
      value: { language: "zh-Hant", tone: "concise" },
    });
    await user.mutation(api.preferences.sync, {
      deviceId: "core-device-a",
      changes: [{ key: "apps.brave.alias", valueJson: JSON.stringify("Brave") }],
    });
    await expect(user.query(api.preferences.list, {})).resolves.toHaveLength(2);
    await expect(user.mutation(api.preferences.remove, { key: "writing.style" })).resolves.toMatchObject({
      deleted: true,
    });
  });

  it("revocation stops new work and cannot be bypassed by re-registering the same device", async () => {
    const t = convexTest(schema, modules);
    const user = t.withIdentity(ownerA);
    await user.mutation(api.workflows.registerDevice, { deviceId: "core-device-b" });
    await user.mutation(api.devices.revoke, { deviceId: "core-device-b" });
    await expect(
      user.mutation(api.workflows.registerDevice, { deviceId: "core-device-b" }),
    ).rejects.toThrow("revoked");
    await expect(
      user.mutation(api.workflows.createResearchRun, {
        deviceId: "core-device-b",
        query: "should not run after revocation",
      }),
    ).rejects.toThrow("registered");
  });

  it("revocation invalidates action plans and hides them from the revoked device", async () => {
    const t = convexTest(schema, modules);
    const user = t.withIdentity(ownerA);
    await user.mutation(api.workflows.registerDevice, { deviceId: "core-device-r" });
    const { planId } = await user.mutation(api.plans.createActionPlan, {
      deviceId: "core-device-r",
      command: "scroll in the reader",
      locale: "en",
    });
    await t.run(async (ctx) => {
      await ctx.db.patch(planId, { status: "approved" });
    });
    await user.mutation(api.devices.revoke, { deviceId: "core-device-r" });
    await expect(user.query(api.plans.getActionPlan, { planId })).rejects.toThrow("revoked");
    await expect(t.run(async (ctx) => ctx.db.get(planId))).resolves.toMatchObject({
      status: "cancelled",
      errorCode: "device_revoked",
    });
  });

  it("reports grants inactive after their device is revoked", async () => {
    const t = convexTest(schema, modules);
    const user = t.withIdentity(ownerA);
    await user.mutation(api.workflows.registerDevice, { deviceId: "core-device-s" });
    await user.mutation(api.grants.grant, {
      deviceId: "core-device-s",
      capability: "app.control",
      expiresAt: Date.now() + 60_000,
    });
    await user.mutation(api.devices.revoke, { deviceId: "core-device-s" });
    await expect(user.query(api.grants.list, { deviceId: "core-device-s" })).resolves.toMatchObject([
      { active: false },
    ]);
  });

  it("requires an unscoped grant for an action without a target and exact target grants otherwise", async () => {
    const t = convexTest(schema, modules);
    const user = t.withIdentity(ownerA);
    await user.mutation(api.workflows.registerDevice, { deviceId: "core-device-c" });
    const expiresAt = Date.now() + 60_000;
    await user.mutation(api.grants.grant, {
      deviceId: "core-device-c",
      capability: "app.control",
      target: "com.example.Restricted",
      expiresAt,
    });
    const restricted = normalizeModelPlan({
      actions: [
        {
          kind: "scroll",
          parameters: { lines: 3 },
          targetBundleIdentifier: "com.example.Restricted",
        },
      ],
      explanation: "Scroll in the selected app",
      clarificationNeeded: false,
    });
    const unscoped = normalizeModelPlan({
      actions: [
        {
          kind: "scroll",
          parameters: { lines: 3 },
          targetBundleIdentifier: "com.example.Other",
        },
      ],
      explanation: "Scroll in another app",
      clarificationNeeded: false,
    });
    const noTarget = normalizeModelPlan({
      actions: [
        {
          kind: "scroll",
          parameters: { lines: 3 },
          targetBundleIdentifier: "com.example.Restricted",
        },
      ],
      explanation: "Scroll",
      clarificationNeeded: false,
    });
    const { planId } = await user.mutation(api.plans.createActionPlan, {
      deviceId: "core-device-c",
      command: "scroll down",
      locale: "en",
    });
    await t.run(async (ctx) => {
      await ctx.db.patch(planId, {
        status: "awaiting_approval",
        actionsJson: JSON.stringify(JSON.parse(JSON.stringify(noTarget.actions))),
        capabilitiesJson: JSON.stringify(noTarget.capabilities),
        planFingerprint: noTarget.fingerprint,
        explanation: "Scroll",
      });
    });
    await expect(
      user.mutation(api.plans.approveActionPlan, { planId, fingerprint: noTarget.fingerprint }),
    ).resolves.toMatchObject({ status: "approved" });

    const { planId: otherPlan } = await user.mutation(api.plans.createActionPlan, {
      deviceId: "core-device-c",
      command: "scroll in another app",
      locale: "en",
    });
    await t.run(async (ctx) => {
      await ctx.db.patch(otherPlan, {
        status: "awaiting_approval",
        actionsJson: JSON.stringify(unscoped.actions),
        capabilitiesJson: JSON.stringify(unscoped.capabilities),
        planFingerprint: unscoped.fingerprint,
        explanation: "Scroll in another app",
      });
    });
    await expect(
      user.mutation(api.plans.approveActionPlan, { planId: otherPlan, fingerprint: unscoped.fingerprint }),
    ).rejects.toThrow("missing active grant");
    expect(restricted.fingerprint).not.toBe(unscoped.fingerprint);
  });
});

describe("quota and retention safeguards", () => {
  it("enforces the research quota transactionally", async () => {
    process.env.FLOWSTATE_DAILY_RESEARCH_LIMIT = "1";
    const t = convexTest(schema, modules);
    const user = t.withIdentity(ownerA);
    await user.mutation(api.workflows.registerDevice, { deviceId: "core-device-d" });
    await user.mutation(api.workflows.createResearchRun, {
      deviceId: "core-device-d",
      query: "first permitted research",
    });
    await expect(
      user.mutation(api.workflows.createResearchRun, {
        deviceId: "core-device-d",
        query: "second blocked research",
      }),
    ).rejects.toThrow("daily usage limit");
    await expect(user.query(api.usage.get, {})).resolves.toMatchObject({ researchCount: 1 });
  });

  it("preserves uncertain delivery receipts while deleting content", async () => {
    const t = convexTest(schema, modules);
    const user = t.withIdentity(ownerA);
    const runId = await t.run(async (ctx) => {
      const id = await ctx.db.insert("workflowRuns", {
        ownerKey: ownerA.tokenIdentifier,
        deviceId: "core-device-e",
        kind: "public_research_email",
        query: "private research query",
        previewTitle: "Private title",
        previewBody: "Private body",
        previewJson: JSON.stringify({ private: "derived content" }),
        status: "uncertain",
        cancellationGeneration: 0,
        createdAt: Date.now(),
        updatedAt: Date.now(),
      });
      const approvalId = await ctx.db.insert("approvals", {
        ownerKey: ownerA.tokenIdentifier,
        runId: id,
        actionKind: "agentmail_send",
        recipient: "owner@example.com",
        subject: "Private title",
        body: "Private body",
        actionFingerprint: "private-fingerprint",
        status: "approved",
        expiresAt: Date.now() + 60_000,
        createdAt: Date.now(),
      });
      await ctx.db.insert("deliveryAttempts", {
        ownerKey: ownerA.tokenIdentifier,
        runId: id,
        approvalId,
        provider: "agentmail",
        idempotencyKey: "uncertain-receipt",
        status: "uncertain",
        requestFingerprint: "private-fingerprint",
        createdAt: Date.now(),
        updatedAt: Date.now(),
      });
      return id;
    });
    const result = await user.mutation(api.retention.deleteMyData, {
      includeDevices: false,
      maxRecords: 100,
    });
    expect(result.preservedUncertain).toBe(1);
    const retained = await t.run(async (ctx) => ({
      run: await ctx.db.get(runId),
      attempts: await ctx.db.query("deliveryAttempts").collect(),
      approvals: await ctx.db.query("approvals").collect(),
      usage: await ctx.db.query("usageCounters").collect(),
    }));
    expect(retained.run).toMatchObject({ status: "uncertain", query: "[redacted]" });
    expect(retained.run?.previewJson).toBeUndefined();
    expect(retained.attempts).toHaveLength(1);
    expect(retained.approvals[0]).toMatchObject({ body: "[redacted]", status: "rejected" });
    expect(retained.usage).toHaveLength(0);
  });

  it("does not retry a failed research or planning run without consuming a new quota", async () => {
    const t = convexTest(schema, modules);
    const user = t.withIdentity(ownerA);
    await user.mutation(api.workflows.registerDevice, { deviceId: "core-device-t" });
    const { runId } = await user.mutation(api.workflows.createResearchRun, {
      deviceId: "core-device-t",
      query: "failed research that must not retry",
    });
    await t.run(async (ctx) => {
      await ctx.db.patch(runId, { status: "failed", errorCode: "provider_failed" });
    });
    await expect(user.action(api.workflows.runResearch, { runId })).rejects.toThrow("failed");

    const { planId } = await user.mutation(api.plans.createActionPlan, {
      deviceId: "core-device-t",
      command: "failed plan that must not retry",
      locale: "en",
    });
    await t.run(async (ctx) => {
      await ctx.db.patch(planId, { status: "failed", errorCode: "planner_failed" });
    });
    await expect(user.action(api.plans.resolveActionPlan, { planId })).rejects.toThrow("failed");
  });

  it("rechecks a revoked device inside the delivery reservation", async () => {
    process.env.FLOWSTATE_ALLOWED_TEST_RECIPIENTS = "owner@example.com";
    process.env.FLOWSTATE_AGENTMAIL_INBOX_ID = "flowstate@example.com";
    const t = convexTest(schema, modules);
    const user = t.withIdentity(ownerA);
    await user.mutation(api.workflows.registerDevice, { deviceId: "core-device-u" });
    const { runId } = await user.mutation(api.workflows.createResearchRun, {
      deviceId: "core-device-u",
      query: "delivery reservation",
    });
    const approvalId = await t.run(async (ctx) => {
      await ctx.db.patch(runId, {
        status: "approved",
        previewTitle: "Reservation",
        previewBody: "Body",
      });
      return ctx.db.insert("approvals", {
        ownerKey: ownerA.tokenIdentifier,
        runId,
        actionKind: "agentmail_send",
        sender: "flowstate@example.com",
        recipient: "owner@example.com",
        subject: "Reservation",
        body: "Body",
        actionFingerprint: createEmailActionFingerprint({
          recipient: "owner@example.com",
          subject: "Reservation",
          body: "Body",
        }),
        status: "approved",
        expiresAt: Date.now() + 60_000,
        createdAt: Date.now(),
      });
    });
    await user.mutation(api.devices.revoke, { deviceId: "core-device-u" });
    const beginDelivery = makeFunctionReference<
      "mutation",
      {
        ownerKey: string;
        runId: typeof runId;
        approvalId: typeof approvalId;
        idempotencyKey: string;
        requestFingerprint: string;
      },
      unknown
    >("workflows:beginDelivery");
    await expect(
      t.mutation(beginDelivery, {
        ownerKey: ownerA.tokenIdentifier,
        runId,
        approvalId,
        idempotencyKey: "revoked-reservation",
        requestFingerprint: createEmailActionFingerprint({
          recipient: "owner@example.com",
          subject: "Reservation",
          body: "Body",
        }),
      }),
    ).rejects.toThrow("revoked");
  });

  it("purges old plans, webhook events, and usage while preserving current usage and uncertain receipts", async () => {
    const purgeExpired = makeFunctionReference<"mutation", { maxRecords?: number }, unknown>(
      "retention:purgeExpired",
    );
    const t = convexTest(schema, modules);
    const old = Date.now() - 40 * 24 * 60 * 60 * 1_000;
    const currentPeriod = new Date().toISOString().slice(0, 10);
    const oldPeriod = new Date(old).toISOString().slice(0, 10);
    const oldPlan = await t.run(async (ctx) =>
      ctx.db.insert("actionPlans", {
        ownerKey: ownerA.tokenIdentifier,
        deviceId: "core-device-purge",
        command: "old plan",
        locale: "en",
        status: "approved",
        cancellationGeneration: 0,
        expiresAt: old,
        createdAt: old,
        updatedAt: old,
      }),
    );
    await t.run(async (ctx) => {
      await ctx.db.insert("agentMailEvents", {
        eventId: "old-event",
        eventType: "message.sent",
        inboxId: "flowstate@example.com",
        receivedAt: old,
        payloadJson: "{}",
      });
      await ctx.db.insert("usageCounters", {
        ownerKey: ownerA.tokenIdentifier,
        period: oldPeriod,
        researchCount: 4,
        planningCount: 4,
        mailCount: 4,
        providerBytes: 0,
        updatedAt: old,
      });
      await ctx.db.insert("usageCounters", {
        ownerKey: ownerA.tokenIdentifier,
        period: currentPeriod,
        researchCount: 1,
        planningCount: 1,
        mailCount: 1,
        providerBytes: 0,
        updatedAt: Date.now(),
      });
    });
    await expect(t.mutation(purgeExpired, { maxRecords: 20 })).resolves.toMatchObject({ deleted: 3 });
    await expect(t.run(async (ctx) => ctx.db.get(oldPlan))).resolves.toBeNull();
    await expect(t.run(async (ctx) => ctx.db.query("agentMailEvents").collect())).resolves.toHaveLength(0);
    await expect(t.run(async (ctx) => ctx.db.query("usageCounters").collect())).resolves.toHaveLength(1);
  });
});

describe("typed action-plan contracts", () => {
  it("resolves a bounded plan through OpenAI and leaves execution behind approval", async () => {
    vi.stubEnv("TYPESAFE_API_KEY", "test-key");
    vi.stubEnv("FLOWSTATE_JEV_MODEL", "jev-1.13.0");
    process.env.OPENAI_API_KEY = "sk-test";
    process.env.FLOWSTATE_PLANNER_MODEL = "gpt-5-mini";
    const fetch = vi.fn(async () =>
      new Response(
        JSON.stringify({
          id: "resp_plan",
          output_text: JSON.stringify({
            actions: [
              {
                kind: "scroll",
                targetBundleIdentifier: "com.example.Reader",
                parameters: { lines: -3 },
              },
            ],
            explanation: "Scroll down in the reader",
            clarificationNeeded: false,
          }),
        }),
        { status: 200 },
      ),
    );
    vi.stubGlobal("fetch", fetch);
    const t = convexTest(schema, modules);
    const user = t.withIdentity(ownerA);
    await user.mutation(api.workflows.registerDevice, { deviceId: "core-device-f" });
    const { planId } = await user.mutation(api.plans.createActionPlan, {
      deviceId: "core-device-f",
      command: "scroll down in my reader",
      locale: "en",
      supportedTools: ["nativeAccessibility"],
      integrations: [],
      applicationCandidates: [
        {
          bundleIdentifier: "com.example.Reader",
          displayName: "Reader",
          normalizedNames: ["reader"],
          supportedActions: ["scroll"],
          integrations: [],
        },
      ],
    });
    await expect(user.action(api.plans.resolveActionPlan, { planId })).resolves.toMatchObject({
      status: "awaiting_approval",
      actions: [{ kind: "scroll", executor: "desktop" }],
    });
    expect(JSON.stringify(fetch.mock.calls[0])).toContain(
      "openURL {targetBundleIdentifier: required advertised app, url",
    );
    expect(JSON.stringify(fetch.mock.calls[0])).toContain(
      "draftMessage {targetBundleIdentifier: required advertised app, recipient,subject,body}",
    );
    const view = await user.query(api.plans.getActionPlan, { planId });
    expect(view).toMatchObject({
      status: "awaiting_approval",
      explanation: "Scroll down in the reader",
      supportedTools: ["nativeAccessibility"],
      integrations: [],
      applicationCandidates: [
        {
          bundleIdentifier: "com.example.Reader",
          displayName: "Reader",
          normalizedNames: ["reader"],
          supportedActions: ["scroll"],
          integrations: [],
        },
      ],
    });
    await expect(
      user.mutation(api.plans.approveActionPlan, { planId, fingerprint: view.fingerprint ?? "" }),
    ).rejects.toThrow("missing active grant");
    expect(fetch).toHaveBeenCalledTimes(1);
  });

  it("rejects missing desktop targets, unsafe key presses, and fractional scrolls", () => {
    expect(() =>
      normalizeModelPlan({
        actions: [{ kind: "scroll", parameters: { lines: 2 } }],
        explanation: "Scroll",
      }),
    ).toThrow("target bundle");
    expect(() =>
      normalizeModelPlan({
        actions: [
          {
            kind: "press",
            targetBundleIdentifier: "com.example.App",
            parameters: { key: "Command-Q" },
          },
        ],
        explanation: "Quit",
      }),
    ).toThrow("safe navigation");
    expect(() =>
      normalizeModelPlan({
        actions: [
          {
            kind: "scroll",
            targetBundleIdentifier: "com.example.App",
            parameters: { lines: 1.5 },
          },
        ],
        explanation: "Scroll",
      }),
    ).toThrow("integer");
  });

  it("marks service actions so native executors can refuse them", () => {
    const plan = normalizeModelPlan({
      actions: [
        {
          kind: "sendEmail",
          parameters: { recipient: "owner@example.com", subject: "Hello", body: "Body" },
        },
      ],
      explanation: "Prepare an email",
    });
    expect(plan.actions[0]).toMatchObject({ executor: "service", requiresApproval: true, capability: "mail.send" });
  });
});

it("legacy planning cannot bypass the authorized screenshot intent path", async () => {
  const t = convexTest(schema, modules); const user = t.withIdentity(ownerA);
  await user.mutation(api.workflows.registerDevice, { deviceId: "legacy-screen" });
  const { planId } = await user.mutation(api.plans.createActionPlan, { deviceId: "legacy-screen", command: "scroll down", locale: "en" });
  await expect(user.action(api.plans.resolveActionPlan, { planId, screenshot: "data:image/png;base64,AAAA" })).rejects.toThrow("authorized intent");
});

it("returns a specific clarification without approving or exposing a partial workflow", async () => {
  vi.stubEnv("OPENAI_API_KEY", "test-key");
  vi.stubEnv("FLOWSTATE_PLANNER_MODEL", "test-model");
  vi.stubGlobal("fetch", vi.fn(async () => new Response(JSON.stringify({id: "clarify", output_text: JSON.stringify({
    actions: [], explanation: "Deleting files is not supported.", clarificationNeeded: true,
  })}), {status: 200})));
  const t = convexTest(schema, modules);
  const user = t.withIdentity(ownerA);
  await user.mutation(api.workflows.registerDevice, {deviceId: "workflow-device"});
  const {planId} = await user.mutation(api.plans.createActionPlan, {
    deviceId: "workflow-device", command: "Open Brave and delete my files", locale: "en",
  });
  const response = await user.action(api.plans.resolveActionPlan, {planId});
  await expect(user.query(api.plans.getActionPlan, {planId})).resolves.toMatchObject({
    actions: [], error: "clarification_required", explanation: "Deleting files is not supported.",
  });
  await expect(user.mutation(api.plans.approveActionPlan, {planId, fingerprint: response.fingerprint}))
    .rejects.toThrow("needs clarification");
});
