import { internalMutationGeneric, mutationGeneric } from "convex/server";
import { v } from "convex/values";

import { requireIdentity } from "./lib/identity";

const RETENTION_DAYS = 30;

function retentionDays(): number {
  const value = Number(process.env.FLOWSTATE_RETENTION_DAYS ?? RETENTION_DAYS);
  return Number.isInteger(value) && value >= 1 && value <= 3650 ? value : RETENTION_DAYS;
}

function boundedLimit(value: number | undefined, maximum: number): number {
  const result = value ?? maximum;
  if (!Number.isInteger(result) || result < 1 || result > maximum) {
    throw new Error(`maxRecords must be between 1 and ${maximum}`);
  }
  return result;
}

export const deleteMyData = mutationGeneric({
  args: {
    includeDevices: v.optional(v.boolean()),
    maxRecords: v.optional(v.number()),
  },
  handler: async (ctx, args) => {
    const identity = await requireIdentity(ctx);
    const limit = boundedLimit(args.maxRecords, 500);
    let processed = 0;
    let preservedUncertain = 0;

    const preferences = await ctx.db
      .query("preferences")
      .withIndex("by_owner_key", (q) => q.eq("ownerKey", identity.tokenIdentifier))
      .take(limit);
    for (const row of preferences) {
      await ctx.db.delete(row._id);
      processed += 1;
    }
    const grants = await ctx.db
      .query("grants")
      .withIndex("by_owner_device", (q) => q.eq("ownerKey", identity.tokenIdentifier))
      .take(Math.max(0, limit - processed));
    for (const row of grants) {
      await ctx.db.delete(row._id);
      processed += 1;
    }

    const runs = await ctx.db
      .query("workflowRuns")
      .withIndex("by_owner", (q) => q.eq("ownerKey", identity.tokenIdentifier))
      .take(Math.max(0, limit - processed));
    for (const run of runs) {
      const deliveries = await ctx.db
        .query("deliveryAttempts")
        .withIndex("by_run", (q) => q.eq("runId", run._id))
        .collect();
      const unsafeDelivery = deliveries.some(
        (delivery) => delivery.status === "pending" || delivery.status === "uncertain",
      ) || run.status === "sending" || run.status === "uncertain";
      const steps = await ctx.db
        .query("workflowSteps")
        .withIndex("by_run", (q) => q.eq("runId", run._id))
        .collect();
      for (const step of steps) await ctx.db.delete(step._id);
      const sources = await ctx.db
        .query("researchSources")
        .withIndex("by_run", (q) => q.eq("runId", run._id))
        .collect();
      for (const source of sources) await ctx.db.delete(source._id);
      const approvals = await ctx.db
        .query("approvals")
        .withIndex("by_run", (q) => q.eq("runId", run._id))
        .collect();
      if (unsafeDelivery) {
        preservedUncertain += 1;
        for (const delivery of deliveries) {
          if (delivery.status === "pending") {
            await ctx.db.patch(delivery._id, { status: "uncertain", errorCode: "data_deleted" });
          }
        }
        for (const approval of approvals) {
          await ctx.db.patch(approval._id, {
            recipient: "redacted@invalid",
            subject: "[redacted]",
            body: "[redacted]",
            actionFingerprint: "redacted",
            status: "rejected",
          });
        }
        await ctx.db.patch(run._id, {
          query: "[redacted]",
          sourceUrl: undefined,
          previewTitle: undefined,
          previewBody: undefined,
          previewJson: undefined,
          status: "uncertain",
          errorCode: "data_deleted_external_effect_uncertain",
          updatedAt: Date.now(),
        });
      } else {
        for (const approval of approvals) await ctx.db.delete(approval._id);
        for (const delivery of deliveries) await ctx.db.delete(delivery._id);
        await ctx.db.delete(run._id);
      }
      processed += 1;
    }

    const plans = await ctx.db
      .query("actionPlans")
      .withIndex("by_owner", (q) => q.eq("ownerKey", identity.tokenIdentifier))
      .take(Math.max(0, limit - processed));
    for (const plan of plans) {
      if (plan.status === "executing" || plan.status === "uncertain") {
        preservedUncertain += 1;
        await ctx.db.patch(plan._id, {
          status: "uncertain",
          command: "[redacted]",
          explanation: undefined,
          actionsJson: undefined,
          capabilitiesJson: undefined,
          planFingerprint: undefined,
          errorCode: "data_deleted_external_effect_uncertain",
          updatedAt: Date.now(),
        });
      } else {
        await ctx.db.delete(plan._id);
      }
      processed += 1;
    }

    if (args.includeDevices === true && processed < limit) {
      const devices = await ctx.db
        .query("devices")
        .withIndex("by_owner_device", (q) => q.eq("ownerKey", identity.tokenIdentifier))
        .take(limit - processed);
      for (const device of devices) {
        await ctx.db.delete(device._id);
        processed += 1;
      }
      if (processed < limit) {
        const user = await ctx.db
          .query("users")
          .withIndex("by_owner_key", (q) => q.eq("ownerKey", identity.tokenIdentifier))
          .first();
        if (user !== null) {
          await ctx.db.delete(user._id);
          processed += 1;
        }
      }
    }

    const hasMoreContent =
      (await ctx.db
        .query("preferences")
        .withIndex("by_owner_key", (q) => q.eq("ownerKey", identity.tokenIdentifier))
        .first()) !== null ||
      (await ctx.db
        .query("grants")
        .withIndex("by_owner_device", (q) => q.eq("ownerKey", identity.tokenIdentifier))
        .first()) !== null ||
      (await ctx.db
        .query("workflowRuns")
        .withIndex("by_owner", (q) => q.eq("ownerKey", identity.tokenIdentifier))
        .first()) !== null ||
      (await ctx.db
        .query("actionPlans")
        .withIndex("by_owner", (q) => q.eq("ownerKey", identity.tokenIdentifier))
        .first()) !== null;
    const hasMoreDevices =
      args.includeDevices === true &&
      ((await ctx.db
        .query("devices")
        .withIndex("by_owner_device", (q) => q.eq("ownerKey", identity.tokenIdentifier))
        .first()) !== null ||
        (await ctx.db
          .query("users")
          .withIndex("by_owner_key", (q) => q.eq("ownerKey", identity.tokenIdentifier))
          .first()) !== null);
    return {
      deleted: processed,
      hasMore: hasMoreContent || hasMoreDevices,
      preservedUncertain,
      retentionDays: retentionDays(),
    };
  },
});

export const purgeExpired = internalMutationGeneric({
  args: { maxRecords: v.optional(v.number()) },
  handler: async (ctx, args) => {
    const limit = boundedLimit(args.maxRecords, 100);
    const cutoff = Date.now() - retentionDays() * 24 * 60 * 60 * 1_000;
    const runs = await ctx.db
      .query("workflowRuns")
      .filter((q) => q.lt(q.field("updatedAt"), cutoff))
      .take(Math.min(limit * 4, 500));
    let deleted = 0;
    let preservedUncertain = 0;
    for (const run of runs) {
      if (deleted >= limit) break;
      const deliveries = await ctx.db
        .query("deliveryAttempts")
        .withIndex("by_run", (q) => q.eq("runId", run._id))
        .collect();
      if (deliveries.some((delivery) => delivery.status === "pending" || delivery.status === "uncertain")) {
        preservedUncertain += 1;
        continue;
      }
      if (run.status === "sending" || run.status === "uncertain") {
        preservedUncertain += 1;
        continue;
      }
      const steps = await ctx.db
        .query("workflowSteps")
        .withIndex("by_run", (q) => q.eq("runId", run._id))
        .collect();
      for (const step of steps) await ctx.db.delete(step._id);
      const sources = await ctx.db
        .query("researchSources")
        .withIndex("by_run", (q) => q.eq("runId", run._id))
        .collect();
      for (const source of sources) await ctx.db.delete(source._id);
      const approvals = await ctx.db
        .query("approvals")
        .withIndex("by_run", (q) => q.eq("runId", run._id))
        .collect();
      for (const approval of approvals) await ctx.db.delete(approval._id);
      for (const delivery of deliveries) await ctx.db.delete(delivery._id);
      await ctx.db.delete(run._id);
      deleted += 1;
    }
    const currentPeriod = new Date().toISOString().slice(0, 10);
    const oldPlans = await ctx.db
      .query("actionPlans")
      .filter((q) => q.lt(q.field("updatedAt"), cutoff))
      .take(Math.min(Math.max(limit - deleted, 0) * 4, 500));
    for (const plan of oldPlans) {
      if (deleted >= limit) break;
      if (plan.status === "executing" || plan.status === "uncertain") {
        preservedUncertain += 1;
        continue;
      }
      await ctx.db.delete(plan._id);
      deleted += 1;
    }
    const oldEvents = await ctx.db
      .query("agentMailEvents")
      .filter((q) => q.lt(q.field("receivedAt"), cutoff))
      .take(Math.min(Math.max(limit - deleted, 0) * 4, 500));
    for (const event of oldEvents) {
      if (deleted >= limit) break;
      await ctx.db.delete(event._id);
      deleted += 1;
    }
    const usage = await ctx.db
      .query("usageCounters")
      .filter((q) => q.lt(q.field("period"), currentPeriod))
      .take(Math.min(Math.max(limit - deleted, 0) * 4, 500));
    for (const row of usage) {
      if (deleted >= limit) break;
      await ctx.db.delete(row._id);
      deleted += 1;
    }
    return { deleted, preservedUncertain, cutoff, retentionDays: retentionDays() };
  },
});
