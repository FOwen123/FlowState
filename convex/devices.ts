import { mutationGeneric, queryGeneric } from "convex/server";
import { v } from "convex/values";

import { requireIdentity } from "./lib/identity";

function requireDeviceId(deviceId: string): string {
  const value = deviceId.trim();
  if (!/^[A-Za-z0-9._:-]{8,128}$/.test(value)) {
    throw new Error("deviceId must be a stable 8-128 character identifier");
  }
  return value;
}

export const list = queryGeneric({
  args: {},
  handler: async (ctx) => {
    const identity = await requireIdentity(ctx);
    const rows = await ctx.db
      .query("devices")
      .withIndex("by_owner_device", (q) => q.eq("ownerKey", identity.tokenIdentifier))
      .order("asc")
      .collect();
    return rows.map((row) => ({
      id: String(row._id),
      deviceId: row.deviceId,
      name: row.name ?? null,
      createdAt: row.createdAt,
      lastSeenAt: row.lastSeenAt,
      revokedAt: row.revokedAt ?? null,
      active: row.revokedAt === undefined,
    }));
  },
});

export const revoke = mutationGeneric({
  args: { deviceId: v.string() },
  handler: async (ctx, args) => {
    const identity = await requireIdentity(ctx);
    const deviceId = requireDeviceId(args.deviceId);
    const row = await ctx.db
      .query("devices")
      .withIndex("by_owner_device", (q) => q.eq("ownerKey", identity.tokenIdentifier))
      .filter((q) => q.eq(q.field("deviceId"), deviceId))
      .first();
    if (row === null) throw new Error("device not found");
    const timestamp = Date.now();
    if (row.revokedAt === undefined) await ctx.db.patch(row._id, { revokedAt: timestamp });
    const plans = await ctx.db
      .query("actionPlans")
      .withIndex("by_owner_device", (q) => q.eq("ownerKey", identity.tokenIdentifier))
      .filter((q) => q.eq(q.field("deviceId"), deviceId))
      .collect();
    for (const plan of plans) {
      const approvals = await ctx.db
        .query("actionStepApprovals")
        .withIndex("by_plan_step", (q) => q.eq("planId", plan._id))
        .collect();
      for (const approval of approvals) {
        if (approval.consumedAt === undefined && approval.expiresAt > timestamp) {
          await ctx.db.patch(approval._id, { expiresAt: timestamp, updatedAt: timestamp });
        }
      }
      if (["queued", "planning", "awaiting_approval", "approved"].includes(plan.status)) {
        await ctx.db.patch(plan._id, {
          status: "cancelled",
          cancellationGeneration: plan.cancellationGeneration + 1,
          errorCode: "device_revoked",
          updatedAt: timestamp,
        });
      }
    }
    return { deviceId, revoked: true };
  },
});

export const assertActive = queryGeneric({
  args: { deviceId: v.string() },
  handler: async (ctx, args) => {
    const identity = await requireIdentity(ctx);
    const deviceId = requireDeviceId(args.deviceId);
    const row = await ctx.db
      .query("devices")
      .withIndex("by_owner_device", (q) => q.eq("ownerKey", identity.tokenIdentifier))
      .filter((q) => q.eq(q.field("deviceId"), deviceId))
      .first();
    return { active: row !== null && row.revokedAt === undefined };
  },
});
