import { v } from "convex/values";
import { mutation, type MutationCtx } from "./_generated/server";
import type { Id } from "./_generated/dataModel";
import { requireIdentity } from "./lib/identity";
import type { PlannedAction } from "./lib/action_plan";

async function ownedPlan(ctx: MutationCtx, id: Id<"actionPlans">) {
  const owner = await requireIdentity(ctx);
  const plan = await ctx.db.get(id);
  if (!plan || plan.ownerKey !== owner.tokenIdentifier)
    throw new Error("action plan not found");
  return plan;
}
async function activeDevice(
  ctx: MutationCtx,
  ownerKey: string,
  deviceId: string,
) {
  const device = await ctx.db
    .query("devices")
    .withIndex("by_owner_device", (q) =>
      q.eq("ownerKey", ownerKey).eq("deviceId", deviceId),
    )
    .first();
  if (!device || device.revokedAt !== undefined)
    throw new Error("device is revoked");
}
export const start = mutation({
  args: { planId: v.id("actionPlans"), fingerprint: v.string() },
  handler: async (ctx, args) => {
    const plan = await ownedPlan(ctx, args.planId);
    await activeDevice(ctx, plan.ownerKey, plan.deviceId);
    if (plan.status !== "approved")
      throw new Error("plan is not approved or was already started");
    if (
      plan.expiresAt <= Date.now() ||
      plan.planFingerprint !== args.fingerprint
    )
      throw new Error("plan changed or expired");
    const actions = JSON.parse(plan.actionsJson ?? "[]") as PlannedAction[];
    if (
      !actions.length ||
      actions.some((action) => action.executor !== "desktop")
    )
      throw new Error("plan contains no executable desktop-only actions");
    await ctx.db.patch(plan._id, {
      status: "executing",
      completedSteps: 0,
      updatedAt: Date.now(),
    });
    return { generation: plan.cancellationGeneration };
  },
});
export const claimStep = mutation({
  args: {
    planId: v.id("actionPlans"),
    ordinal: v.number(),
    generation: v.number(),
  },
  handler: async (ctx, args) => {
    const plan = await ownedPlan(ctx, args.planId);
    await activeDevice(ctx, plan.ownerKey, plan.deviceId);
    if (
      plan.status !== "executing" ||
      plan.cancellationGeneration !== args.generation ||
      plan.expiresAt <= Date.now()
    )
      throw new Error("execution is cancelled or expired");
    if (plan.executingStep !== undefined)
      throw new Error("previous effect is pending or uncertain; do not replay");
    const actions = JSON.parse(plan.actionsJson ?? "[]") as PlannedAction[];
    if (
      !Number.isInteger(args.ordinal) ||
      args.ordinal !== (plan.completedSteps ?? 0) ||
      !actions[args.ordinal]
    )
      throw new Error("step is out of sequence");
    const action = actions[args.ordinal];
    const grants = await ctx.db
      .query("grants")
      .withIndex("by_owner_device", (q) =>
        q.eq("ownerKey", plan.ownerKey).eq("deviceId", plan.deviceId),
      )
      .collect();
    if (
      !grants.some(
        (g) =>
          g.revokedAt === undefined &&
          g.expiresAt > Date.now() &&
          g.capability === action.capability &&
          (g.target === undefined ||
            g.target === action.targetBundleIdentifier),
      )
    )
      throw new Error("action grant expired or revoked");
    await ctx.db.patch(plan._id, {
      executingStep: args.ordinal,
      updatedAt: Date.now(),
    });
    return { reserved: true };
  },
});
export const finishStep = mutation({
  args: {
    planId: v.id("actionPlans"),
    ordinal: v.number(),
    generation: v.number(),
    verified: v.boolean(),
  },
  handler: async (ctx, args) => {
    const plan = await ownedPlan(ctx, args.planId);
    // Recording an outcome is allowed after revocation; it cannot authorize another effect.
    if (
      plan.status !== "executing" ||
      plan.cancellationGeneration !== args.generation ||
      plan.executingStep !== args.ordinal
    )
      throw new Error("execution result is stale");
    const actions = JSON.parse(plan.actionsJson ?? "[]") as PlannedAction[];
    const completedSteps = (plan.completedSteps ?? 0) + (args.verified ? 1 : 0);
    const status = args.verified
      ? completedSteps === actions.length
        ? "succeeded"
        : "executing"
      : "uncertain";
    await ctx.db.patch(plan._id, {
      completedSteps,
      executingStep: undefined,
      status,
      updatedAt: Date.now(),
    });
    return { status, completedSteps };
  },
});
