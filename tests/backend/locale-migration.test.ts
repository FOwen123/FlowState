import { expect, it } from "vitest";
import { anyApi } from "convex/server";
import { convexTest } from "convex-test";

import schema from "../../convex/schema";

const modules = {
  ...import.meta.glob("../../convex/**/*.ts"),
  "../../convex/_generated/test-root.ts": async () => ({}),
};

it("removes Chinese locale from new plans while keeping legacy records readable", async () => {
  const t = convexTest(schema, modules);
  const user = t.withIdentity({ tokenIdentifier: "locale-owner", subject: "locale-owner" });
  await user.mutation(anyApi.workflows.registerDevice, { deviceId: "locale-device" });
  await expect(
    user.mutation(anyApi.plans.createActionPlan, {
      deviceId: "locale-device",
      command: "Open Brave",
      locale: "zh-Hant",
    }),
  ).rejects.toThrow();
  const planId = await t.run((ctx) =>
    ctx.db.insert("actionPlans", {
      ownerKey: "locale-owner",
      deviceId: "locale-device",
      command: "legacy plan",
      locale: "zh-Hant",
      status: "queued",
      cancellationGeneration: 0,
      expiresAt: Date.now() + 60_000,
      createdAt: Date.now(),
      updatedAt: Date.now(),
    }),
  );
  await expect(user.query(anyApi.plans.getActionPlan, { planId })).resolves.toMatchObject({ locale: "zh-Hant" });
});

it("runs a scoped idempotent locale migration without changing literal user content", async () => {
  const t = convexTest(schema, modules);
  const user = t.withIdentity({ tokenIdentifier: "locale-migrate-owner", subject: "locale-migrate-owner" });
  await user.mutation(anyApi.workflows.registerDevice, { deviceId: "locale-device" });
  const planId = await t.run((ctx) =>
    ctx.db.insert("actionPlans", {
      ownerKey: "locale-migrate-owner",
      deviceId: "locale-device",
      command: "legacy plan",
      locale: "zh-Hant",
      status: "queued",
      cancellationGeneration: 0,
      expiresAt: Date.now() + 60_000,
      createdAt: Date.now(),
      updatedAt: Date.now(),
    }),
  );
  await user.mutation(anyApi.preferences.set, {
    key: "writing.style",
    valueJson: JSON.stringify({ language: "zh-Hant", literal: "繁體中文內容" }),
    deviceId: "locale-device",
  });
  await expect(user.mutation(anyApi.migrations.migrateLegacyLocales, { maxRecords: 10 })).resolves.toMatchObject({
    actionPlans: 1,
    preferences: 1,
  });
  await expect(user.mutation(anyApi.migrations.migrateLegacyLocales, { maxRecords: 10 })).resolves.toMatchObject({
    actionPlans: 0,
    preferences: 0,
  });
  await expect(t.run((ctx) => ctx.db.get(planId))).resolves.toMatchObject({ locale: "en" });
  await expect(user.query(anyApi.preferences.get, { key: "writing.style" })).resolves.toMatchObject({
    value: { language: "en", literal: "繁體中文內容" },
  });
});

it("invalidates legacy control plans that still contain insertText", async () => {
  const t = convexTest(schema, modules);
  const user = t.withIdentity({ tokenIdentifier: "legacy-control-owner", subject: "legacy-control-owner" });
  await user.mutation(anyApi.workflows.registerDevice, { deviceId: "legacy-device" });
  const planId = await t.run((ctx) =>
    ctx.db.insert("actionPlans", {
      ownerKey: "legacy-control-owner",
      deviceId: "legacy-device",
      command: "legacy typing plan",
      locale: "en",
      status: "approved",
      actionsJson: JSON.stringify([
        {
          kind: "insertText",
          targetBundleIdentifier: "com.example.Editor",
          parameters: { text: "hello" },
        },
      ]),
      planFingerprint: "legacy-fingerprint",
      cancellationGeneration: 3,
      expiresAt: Date.now() + 60_000,
      createdAt: Date.now(),
      updatedAt: Date.now(),
    }),
  );

  await expect(
    user.mutation(anyApi.migrations.invalidateLegacyInsertTextPlans, {
      maxRecords: 10,
    }),
  ).resolves.toMatchObject({ invalidated: 1 });
  const invalidated = await t.run((ctx) => ctx.db.get(planId));
  expect(invalidated).toMatchObject({
    status: "failed",
    errorCode: "legacy_insertText_invalidated",
  });
  expect(invalidated?.actionsJson).toBeUndefined();
  expect(invalidated?.planFingerprint).toBeUndefined();
  await expect(
    user.mutation(anyApi.migrations.invalidateLegacyInsertTextPlans, {
      maxRecords: 10,
    }),
  ).resolves.toMatchObject({ invalidated: 0 });
});
