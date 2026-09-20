import { mutationGeneric, queryGeneric } from "convex/server";
import { v } from "convex/values";

import { requireIdentity } from "./lib/identity";
import {
  normalizePreferenceKey,
  normalizePreferenceValue,
  parsePreferenceValue,
} from "./lib/preferences";

export const list = queryGeneric({
  args: {},
  handler: async (ctx) => {
    const identity = await requireIdentity(ctx);
    const rows = await ctx.db
      .query("preferences")
      .withIndex("by_owner_key", (q) => q.eq("ownerKey", identity.tokenIdentifier))
      .order("asc")
      .collect();
    return rows.map((row) => ({
      key: row.key,
      value: parsePreferenceValue(row.valueJson),
      updatedAt: row.updatedAt,
    }));
  },
});

export const get = queryGeneric({
  args: { key: v.string() },
  handler: async (ctx, args) => {
    const identity = await requireIdentity(ctx);
    const key = normalizePreferenceKey(args.key);
    const row = await ctx.db
      .query("preferences")
      .withIndex("by_owner_key", (q) => q.eq("ownerKey", identity.tokenIdentifier))
      .filter((q) => q.eq(q.field("key"), key))
      .first();
    return row === null
      ? null
      : { key: row.key, value: parsePreferenceValue(row.valueJson), updatedAt: row.updatedAt };
  },
});

export const set = mutationGeneric({
  args: {
    key: v.string(),
    valueJson: v.string(),
    deviceId: v.optional(v.string()),
  },
  handler: async (ctx, args) => {
    const identity = await requireIdentity(ctx);
    const key = normalizePreferenceKey(args.key);
    const valueJson = normalizePreferenceValue(args.valueJson);
    if (args.deviceId !== undefined) {
      const device = await ctx.db
        .query("devices")
        .withIndex("by_owner_device", (q) => q.eq("ownerKey", identity.tokenIdentifier))
        .filter((q) => q.eq(q.field("deviceId"), args.deviceId!))
        .first();
      if (device === null || device.revokedAt !== undefined) {
        throw new Error("device is not active for this account");
      }
    }
    const timestamp = Date.now();
    const existing = await ctx.db
      .query("preferences")
      .withIndex("by_owner_key", (q) => q.eq("ownerKey", identity.tokenIdentifier))
      .filter((q) => q.eq(q.field("key"), key))
      .first();
    if (existing === null) {
      await ctx.db.insert("preferences", {
        ownerKey: identity.tokenIdentifier,
        key,
        valueJson,
        updatedAt: timestamp,
      });
    } else {
      await ctx.db.patch(existing._id, { valueJson, updatedAt: timestamp });
    }
    return { key, value: parsePreferenceValue(valueJson), updatedAt: timestamp };
  },
});

export const sync = mutationGeneric({
  args: {
    deviceId: v.optional(v.string()),
    changes: v.array(v.object({ key: v.string(), valueJson: v.string() })),
  },
  handler: async (ctx, args) => {
    const identity = await requireIdentity(ctx);
    if (args.changes.length > 50) throw new Error("at most 50 preferences may sync at once");
    if (args.deviceId !== undefined) {
      const device = await ctx.db
        .query("devices")
        .withIndex("by_owner_device", (q) => q.eq("ownerKey", identity.tokenIdentifier))
        .filter((q) => q.eq(q.field("deviceId"), args.deviceId!))
        .first();
      if (device === null || device.revokedAt !== undefined) {
        throw new Error("device is not active for this account");
      }
    }
    const applied: Array<{ key: string; updatedAt: number }> = [];
    for (const change of args.changes) {
      const key = normalizePreferenceKey(change.key);
      const valueJson = normalizePreferenceValue(change.valueJson);
      const existing = await ctx.db
        .query("preferences")
        .withIndex("by_owner_key", (q) => q.eq("ownerKey", identity.tokenIdentifier))
        .filter((q) => q.eq(q.field("key"), key))
        .first();
      const timestamp = Date.now();
      if (existing === null) {
        await ctx.db.insert("preferences", {
          ownerKey: identity.tokenIdentifier,
          key,
          valueJson,
          updatedAt: timestamp,
        });
      } else {
        await ctx.db.patch(existing._id, { valueJson, updatedAt: timestamp });
      }
      applied.push({ key, updatedAt: timestamp });
    }
    return { applied };
  },
});

export const remove = mutationGeneric({
  args: { key: v.string(), deviceId: v.optional(v.string()) },
  handler: async (ctx, args) => {
    const identity = await requireIdentity(ctx);
    const key = normalizePreferenceKey(args.key);
    if (args.deviceId !== undefined) {
      const device = await ctx.db
        .query("devices")
        .withIndex("by_owner_device", (q) => q.eq("ownerKey", identity.tokenIdentifier))
        .filter((q) => q.eq(q.field("deviceId"), args.deviceId!))
        .first();
      if (device === null || device.revokedAt !== undefined) {
        throw new Error("device is not active for this account");
      }
    }
    const existing = await ctx.db
      .query("preferences")
      .withIndex("by_owner_key", (q) => q.eq("ownerKey", identity.tokenIdentifier))
      .filter((q) => q.eq(q.field("key"), key))
      .first();
    if (existing !== null) await ctx.db.delete(existing._id);
    return { key, deleted: existing !== null };
  },
});
