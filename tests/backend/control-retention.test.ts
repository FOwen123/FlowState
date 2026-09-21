import { expect, it } from "vitest";
import { anyApi, makeFunctionReference } from "convex/server";
import { convexTest } from "convex-test";

import schema from "../../convex/schema";

const modules = {
  ...import.meta.glob("../../convex/**/*.ts"),
  "../../convex/_generated/test-root.ts": async () => ({}),
};

it("purges old settled control receipts but preserves uncertain effects", async () => {
  const purgeExpired = makeFunctionReference<
    "mutation",
    { maxRecords?: number },
    unknown
  >("retention:purgeExpired");
  const t = convexTest(schema, modules);
  const old = Date.now() - 40 * 24 * 60 * 60 * 1_000;
  const ownerKey = "control-retention-owner";
  const planId = await t.run((ctx) =>
    ctx.db.insert("actionPlans", {
      ownerKey,
      deviceId: "retention-device",
      command: "control receipt plan",
      locale: "en",
      status: "succeeded",
      cancellationGeneration: 1,
      expiresAt: old,
      createdAt: old,
      updatedAt: old,
    }),
  );
  const settledId = await t.run((ctx) =>
    ctx.db.insert("actionExecutionReceipts", {
      ownerKey,
      deviceId: "retention-device",
      planId,
      ordinal: 0,
      generation: 1,
      provider: "agentmail",
      idempotencyKey: "settled-receipt-1",
      requestFingerprint: "settled-fingerprint",
      status: "succeeded",
      createdAt: old,
      updatedAt: old,
    }),
  );
  const approvalId = await t.run((ctx) =>
    ctx.db.insert("actionStepApprovals", {
      ownerKey,
      deviceId: "retention-device",
      planId,
      ordinal: 0,
      generation: 1,
      planFingerprint: "retention-plan",
      actionFingerprint: "retention-action",
      expiresAt: old,
      createdAt: old,
      updatedAt: old,
    }),
  );
  const uncertainId = await t.run((ctx) =>
    ctx.db.insert("actionExecutionReceipts", {
      ownerKey,
      deviceId: "retention-device",
      planId,
      ordinal: 1,
      generation: 1,
      provider: "agentmail",
      idempotencyKey: "uncertain-receipt-1",
      requestFingerprint: "uncertain-fingerprint",
      status: "uncertain",
      createdAt: old,
      updatedAt: old,
    }),
  );
  await expect(t.mutation(purgeExpired, { maxRecords: 20 })).resolves.toMatchObject({
    preservedUncertain: 1,
  });
  await expect(t.run((ctx) => ctx.db.get(settledId))).resolves.toBeNull();
  await expect(t.run((ctx) => ctx.db.get(uncertainId))).resolves.toMatchObject({
    status: "uncertain",
  });
  await expect(t.run((ctx) => ctx.db.get(approvalId))).resolves.toBeNull();
});

it("deletes step approvals with plans during user data deletion", async () => {
  const t = convexTest(schema, modules);
  const ownerKey = "control-retention-delete-owner";
  const user = t.withIdentity({ tokenIdentifier: ownerKey, subject: ownerKey });
  const planId = await t.run((ctx) =>
    ctx.db.insert("actionPlans", {
      ownerKey,
      deviceId: "retention-delete-device",
      command: "approved plan",
      locale: "en",
      status: "approved",
      cancellationGeneration: 1,
      expiresAt: Date.now() + 60_000,
      createdAt: Date.now(),
      updatedAt: Date.now(),
    }),
  );
  const approvalId = await t.run((ctx) =>
    ctx.db.insert("actionStepApprovals", {
      ownerKey,
      deviceId: "retention-delete-device",
      planId,
      ordinal: 0,
      generation: 1,
      planFingerprint: "retention-delete-plan",
      actionFingerprint: "retention-delete-action",
      expiresAt: Date.now() + 60_000,
      createdAt: Date.now(),
      updatedAt: Date.now(),
    }),
  );
  await expect(
    user.mutation(anyApi.retention.deleteMyData, {
      includeDevices: false,
      maxRecords: 100,
    }),
  ).resolves.toMatchObject({ deleted: expect.any(Number), hasMore: false });
  await expect(t.run((ctx) => ctx.db.get(planId))).resolves.toBeNull();
  await expect(t.run((ctx) => ctx.db.get(approvalId))).resolves.toBeNull();
});

it("paginates plan deletion without leaving step approval orphans", async () => {
  const t = convexTest(schema, modules);
  const ownerKey = "control-retention-page-owner";
  const user = t.withIdentity({ tokenIdentifier: ownerKey, subject: ownerKey });
  const planIds = await t.run(async (ctx) => {
    const ids = [];
    for (const ordinal of [0, 1]) {
      const planId = await ctx.db.insert("actionPlans", {
        ownerKey,
        deviceId: "retention-page-device",
        command: `approved plan ${ordinal}`,
        locale: "en",
        status: "approved",
        cancellationGeneration: 1,
        expiresAt: Date.now() + 60_000,
        createdAt: Date.now(),
        updatedAt: Date.now(),
      });
      await ctx.db.insert("actionStepApprovals", {
        ownerKey,
        deviceId: "retention-page-device",
        planId,
        ordinal: 0,
        generation: 1,
        planFingerprint: `page-plan-${ordinal}`,
        actionFingerprint: `page-action-${ordinal}`,
        expiresAt: Date.now() + 60_000,
        createdAt: Date.now(),
        updatedAt: Date.now(),
      });
      ids.push(planId);
    }
    return ids;
  });
  await expect(
    user.mutation(anyApi.retention.deleteMyData, {
      includeDevices: false,
      maxRecords: 1,
    }),
  ).resolves.toMatchObject({ deleted: 1, hasMore: true });
  await expect(
    user.mutation(anyApi.retention.deleteMyData, {
      includeDevices: false,
      maxRecords: 1,
    }),
  ).resolves.toMatchObject({ deleted: 1, hasMore: false });
  await expect(
    t.run(async (ctx) => ({
      plans: await Promise.all(planIds.map((planId) => ctx.db.get(planId))),
      approvals: await ctx.db
        .query("actionStepApprovals")
        .withIndex("by_owner", (q) => q.eq("ownerKey", ownerKey))
        .collect(),
    })),
  ).resolves.toMatchObject({ plans: [null, null], approvals: [] });
});
