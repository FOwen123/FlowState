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
