import { v } from "convex/values";
import { mutation, type MutationCtx } from "./_generated/server";
import type { Id } from "./_generated/dataModel";
import { requireIdentity } from "./lib/identity";
import {
  containsLegacyInsertTextJson,
  normalizeStoredActions,
  parsePlanAvailability,
  plannedActionFingerprint,
  type PlannedAction,
} from "./lib/action_plan";

function planActions(plan: {
  actionsJson?: string;
  supportedToolsJson?: string;
  integrationsJson?: string;
  applicationCandidatesJson?: string;
}): PlannedAction[] {
  const availability = parsePlanAvailability(
    plan.supportedToolsJson,
    plan.integrationsJson,
    plan.applicationCandidatesJson,
  );
  return normalizeStoredActions(
    JSON.parse(plan.actionsJson ?? "[]") as unknown,
    availability,
  );
}

async function expireStepApprovals(
  ctx: MutationCtx,
  planId: Id<"actionPlans">,
): Promise<void> {
  const approvals = await ctx.db
    .query("actionStepApprovals")
    .withIndex("by_plan_step", (q) => q.eq("planId", planId))
    .collect();
  const now = Date.now();
  for (const approval of approvals) {
    if (approval.consumedAt === undefined && approval.expiresAt > now) {
      await ctx.db.patch(approval._id, { expiresAt: now, updatedAt: now });
    }
  }
}

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
    if (containsLegacyInsertTextJson(plan.actionsJson)) {
      throw new Error("legacy insertText plan must be invalidated before use");
    }
    const actions = planActions(plan);
    if (!actions.length) throw new Error("plan contains no executable actions");
    const hasVisualAction = actions.some(
      (action) =>
        action.route === "visualComputerUse" || action.visualTarget !== undefined,
    );
    if (hasVisualAction) {
      const activePlans = await ctx.db
        .query("actionPlans")
        .withIndex("by_owner_device", (q) =>
          q.eq("ownerKey", plan.ownerKey).eq("deviceId", plan.deviceId),
        )
        .collect();
      const anotherVisualPlan = activePlans.some((candidate) => {
        if (candidate._id === plan._id) return false;
        if (!["approved", "executing"].includes(candidate.status)) return false;
        if (!candidate.actionsJson) return false;
        try {
          const candidateActions = JSON.parse(candidate.actionsJson) as unknown;
          return (
            Array.isArray(candidateActions) &&
            candidateActions.some(
              (action) =>
                typeof action === "object" &&
                action !== null &&
                ((action as { route?: unknown }).route === "visualComputerUse" ||
                  (action as { visualTarget?: unknown }).visualTarget !== undefined),
            )
          );
        } catch {
          return false;
        }
      });
      if (anotherVisualPlan) throw new Error("another visual plan is already active");
    }
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
    contextRevision: v.optional(v.number()),
    observationObservedAt: v.optional(v.number()),
  },
  handler: async (ctx, args) => {
    const plan = await ownedPlan(ctx, args.planId);
    await activeDevice(ctx, plan.ownerKey, plan.deviceId);
    if (
      plan.status !== "executing" ||
      plan.cancellationGeneration !== args.generation ||
      (plan.contextRevision !== undefined &&
        args.contextRevision !== plan.contextRevision) ||
      plan.expiresAt <= Date.now()
    )
      throw new Error("execution is cancelled or expired");
    if (plan.executingStep !== undefined)
      throw new Error("previous effect is pending or uncertain; do not replay");
    const actions = planActions(plan);
    if (
      !Number.isInteger(args.ordinal) ||
      args.ordinal !== (plan.completedSteps ?? 0) ||
      !actions[args.ordinal]
    )
      throw new Error("step is out of sequence");
    const action = actions[args.ordinal];
    const requiresFreshObservation =
      action.route === "visualComputerUse" ||
      action.preconditions?.requiresFreshObservation === true ||
      action.visualTarget !== undefined;
    if (requiresFreshObservation) {
      const observedAt = args.observationObservedAt;
      if (
        observedAt === undefined ||
        !Number.isFinite(observedAt) ||
        observedAt < Date.now() - 30_000 ||
        (action.visualTarget !== undefined &&
          observedAt <= action.visualTarget.observedAt)
      ) {
        throw new Error("step requires a fresh observation");
      }
    }
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
    if (action.requiresApproval) {
      const now = Date.now();
      const actionFingerprint = plannedActionFingerprint(action);
      const approvals = await ctx.db
        .query("actionStepApprovals")
        .withIndex("by_plan_step", (q) =>
          q.eq("planId", plan._id).eq("ordinal", args.ordinal),
        )
        .collect();
      const approval = approvals.find(
        (candidate) =>
          candidate.ownerKey === plan.ownerKey &&
          candidate.deviceId === plan.deviceId &&
          candidate.generation === args.generation &&
          candidate.planFingerprint === plan.planFingerprint &&
          candidate.actionFingerprint === actionFingerprint &&
          candidate.consumedAt === undefined &&
          candidate.expiresAt > now,
      );
      if (approval === undefined) {
        throw new Error("step approval is required or stale");
      }
      await ctx.db.patch(approval._id, { consumedAt: now, updatedAt: now });
    }
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
    const actions = planActions(plan);
    const action = actions[args.ordinal];
    if (action?.executor === "service") {
      const receipts = await ctx.db
        .query("actionExecutionReceipts")
        .withIndex("by_plan_step", (q) =>
          q.eq("planId", plan._id).eq("ordinal", args.ordinal),
        )
        .collect();
      const receipt = receipts.find(
        (candidate) => candidate.generation === args.generation,
      );
      if (receipt?.status !== "succeeded") {
        throw new Error("external effect must be reconciled before completion");
      }
    }
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
    await expireStepApprovals(ctx, plan._id);
    return { status, completedSteps };
  },
});

export const approveStep = mutation({
  args: {
    planId: v.id("actionPlans"),
    ordinal: v.number(),
    generation: v.number(),
    fingerprint: v.string(),
  },
  handler: async (ctx, args) => {
    const plan = await ownedPlan(ctx, args.planId);
    await activeDevice(ctx, plan.ownerKey, plan.deviceId);
    if (
      !["approved", "executing"].includes(plan.status) ||
      plan.cancellationGeneration !== args.generation ||
      plan.expiresAt <= Date.now() ||
      plan.planFingerprint === undefined ||
      plan.planFingerprint !== args.fingerprint ||
      args.fingerprint.trim().length === 0 ||
      args.fingerprint.length > 50_000
    ) {
      throw new Error("step approval is stale or plan changed");
    }
    if (plan.executingStep !== undefined) {
      throw new Error("step approval is stale or step is already reserved");
    }
    const actions = planActions(plan);
    const completedSteps = plan.completedSteps ?? 0;
    if (
      !Number.isInteger(args.ordinal) ||
      args.ordinal !== completedSteps ||
      actions[args.ordinal] === undefined
    ) {
      throw new Error("step approval is out of sequence");
    }
    const action = actions[args.ordinal];
    if (!action.requiresApproval) throw new Error("step does not require approval");
    const now = Date.now();
    const actionFingerprint = plannedActionFingerprint(action);
    const prior = await ctx.db
      .query("actionStepApprovals")
      .withIndex("by_plan_step", (q) =>
        q.eq("planId", plan._id).eq("ordinal", args.ordinal),
      )
      .collect();
    for (const approval of prior) {
      if (approval.consumedAt === undefined && approval.expiresAt > now) {
        throw new Error("step approval already exists");
      }
    }
    const expiresAt = Math.min(plan.expiresAt, now + 10 * 60_000);
    await ctx.db.insert("actionStepApprovals", {
      ownerKey: plan.ownerKey,
      deviceId: plan.deviceId,
      planId: plan._id,
      ordinal: args.ordinal,
      generation: args.generation,
      planFingerprint: args.fingerprint,
      actionFingerprint,
      expiresAt,
      createdAt: now,
      updatedAt: now,
    });
    return {
      approved: true as const,
      planId: plan._id,
      ordinal: args.ordinal,
      generation: args.generation,
      fingerprint: args.fingerprint,
      actionFingerprint,
      expiresAt,
    };
  },
});

export const beginExternalEffect = mutation({
  args: {
    planId: v.id("actionPlans"),
    ordinal: v.number(),
    generation: v.number(),
    provider: v.string(),
    idempotencyKey: v.string(),
    requestFingerprint: v.string(),
  },
  handler: async (ctx, args) => {
    const plan = await ownedPlan(ctx, args.planId);
    await activeDevice(ctx, plan.ownerKey, plan.deviceId);
    if (
      plan.status !== "executing" ||
      plan.cancellationGeneration !== args.generation ||
      plan.executingStep !== args.ordinal ||
      plan.expiresAt <= Date.now()
    ) {
      throw new Error("external effect reservation is stale");
    }
    if (
      args.provider.trim().length === 0 ||
      args.provider.length > 64 ||
      args.idempotencyKey.trim().length < 8 ||
      args.idempotencyKey.length > 256 ||
      args.requestFingerprint.trim().length === 0 ||
      args.requestFingerprint.length > 256
    ) {
      throw new Error("external effect idempotency fields are invalid");
    }
    let actions: PlannedAction[];
    try {
      actions = planActions(plan);
    } catch {
      throw new Error("stored action plan is invalid");
    }
    const action = actions[args.ordinal];
    if (action?.executor !== "service") {
      throw new Error("external effect requires a structured service step");
    }
    const prior = await ctx.db
      .query("actionExecutionReceipts")
      .withIndex("by_idempotency", (q) =>
        q.eq("provider", args.provider).eq("idempotencyKey", args.idempotencyKey),
      )
      .collect();
    const ownerReceipts = prior.filter((receipt) => receipt.ownerKey === plan.ownerKey);
    const existing = ownerReceipts.find(
      (receipt) =>
        receipt.deviceId === plan.deviceId &&
        receipt.planId === plan._id &&
        receipt.ordinal === args.ordinal &&
        receipt.generation === args.generation,
    );
    if (existing === undefined && ownerReceipts.length > 0) {
      throw new Error("external effect idempotency key collision");
    }
    if (existing !== undefined) {
      if (existing.requestFingerprint !== args.requestFingerprint) {
        throw new Error("external effect idempotency key collision");
      }
      return {
        status:
          existing.status === "pending" || existing.status === "uncertain"
            ? ("reconcile" as const)
            : existing.status,
        receiptId: existing._id,
      };
    }
    const timestamp = Date.now();
    const receiptId = await ctx.db.insert("actionExecutionReceipts", {
      ownerKey: plan.ownerKey,
      deviceId: plan.deviceId,
      planId: args.planId,
      ordinal: args.ordinal,
      generation: args.generation,
      provider: args.provider,
      idempotencyKey: args.idempotencyKey,
      requestFingerprint: args.requestFingerprint,
      status: "pending",
      createdAt: timestamp,
      updatedAt: timestamp,
    });
    return { status: "pending" as const, receiptId };
  },
});

export const reconcileExternalEffect = mutation({
  args: {
    receiptId: v.id("actionExecutionReceipts"),
    status: v.union(
      v.literal("succeeded"),
      v.literal("failed"),
      v.literal("uncertain"),
    ),
    requestFingerprint: v.string(),
  },
  handler: async (ctx, args) => {
    const owner = await requireIdentity(ctx);
    const receipt = await ctx.db.get(args.receiptId);
    if (receipt === null || receipt.ownerKey !== owner.tokenIdentifier) {
      throw new Error("external effect receipt not found");
    }
    const plan = await ctx.db.get(receipt.planId);
    if (
      plan === null ||
      plan.ownerKey !== owner.tokenIdentifier ||
      plan.deviceId !== receipt.deviceId ||
      receipt.requestFingerprint !== args.requestFingerprint ||
      args.requestFingerprint.trim().length === 0 ||
      args.requestFingerprint.length > 256
    ) {
      throw new Error("external effect receipt fingerprint or scope is invalid");
    }
    if (receipt.status !== "pending" && receipt.status !== "uncertain") {
      throw new Error("external effect receipt is already reconciled");
    }
    await ctx.db.patch(receipt._id, {
      status: args.status,
      updatedAt: Date.now(),
    });
    return { status: args.status, receiptId: args.receiptId };
  },
});
