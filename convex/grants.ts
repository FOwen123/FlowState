import { v } from "convex/values";
import { mutationGeneric, queryGeneric } from "convex/server";
import type { Id } from "./_generated/dataModel";

import { requireIdentity } from "./lib/identity";

const capabilities = new Set([
  "app.open",
  "app.observe",
  "app.control",
  "app.input",
  "app.upload",
  "file.read",
  "file.upload",
  "mail.read",
  "mail.send",
  "mail.draft",
  "spend.confirm",
]);

function requireCapability(capability: string): string {
  const value = capability.trim();
  if (!capabilities.has(value)) throw new Error("unknown capability");
  return value;
}

function requireTarget(target: string | undefined): string | undefined {
  if (target === undefined) return undefined;
  const value = target.trim();
  if (value.length === 0 || value.length > 320) throw new Error("grant target is invalid");
  return value;
}

function requireApplicationTargets(targets: string[]): string[] {
  if (targets.length === 0) throw new Error("at least one target is required");
  if (targets.length > 100) throw new Error("at most 100 targets are allowed");
  const values = targets.map((target) => {
    const value = requireTarget(target);
    if (value === undefined) throw new Error("grant target is invalid");
    return value;
  });
  if (new Set(values).size !== values.length)
    throw new Error("grant targets must be unique");
  return values;
}

export const list = queryGeneric({
  args: { deviceId: v.string() },
  handler: async (ctx, args) => {
    const identity = await requireIdentity(ctx);
    const device = await ctx.db
      .query("devices")
      .withIndex("by_owner_device", (q) => q.eq("ownerKey", identity.tokenIdentifier))
      .filter((q) => q.eq(q.field("deviceId"), args.deviceId))
      .first();
    const rows = await ctx.db
      .query("grants")
      .withIndex("by_owner_device", (q) => q.eq("ownerKey", identity.tokenIdentifier))
      .filter((q) => q.eq(q.field("deviceId"), args.deviceId))
      .order("desc")
      .collect();
    return rows.map((row) => ({
      id: String(row._id),
      capability: row.capability,
      target: row.target ?? null,
      expiresAt: row.expiresAt,
      revokedAt: row.revokedAt ?? null,
      active:
        device !== null &&
        device.revokedAt === undefined &&
        row.revokedAt === undefined &&
        row.expiresAt > Date.now(),
    }));
  },
});

export const grant = mutationGeneric({
  args: {
    deviceId: v.string(),
    capability: v.string(),
    target: v.optional(v.string()),
    expiresAt: v.number(),
  },
  handler: async (ctx, args) => {
    const identity = await requireIdentity(ctx);
    const device = await ctx.db
      .query("devices")
      .withIndex("by_owner_device", (q) => q.eq("ownerKey", identity.tokenIdentifier))
      .filter((q) => q.eq(q.field("deviceId"), args.deviceId))
      .first();
    if (device === null || device.revokedAt !== undefined) throw new Error("device is not active");
    const capability = requireCapability(args.capability);
    const target = requireTarget(args.target);
    const timestamp = Date.now();
    if (!Number.isFinite(args.expiresAt) || args.expiresAt <= timestamp || args.expiresAt > timestamp + 30 * 24 * 60 * 60 * 1_000) {
      throw new Error("grant expiry must be within 30 days");
    }
    const existing = await ctx.db
      .query("grants")
      .withIndex("by_owner_device", (q) => q.eq("ownerKey", identity.tokenIdentifier))
      .filter((q) => q.eq(q.field("deviceId"), args.deviceId))
      .filter((q) =>
        q.and(
          q.eq(q.field("capability"), capability),
          target === undefined ? q.eq(q.field("target"), undefined) : q.eq(q.field("target"), target),
          q.eq(q.field("revokedAt"), undefined),
        ),
      )
      .first();
    if (existing !== null) {
      await ctx.db.patch(existing._id, { expiresAt: args.expiresAt, createdAt: timestamp });
      return { grantId: existing._id, expiresAt: args.expiresAt };
    }
    const grantId = await ctx.db.insert("grants", {
      ownerKey: identity.tokenIdentifier,
      deviceId: args.deviceId,
      capability,
      ...(target === undefined ? {} : { target }),
      expiresAt: args.expiresAt,
      createdAt: timestamp,
    });
    return { grantId, expiresAt: args.expiresAt };
  },
});

export const grantApplicationOpenTargets = mutationGeneric({
  args: {
    deviceId: v.string(),
    targets: v.array(v.string()),
    expiresAt: v.number(),
  },
  handler: async (ctx, args) => {
    const identity = await requireIdentity(ctx);
    const device = await ctx.db
      .query("devices")
      .withIndex("by_owner_device", (q) =>
        q.eq("ownerKey", identity.tokenIdentifier),
      )
      .filter((q) => q.eq(q.field("deviceId"), args.deviceId))
      .first();
    if (device === null || device.revokedAt !== undefined)
      throw new Error("device is not active");

    const targets = requireApplicationTargets(args.targets);
    const timestamp = Date.now();
    if (
      !Number.isFinite(args.expiresAt) ||
      args.expiresAt <= timestamp ||
      args.expiresAt > timestamp + 30 * 24 * 60 * 60 * 1_000
    ) {
      throw new Error("grant expiry must be within 30 days");
    }

    const existing = await ctx.db
      .query("grants")
      .withIndex("by_owner_device", (q) =>
        q.eq("ownerKey", identity.tokenIdentifier),
      )
      .filter((q) => q.eq(q.field("deviceId"), args.deviceId))
      .filter((q) =>
        q.and(
          q.eq(q.field("capability"), "app.open"),
          q.eq(q.field("revokedAt"), undefined),
        ),
      )
      .collect();
    const existingByTarget = new Map(
      existing.flatMap((row) =>
        row.target === undefined ? [] : [[row.target, row] as const],
      ),
    );
    const grantIds: Array<Id<"grants">> = [];

    for (const target of targets) {
      const current = existingByTarget.get(target);
      if (current !== undefined) {
        await ctx.db.patch(current._id, {
          expiresAt: args.expiresAt,
          createdAt: timestamp,
        });
        grantIds.push(current._id);
        continue;
      }

      const grantId = await ctx.db.insert("grants", {
        ownerKey: identity.tokenIdentifier,
        deviceId: args.deviceId,
        capability: "app.open",
        target,
        expiresAt: args.expiresAt,
        createdAt: timestamp,
      });
      grantIds.push(grantId);
    }

    return { grantIds, expiresAt: args.expiresAt };
  },
});

export const revoke = mutationGeneric({
  args: { grantId: v.id("grants") },
  handler: async (ctx, args) => {
    const identity = await requireIdentity(ctx);
    const row = await ctx.db.get(args.grantId);
    if (row === null || row.ownerKey !== identity.tokenIdentifier) throw new Error("grant not found");
    if (row.revokedAt === undefined) await ctx.db.patch(args.grantId, { revokedAt: Date.now() });
    return { grantId: args.grantId, revoked: true };
  },
});
