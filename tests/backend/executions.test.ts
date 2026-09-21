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
  ).resolves.toEqual({
    status: "succeeded",
    receiptId: first.receiptId,
  });
  await expect(
    user.mutation(anyApi.executions.reconcileExternalEffect, {
      receiptId: first.receiptId,
      status: "failed",
      requestFingerprint: "message-fingerprint-1",
    }),
  ).resolves.toEqual({
    status: "succeeded",
    receiptId: first.receiptId,
  });
  await expect(t.run((ctx) => ctx.db.get(first.receiptId))).resolves.toMatchObject({
    status: "succeeded",
  });
  await expect(
    user.mutation(anyApi.executions.reconcileExternalEffect, {
      receiptId: first.receiptId,
      status: "failed",
      requestFingerprint: "different-message",
    }),
  ).rejects.toThrow(/fingerprint/i);
  await expect(
    user.mutation(anyApi.executions.finishStep, {
      planId,
      ordinal: 0,
      generation: 1,
      verified: true,
    }),
  ).resolves.toMatchObject({ status: "succeeded" });
});

it("keeps a terminal failed receipt authoritative after a lost reconciliation response", async () => {
  const t = convexTest(schema, modules);
  const ownerKey = "terminal-failed-reconciliation";
  const user = t.withIdentity({ subject: ownerKey, tokenIdentifier: ownerKey });
  const planId = await t.run((ctx) =>
    ctx.db.insert("actionPlans", {
      ownerKey,
      deviceId: "terminal-failed-device",
      command: "send the approved message",
      locale: "en",
      status: "executing",
      cancellationGeneration: 1,
      expiresAt: Date.now() + 60_000,
      createdAt: Date.now(),
      updatedAt: Date.now(),
    }),
  );
  const receiptId = await t.run((ctx) =>
    ctx.db.insert("actionExecutionReceipts", {
      ownerKey,
      deviceId: "terminal-failed-device",
      planId,
      ordinal: 0,
      generation: 1,
      provider: "agentmail",
      idempotencyKey: "terminal-failed-key",
      requestFingerprint: "terminal-failed-fingerprint",
      status: "failed",
      createdAt: Date.now(),
      updatedAt: Date.now(),
    }),
  );
  await expect(
    user.mutation(anyApi.executions.reconcileExternalEffect, {
      receiptId,
      status: "succeeded",
      requestFingerprint: "terminal-failed-fingerprint",
    }),
  ).resolves.toEqual({ status: "failed", receiptId });
  await expect(t.run((ctx) => ctx.db.get(receiptId))).resolves.toMatchObject({
    status: "failed",
  });
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

it("recovers external receipts across plans by owner, device, provider, and request fingerprint", async () => {
  const t = convexTest(schema, modules);
  const user = t.withIdentity({
    subject: "external-recovery-owner",
    tokenIdentifier: "test|external-recovery-owner",
  });
  const otherUser = t.withIdentity({
    subject: "external-recovery-other-owner",
    tokenIdentifier: "test|external-recovery-other-owner",
  });
  const action = {
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
  } as const;

  await user.mutation(anyApi.workflows.registerDevice, {
    deviceId: "external-recovery-device",
  });
  await user.mutation(anyApi.grants.grant, {
    deviceId: "external-recovery-device",
    capability: "mail.send",
    expiresAt: Date.now() + 60_000,
  });
  await user.mutation(anyApi.workflows.registerDevice, {
    deviceId: "external-recovery-other-device",
  });
  await user.mutation(anyApi.grants.grant, {
    deviceId: "external-recovery-other-device",
    capability: "mail.send",
    expiresAt: Date.now() + 60_000,
  });
  await otherUser.mutation(anyApi.workflows.registerDevice, {
    deviceId: "external-recovery-device",
  });
  await otherUser.mutation(anyApi.grants.grant, {
    deviceId: "external-recovery-device",
    capability: "mail.send",
    expiresAt: Date.now() + 60_000,
  });

  const preparePlan = async (
    actingUser: typeof user,
    ownerKey: string,
    deviceId: string,
    planFingerprint: string,
    generation = 1,
  ) => {
    const planId = await t.run((ctx) =>
      ctx.db.insert("actionPlans", {
        ownerKey,
        deviceId,
        command: "send the approved message",
        locale: "en",
        status: "approved",
        cancellationGeneration: generation,
        expiresAt: Date.now() + 60_000,
        createdAt: Date.now(),
        updatedAt: Date.now(),
        planFingerprint,
        actionsJson: JSON.stringify([action]),
      }),
    );
    await actingUser.mutation(anyApi.executions.start, {
      planId,
      fingerprint: planFingerprint,
    });
    await actingUser.mutation(anyApi.executions.approveStep, {
      planId,
      ordinal: 0,
      generation,
      fingerprint: planFingerprint,
    });
    await actingUser.mutation(anyApi.executions.claimStep, {
      planId,
      ordinal: 0,
      generation,
    });
    return { planId, generation };
  };

  const pendingPlan = await preparePlan(
    user,
    "test|external-recovery-owner",
    "external-recovery-device",
    "recovery-pending-plan",
    1,
  );
  const pending = await user.mutation(anyApi.executions.beginExternalEffect, {
    ...pendingPlan,
    ordinal: 0,
    provider: "agentmail",
    idempotencyKey: "recovery-pending-key-1",
    requestFingerprint: "opaque-pending-action",
  });
  const pendingReplayPlan = await preparePlan(
    user,
    "test|external-recovery-owner",
    "external-recovery-device",
    "recovery-pending-plan-2",
    2,
  );
  await expect(
    user.mutation(anyApi.executions.beginExternalEffect, {
      ...pendingReplayPlan,
      ordinal: 0,
      provider: "agentmail",
      idempotencyKey: "recovery-pending-key-2",
      requestFingerprint: "opaque-pending-action",
    }),
  ).resolves.toEqual({ status: "reconcile", receiptId: pending.receiptId });

  const uncertainPlan = await preparePlan(
    user,
    "test|external-recovery-owner",
    "external-recovery-device",
    "recovery-uncertain-plan",
  );
  const uncertain = await user.mutation(anyApi.executions.beginExternalEffect, {
    ...uncertainPlan,
    ordinal: 0,
    provider: "agentmail",
    idempotencyKey: "recovery-uncertain-key-1",
    requestFingerprint: "opaque-uncertain-action",
  });
  await user.mutation(anyApi.executions.reconcileExternalEffect, {
    receiptId: uncertain.receiptId,
    status: "uncertain",
    requestFingerprint: "opaque-uncertain-action",
  });
  const uncertainReplayPlan = await preparePlan(
    user,
    "test|external-recovery-owner",
    "external-recovery-device",
    "recovery-uncertain-plan-2",
  );
  await expect(
    user.mutation(anyApi.executions.beginExternalEffect, {
      ...uncertainReplayPlan,
      ordinal: 0,
      provider: "agentmail",
      idempotencyKey: "recovery-uncertain-key-2",
      requestFingerprint: "opaque-uncertain-action",
    }),
  ).resolves.toEqual({ status: "reconcile", receiptId: uncertain.receiptId });

  const succeededPlan = await preparePlan(
    user,
    "test|external-recovery-owner",
    "external-recovery-device",
    "recovery-succeeded-plan",
  );
  const succeeded = await user.mutation(anyApi.executions.beginExternalEffect, {
    ...succeededPlan,
    ordinal: 0,
    provider: "agentmail",
    idempotencyKey: "recovery-succeeded-key-1",
    requestFingerprint: "opaque-succeeded-action",
  });
  await user.mutation(anyApi.executions.reconcileExternalEffect, {
    receiptId: succeeded.receiptId,
    status: "succeeded",
    requestFingerprint: "opaque-succeeded-action",
  });
  const succeededReplayPlan = await preparePlan(
    user,
    "test|external-recovery-owner",
    "external-recovery-device",
    "recovery-succeeded-plan-2",
  );
  await expect(
    user.mutation(anyApi.executions.beginExternalEffect, {
      ...succeededReplayPlan,
      ordinal: 0,
      provider: "agentmail",
      idempotencyKey: "recovery-succeeded-key-2",
      requestFingerprint: "opaque-succeeded-action",
    }),
  ).resolves.toEqual({ status: "succeeded", receiptId: succeeded.receiptId });

  const differentFingerprintPlan = await preparePlan(
    user,
    "test|external-recovery-owner",
    "external-recovery-device",
    "recovery-different-plan",
  );
  const differentFingerprint = await user.mutation(
    anyApi.executions.beginExternalEffect,
    {
      ...differentFingerprintPlan,
      ordinal: 0,
      provider: "agentmail",
      idempotencyKey: "recovery-different-key",
      requestFingerprint: "opaque-different-action",
    },
  );
  expect(differentFingerprint).toMatchObject({ status: "pending" });
  expect(differentFingerprint.receiptId).not.toBe(succeeded.receiptId);

  const otherDevicePlan = await preparePlan(
    user,
    "test|external-recovery-owner",
    "external-recovery-other-device",
    "recovery-other-device-plan",
  );
  const otherDevice = await user.mutation(
    anyApi.executions.beginExternalEffect,
    {
      ...otherDevicePlan,
      ordinal: 0,
      provider: "agentmail",
      idempotencyKey: "recovery-succeeded-key-1",
      requestFingerprint: "opaque-succeeded-action",
    },
  );
  expect(otherDevice).toMatchObject({ status: "pending" });
  expect(otherDevice.receiptId).not.toBe(succeeded.receiptId);

  const otherOwnerPlan = await preparePlan(
    otherUser,
    "test|external-recovery-other-owner",
    "external-recovery-device",
    "recovery-other-owner-plan",
  );
  const otherOwner = await otherUser.mutation(
    anyApi.executions.beginExternalEffect,
    {
      ...otherOwnerPlan,
      ordinal: 0,
      provider: "agentmail",
      idempotencyKey: "recovery-succeeded-key-1",
      requestFingerprint: "opaque-succeeded-action",
    },
  );
  expect(otherOwner).toMatchObject({ status: "pending" });
  expect(otherOwner.receiptId).not.toBe(succeeded.receiptId);
});
