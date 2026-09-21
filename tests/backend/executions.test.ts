import { expect, it } from "vitest";
import { anyApi } from "convex/server";
import { convexTest } from "convex-test";
import schema from "../../convex/schema";
const modules = {
  ...import.meta.glob("../../convex/**/*.ts"),
  "../../convex/_generated/test-root.ts": async () => ({}),
};
it("reserves each approved desktop step once and checkpoints verified completion", async () => {
  const t = convexTest(schema, modules);
  const user = t.withIdentity({
    subject: "executor",
    tokenIdentifier: "test|executor",
  });
  await user.mutation(anyApi.workflows.registerDevice, {
    deviceId: "execution-device",
  });
  await user.mutation(anyApi.grants.grant, {
    deviceId: "execution-device",
    capability: "app.control",
    target: "com.example.Reader",
    expiresAt: Date.now() + 60000,
  });
  const planId = await t.run((ctx) =>
    ctx.db.insert("actionPlans", {
      ownerKey: "test|executor",
      deviceId: "execution-device",
      command: "scroll",
      locale: "en",
      status: "approved",
      cancellationGeneration: 1,
      expiresAt: Date.now() + 60000,
      createdAt: Date.now(),
      updatedAt: Date.now(),
      planFingerprint: "reviewed",
      actionsJson: JSON.stringify([
        {
          kind: "scroll",
          targetBundleIdentifier: "com.example.Reader",
          parameters: { lines: 3 },
          capability: "app.control",
          executor: "desktop",
          requiresApproval: false,
        },
      ]),
    }),
  );
  await user.mutation(anyApi.executions.start, {
    planId,
    fingerprint: "reviewed",
  });
  await expect(
    user.mutation(anyApi.executions.start, { planId, fingerprint: "reviewed" }),
  ).rejects.toThrow("already");
  await user.mutation(anyApi.executions.claimStep, {
    planId,
    ordinal: 0,
    generation: 1,
  });
  await expect(
    user.mutation(anyApi.executions.claimStep, {
      planId,
      ordinal: 0,
      generation: 1,
    }),
  ).rejects.toThrow("uncertain");
  await user.mutation(anyApi.executions.finishStep, {
    planId,
    ordinal: 0,
    generation: 1,
    verified: true,
  });
  expect(await t.run((ctx) => ctx.db.get(planId))).toMatchObject({
    status: "succeeded",
    completedSteps: 1,
  });
  await expect(
    user.mutation(anyApi.executions.claimStep, {
      planId,
      ordinal: 0,
      generation: 1,
    }),
  ).rejects.toThrow();
});
it("revocation and cancellation prevent a reserved plan from claiming new effects", async () => {
  const t = convexTest(schema, modules);
  const user = t.withIdentity({
    subject: "executor2",
    tokenIdentifier: "test|executor2",
  });
  await user.mutation(anyApi.workflows.registerDevice, {
    deviceId: "execution-device2",
  });
  const planId = await t.run((ctx) =>
    ctx.db.insert("actionPlans", {
      ownerKey: "test|executor2",
      deviceId: "execution-device2",
      command: "scroll",
      locale: "en",
      status: "approved",
      cancellationGeneration: 1,
      expiresAt: Date.now() + 60000,
      createdAt: Date.now(),
      updatedAt: Date.now(),
      planFingerprint: "reviewed",
      actionsJson: "[]",
    }),
  );
  await user.mutation(anyApi.devices.revoke, { deviceId: "execution-device2" });
  await expect(
    user.mutation(anyApi.executions.start, { planId, fingerprint: "reviewed" }),
  ).rejects.toThrow();
});

it("keeps an in-flight effect uncertain when cancelled instead of claiming it did not happen", async () => {
  const t = convexTest(schema, modules);
  const user = t.withIdentity({
    subject: "cancel",
    tokenIdentifier: "test|cancel",
  });
  const planId = await t.run((ctx) =>
    ctx.db.insert("actionPlans", {
      ownerKey: "test|cancel",
      deviceId: "cancel-device",
      command: "scroll",
      locale: "en",
      status: "executing",
      executingStep: 0,
      completedSteps: 0,
      cancellationGeneration: 1,
      expiresAt: Date.now() + 60000,
      createdAt: Date.now(),
      updatedAt: Date.now(),
    }),
  );
  await user.mutation(anyApi.plans.cancelActionPlan, { planId });
  expect(await t.run((ctx) => ctx.db.get(planId))).toMatchObject({
    status: "uncertain",
    executingStep: 0,
    cancellationGeneration: 2,
  });
  await expect(
    user.mutation(anyApi.executions.finishStep, {
      planId,
      ordinal: 0,
      generation: 1,
      verified: true,
    }),
  ).rejects.toThrow("stale");
});

it("requires a fresh observation for visual steps and allows only one active visual plan", async () => {
  const t = convexTest(schema, modules);
  const user = t.withIdentity({
    subject: "visual-executor",
    tokenIdentifier: "test|visual-executor",
  });
  await user.mutation(anyApi.workflows.registerDevice, {
    deviceId: "visual-device",
  });
  await user.mutation(anyApi.grants.grant, {
    deviceId: "visual-device",
    capability: "app.control",
    target: "com.example.Reader",
    expiresAt: Date.now() + 60_000,
  });
  const observedAt = Date.now();
  const visualAction = {
    kind: "scroll",
    targetBundleIdentifier: "com.example.Reader",
    parameters: { lines: -2 },
    capability: "app.control",
    executor: "desktop",
    requiresApproval: false,
    route: "visualComputerUse",
    riskClass: "reversible",
    preconditions: {
      targetBundleIdentifier: "com.example.Reader",
      requiresFreshObservation: true,
    },
    verifier: { kind: "visualObservation" },
    reversal: { kind: "none", supported: false },
    visualTarget: {
      displayId: "display-1",
      windowId: "window-1",
      x: 0,
      y: 0,
      width: 800,
      height: 600,
      observedAt,
    },
  };
  const planId = await t.run((ctx) =>
    ctx.db.insert("actionPlans", {
      ownerKey: "test|visual-executor",
      deviceId: "visual-device",
      command: "scroll in this view",
      locale: "en",
      status: "approved",
      cancellationGeneration: 1,
      expiresAt: Date.now() + 60_000,
      createdAt: Date.now(),
      updatedAt: Date.now(),
      planFingerprint: "visual-one",
      actionsJson: JSON.stringify([visualAction]),
    }),
  );
  await user.mutation(anyApi.executions.start, {
    planId,
    fingerprint: "visual-one",
  });
  await expect(
    user.mutation(anyApi.executions.claimStep, {
      planId,
      ordinal: 0,
      generation: 1,
    }),
  ).rejects.toThrow("fresh observation");
  await expect(
    user.mutation(anyApi.executions.claimStep, {
      planId,
      ordinal: 0,
      generation: 1,
      observationObservedAt: observedAt,
    }),
  ).rejects.toThrow("fresh observation");
  await expect(
    user.mutation(anyApi.executions.claimStep, {
      planId,
      ordinal: 0,
      generation: 1,
      observationObservedAt: observedAt + 1,
    }),
  ).resolves.toMatchObject({ reserved: true });

  const secondPlanId = await t.run((ctx) =>
    ctx.db.insert("actionPlans", {
      ownerKey: "test|visual-executor",
      deviceId: "visual-device",
      command: "scroll in another view",
      locale: "en",
      status: "approved",
      cancellationGeneration: 1,
      expiresAt: Date.now() + 60_000,
      createdAt: Date.now(),
      updatedAt: Date.now(),
      planFingerprint: "visual-two",
      actionsJson: JSON.stringify([visualAction]),
    }),
  );
  await expect(
    user.mutation(anyApi.executions.start, {
      planId: secondPlanId,
      fingerprint: "visual-two",
    }),
  ).rejects.toThrow("visual plan");
});

it("deduplicates external effects and requires reconciliation before retry", async () => {
  const t = convexTest(schema, modules);
  const user = t.withIdentity({
    subject: "external-executor",
    tokenIdentifier: "test|external-executor",
  });
  await user.mutation(anyApi.workflows.registerDevice, {
    deviceId: "external-device",
  });
  await user.mutation(anyApi.grants.grant, {
    deviceId: "external-device",
    capability: "mail.send",
    expiresAt: Date.now() + 60_000,
  });
  const planId = await t.run((ctx) =>
    ctx.db.insert("actionPlans", {
      ownerKey: "test|external-executor",
      deviceId: "external-device",
      command: "send the approved message",
      locale: "en",
      status: "approved",
      cancellationGeneration: 1,
      expiresAt: Date.now() + 60_000,
      createdAt: Date.now(),
      updatedAt: Date.now(),
      planFingerprint: "external-plan",
      actionsJson: JSON.stringify([
        {
          kind: "sendEmail",
          parameters: {
            recipient: "owner@example.com",
            subject: "Ready",
            body: "The project is ready.",
          },
          capability: "mail.send",
          executor: "service",
          requiresApproval: true,
          route: "structuredIntegration",
          riskClass: "confirm",
          preconditions: { requiresFreshObservation: false },
          verifier: { kind: "externalEffectReconciled" },
          reversal: { kind: "reconcile", supported: false },
        },
      ]),
    }),
  );
  await user.mutation(anyApi.executions.start, {
    planId,
    fingerprint: "external-plan",
  });
  await expect(
    user.mutation(anyApi.executions.claimStep, {
      planId,
      ordinal: 0,
      generation: 1,
    }),
  ).rejects.toThrow(/approval/i);
  await user.mutation(anyApi.executions.approveStep, {
    planId,
    ordinal: 0,
    generation: 1,
    fingerprint: "external-plan",
  });
  await expect(
    user.mutation(anyApi.executions.approveStep, {
      planId,
      ordinal: 0,
      generation: 1,
      fingerprint: "external-plan",
    }),
  ).rejects.toThrow(/approval|consumed/i);
  await user.mutation(anyApi.executions.claimStep, {
    planId,
    ordinal: 0,
    generation: 1,
  });
  const first = await user.mutation(anyApi.executions.beginExternalEffect, {
    planId,
    ordinal: 0,
    generation: 1,
    provider: "agentmail",
    idempotencyKey: "external-idempotency-1",
    requestFingerprint: "message-fingerprint-1",
  });
  expect(first.status).toBe("pending");
  const retry = await user.mutation(anyApi.executions.beginExternalEffect, {
    planId,
    ordinal: 0,
    generation: 1,
    provider: "agentmail",
    idempotencyKey: "external-idempotency-1",
    requestFingerprint: "message-fingerprint-1",
  });
  expect(retry.status).toBe("reconcile");
  await expect(
    user.mutation(anyApi.executions.beginExternalEffect, {
      planId,
      ordinal: 0,
      generation: 1,
      provider: "agentmail",
      idempotencyKey: "external-idempotency-1",
      requestFingerprint: "different-message",
    }),
  ).rejects.toThrow("idempotency");
  await expect(
    user.mutation(anyApi.executions.finishStep, {
      planId,
      ordinal: 0,
      generation: 1,
      verified: true,
    }),
  ).rejects.toThrow("reconciled");
  await expect(
    user.mutation(anyApi.executions.reconcileExternalEffect, {
      receiptId: first.receiptId,
      status: "succeeded",
      requestFingerprint: "different-message",
    }),
  ).rejects.toThrow(/fingerprint/i);
  await user.mutation(anyApi.executions.reconcileExternalEffect, {
    receiptId: first.receiptId,
    status: "succeeded",
    requestFingerprint: "message-fingerprint-1",
  });
  await expect(
    user.mutation(anyApi.executions.reconcileExternalEffect, {
      receiptId: first.receiptId,
      status: "succeeded",
      requestFingerprint: "message-fingerprint-1",
    }),
  ).rejects.toThrow(/reconciled/i);
  await expect(
    user.mutation(anyApi.executions.finishStep, {
      planId,
      ordinal: 0,
      generation: 1,
      verified: true,
    }),
  ).resolves.toMatchObject({ status: "succeeded" });
});

it("expires an unconsumed step approval when the plan is cancelled", async () => {
  const t = convexTest(schema, modules);
  const user = t.withIdentity({
    subject: "approval-cancel",
    tokenIdentifier: "test|approval-cancel",
  });
  await user.mutation(anyApi.workflows.registerDevice, {
    deviceId: "approval-device",
  });
  await user.mutation(anyApi.grants.grant, {
    deviceId: "approval-device",
    capability: "mail.draft",
    expiresAt: Date.now() + 60_000,
  });
  const planId = await t.run((ctx) =>
    ctx.db.insert("actionPlans", {
      ownerKey: "test|approval-cancel",
      deviceId: "approval-device",
      command: "send the approved message",
      locale: "en",
      status: "approved",
      cancellationGeneration: 1,
      expiresAt: Date.now() + 60_000,
      createdAt: Date.now(),
      updatedAt: Date.now(),
      planFingerprint: "approval-cancel-plan",
      actionsJson: JSON.stringify([
        {
          kind: "draftMessage",
          targetBundleIdentifier: "com.example.Mail",
          parameters: {
            recipient: "owner@example.com",
            subject: "Ready",
            body: "The project is ready.",
          },
          requiresApproval: true,
        },
      ]),
    }),
  );
  await user.mutation(anyApi.executions.approveStep, {
    planId,
    ordinal: 0,
    generation: 1,
    fingerprint: "approval-cancel-plan",
  });
  await user.mutation(anyApi.plans.cancelActionPlan, { planId });
  const approvals = await t.run((ctx) => ctx.db.query("actionStepApprovals").collect());
  expect(approvals).toHaveLength(1);
  expect(approvals[0]?.expiresAt).toBeLessThanOrEqual(Date.now());
  await expect(
    user.mutation(anyApi.executions.approveStep, {
      planId,
      ordinal: 0,
      generation: 1,
      fingerprint: "approval-cancel-plan",
    }),
  ).rejects.toThrow(/stale|cancelled/i);
});
