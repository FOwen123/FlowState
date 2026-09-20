import {
  actionGeneric,
  FunctionReference,
  internalMutationGeneric,
  internalQueryGeneric,
  makeFunctionReference,
  mutationGeneric,
  queryGeneric,
} from "convex/server";
import { GenericId, v } from "convex/values";

import { requireIdentity } from "./lib/identity";
import { createOpenAIClient } from "./lib/openai";
import { normalizeModelPlan, parsePlannerText, PlannedAction } from "./lib/action_plan";
import { createTypeSafeClient } from "./lib/typesafe";
import { usageLimit } from "./usage";
import { isRecord } from "./lib/http";

type PlanId = GenericId<"actionPlans">;
type PlanStatus =
  | "queued"
  | "planning"
  | "awaiting_approval"
  | "approved"
  | "executing"
  | "succeeded"
  | "failed"
  | "cancelled"
  | "uncertain";

type StoredPlan = {
  _id: PlanId;
  ownerKey: string;
  deviceId: string;
  command: string;
  locale: "en" | "zh-Hant";
  status: PlanStatus;
  explanation?: string;
  actionsJson?: string;
  capabilitiesJson?: string;
  planFingerprint?: string;
  cancellationGeneration: number;
  expiresAt: number;
  errorCode?: string;
  createdAt: number;
  updatedAt: number;
};

type PlanClaim = { claim: true; plan: StoredPlan } | { claim: false; plan: StoredPlan };

const internalClaimPlan = makeFunctionReference<
  "mutation",
  { planId: PlanId; ownerKey: string },
  PlanClaim
>("plans:claimPlan") as unknown as FunctionReference<
  "mutation",
  "internal",
  { planId: PlanId; ownerKey: string },
  PlanClaim
>;
const internalSavePlan = makeFunctionReference<
  "mutation",
  {
    planId: PlanId;
    cancellationGeneration: number;
    explanation: string;
    actionsJson: string;
    capabilities: string[];
    fingerprint: string;
    clarificationNeeded: boolean;
  },
  null
>("plans:savePlan") as unknown as FunctionReference<
  "mutation",
  "internal",
  {
    planId: PlanId;
    cancellationGeneration: number;
    explanation: string;
    actionsJson: string;
    capabilities: string[];
    fingerprint: string;
    clarificationNeeded: boolean;
  },
  null
>;
const internalMarkPlan = makeFunctionReference<
  "mutation",
  { planId: PlanId; cancellationGeneration: number; status: PlanStatus; errorCode?: string },
  null
>("plans:markPlan") as unknown as FunctionReference<
  "mutation",
  "internal",
  { planId: PlanId; cancellationGeneration: number; status: PlanStatus; errorCode?: string },
  null
>;
const internalGetPlan = makeFunctionReference<"query", { planId: PlanId }, StoredPlan | null>(
  "plans:getPlanInternal",
) as unknown as FunctionReference<"query", "internal", { planId: PlanId }, StoredPlan | null>;

function requireDeviceId(deviceId: string): string {
  const value = deviceId.trim();
  if (!/^[A-Za-z0-9._:-]{8,128}$/.test(value)) {
    throw new Error("deviceId must be a stable 8-128 character identifier");
  }
  return value;
}

function requireCommand(command: string): string {
  const value = command.trim();
  if (value.length < 2 || value.length > 4_000) throw new Error("command must contain 2-4000 characters");
  return value;
}

function requireLocale(locale: string): "en" | "zh-Hant" {
  if (locale !== "en" && locale !== "zh-Hant") throw new Error("locale must be en or zh-Hant");
  return locale;
}

function parseActions(actionsJson: string): PlannedAction[] {
  try {
    const value = JSON.parse(actionsJson) as unknown;
    if (!Array.isArray(value)) throw new Error("actions are not an array");
    return value as PlannedAction[];
  } catch {
    throw new Error("stored action plan is invalid");
  }
}

function parseCapabilities(value: string | undefined): string[] {
  if (value === undefined) return [];
  try {
    const parsed = JSON.parse(value) as unknown;
    if (!Array.isArray(parsed) || parsed.some((item) => typeof item !== "string")) return [];
    return parsed as string[];
  } catch {
    return [];
  }
}

function screenshotDataUrl(value: string | undefined): string | undefined {
  if (value === undefined) return undefined;
  if (value.length > 2_000_000) throw new Error("screenshot exceeds the 2MB limit");
  if (!/^data:image\/(?:png|jpeg);base64,[A-Za-z0-9+/=]+$/.test(value)) {
    throw new Error("screenshot must be a PNG or JPEG data URL");
  }
  return value;
}

export const createActionPlan = mutationGeneric({
  args: {
    deviceId: v.string(),
    command: v.string(),
    locale: v.union(v.literal("en"), v.literal("zh-Hant")),
    expiresAt: v.optional(v.number()),
  },
  handler: async (ctx, args) => {
    const identity = await requireIdentity(ctx);
    const deviceId = requireDeviceId(args.deviceId);
    const device = await ctx.db
      .query("devices")
      .withIndex("by_owner_device", (q) => q.eq("ownerKey", identity.tokenIdentifier))
      .filter((q) => q.eq(q.field("deviceId"), deviceId))
      .first();
    if (device === null || device.revokedAt !== undefined) throw new Error("device is not active");
    const command = requireCommand(args.command);
    const timestamp = Date.now();
    const expiresAt = args.expiresAt ?? timestamp + 10 * 60 * 1_000;
    if (!Number.isFinite(expiresAt) || expiresAt <= timestamp || expiresAt > timestamp + 60 * 60 * 1_000) {
      throw new Error("plan expiry must be within one hour");
    }
    const period = new Date(timestamp).toISOString().slice(0, 10);
    const usage = await ctx.db
      .query("usageCounters")
      .withIndex("by_owner_period", (q) => q.eq("ownerKey", identity.tokenIdentifier))
      .filter((q) => q.eq(q.field("period"), period))
      .first();
    const planningCount = (usage?.planningCount ?? 0) + 1;
    if (planningCount > usageLimit("planning")) throw new Error("planning daily usage limit reached");
    if (usage === null) {
      await ctx.db.insert("usageCounters", {
        ownerKey: identity.tokenIdentifier,
        period,
        researchCount: 0,
        planningCount,
        mailCount: 0,
        providerBytes: 0,
        updatedAt: timestamp,
      });
    } else {
      await ctx.db.patch(usage._id, { planningCount, updatedAt: timestamp });
    }
    const planId = await ctx.db.insert("actionPlans", {
      ownerKey: identity.tokenIdentifier,
      deviceId,
      command,
      locale: args.locale,
      status: "queued",
      cancellationGeneration: 0,
      expiresAt,
      createdAt: timestamp,
      updatedAt: timestamp,
    });
    return { planId, status: "queued" as const, expiresAt };
  },
});

export const getActionPlan = queryGeneric({
  args: { planId: v.id("actionPlans") },
  handler: async (ctx, args) => {
    const identity = await requireIdentity(ctx);
    const plan = await ctx.db.get(args.planId);
    if (plan === null || plan.ownerKey !== identity.tokenIdentifier) throw new Error("action plan not found");
    const device = await ctx.db
      .query("devices")
      .withIndex("by_owner_device", (q) => q.eq("ownerKey", identity.tokenIdentifier))
      .filter((q) => q.eq(q.field("deviceId"), plan.deviceId))
      .first();
    if (device === null || device.revokedAt !== undefined) throw new Error("device has been revoked");
    return {
      id: String(plan._id),
      command: plan.command,
      locale: plan.locale,
      status: plan.status,
      explanation: plan.explanation ?? null,
      actions: plan.actionsJson === undefined ? [] : parseActions(plan.actionsJson),
      capabilities: parseCapabilities(plan.capabilitiesJson),
      fingerprint: plan.planFingerprint ?? null,
      expiresAt: plan.expiresAt,
      error: plan.errorCode ?? null,
      cancellationGeneration: plan.cancellationGeneration,
    };
  },
});

export const resolveActionPlan = actionGeneric({
  args: { planId: v.id("actionPlans"), screenshot: v.optional(v.string()) },
  handler: async (ctx, args) => {
    const identity = await requireIdentity(ctx);
    const claim = await ctx.runMutation(internalClaimPlan, {
      planId: args.planId,
      ownerKey: identity.tokenIdentifier,
    });
    const plan = claim.plan;
    if (!claim.claim) {
      if (plan.status === "awaiting_approval" || plan.status === "approved") {
        return { planId: args.planId, status: plan.status, fingerprint: plan.planFingerprint ?? null };
      }
      throw new Error(`action plan is ${plan.status}`);
    }
    try {
      const screenshot = screenshotDataUrl(args.screenshot);
      if (process.env.TYPESAFE_API_KEY !== undefined) {
        const route = await createTypeSafeClient({
          apiKey: process.env.TYPESAFE_API_KEY,
          model: process.env.FLOWSTATE_JEV_MODEL,
        }).chooseCandidate({
          state: { command: plan.command, locale: plan.locale },
          candidates: {
            desktop: "A registered desktop action plan is appropriate",
            clarify: "The request needs user clarification before planning",
          },
        });
        if (route.choice === "clarify" || (route.confidence !== undefined && route.confidence < 0.55)) {
          throw new Error("action request needs clarification");
        }
      }
      const openai = createOpenAIClient({
        apiKey: process.env.OPENAI_API_KEY,
        model: process.env.FLOWSTATE_PLANNER_MODEL,
      });
      const inputParts: Array<Record<string, unknown>> = [
        {
          type: "input_text",
          text: `Locale: ${plan.locale}\nCommand: ${plan.command}\nReturn only JSON with actions, explanation, and clarificationNeeded. Use only registered action kinds: openApplication, scroll, focus, select, press, insertText, openURL, attachFile, sendEmail. Never invent permissions or file paths.`,
        },
      ];
      if (screenshot !== undefined) {
        inputParts.push({ type: "input_image", image_url: screenshot });
      }
      const response = await openai.createResponse({
        input: [{ role: "user", content: inputParts }],
        instructions:
          "You are a constrained planner. Model output is a proposal only. Return strict JSON: {actions:[{kind,targetBundleIdentifier,parameters}],explanation,clarificationNeeded}. Every desktop action requires its own targetBundleIdentifier, including scroll and insertText; repeat the selected app identifier on each step. Parameters: openApplication {}; scroll {lines: integer from -100 to 100, negative means down}; insertText {text: string, replaceSelection: true}; focus {role: string, label?: string}; select {label: string}; press {key: ArrowUp|ArrowDown|ArrowLeft|ArrowRight|PageUp|PageDown|Home|End|Tab|Escape|Enter, modifiers?: Shift}; openURL {url: http(s) URL}; attachFile {fileId: existing approved ID}; sendEmail {recipient,subject,body}. Use 1 to 12 actions. Do not include executor, capability or requiresApproval; the server supplies them. Omit visualTarget unless supplied with verified current geometry. Never infer unknown file IDs or permissions. Do not include markdown.",
      });
      const normalized = parsePlannerText(response.outputText);
      await ctx.runMutation(internalSavePlan, {
        planId: args.planId,
        cancellationGeneration: plan.cancellationGeneration,
        explanation: normalized.explanation,
        actionsJson: JSON.stringify(normalized.actions),
        capabilities: normalized.capabilities,
        fingerprint: normalized.fingerprint,
        clarificationNeeded: normalized.clarificationNeeded,
      });
      return {
        planId: args.planId,
        status: "awaiting_approval" as const,
        fingerprint: normalized.fingerprint,
        actions: normalized.actions,
        capabilities: normalized.capabilities,
      };
    } catch (error) {
      await ctx.runMutation(internalMarkPlan, {
        planId: args.planId,
        cancellationGeneration: plan.cancellationGeneration,
        status: "failed",
        errorCode: error instanceof Error ? error.message.slice(0, 240) : "planner_failed",
      });
      throw error;
    }
  },
});

export const approveActionPlan = mutationGeneric({
  args: { planId: v.id("actionPlans"), fingerprint: v.string() },
  handler: async (ctx, args) => {
    const identity = await requireIdentity(ctx);
    const plan = await ctx.db.get(args.planId);
    if (plan === null || plan.ownerKey !== identity.tokenIdentifier) throw new Error("action plan not found");
    if (plan.status !== "awaiting_approval") throw new Error("action plan is not awaiting approval");
    if (plan.expiresAt <= Date.now()) throw new Error("action plan has expired");
    if (plan.errorCode === "clarification_required") throw new Error("action plan needs clarification");
    if (plan.planFingerprint !== args.fingerprint) throw new Error("action plan changed; review it again");
    const device = await ctx.db
      .query("devices")
      .withIndex("by_owner_device", (q) => q.eq("ownerKey", identity.tokenIdentifier))
      .filter((q) => q.eq(q.field("deviceId"), plan.deviceId))
      .first();
    if (device === null || device.revokedAt !== undefined) throw new Error("device is not active");
    const actions = plan.actionsJson === undefined ? [] : parseActions(plan.actionsJson);
    const grants = await ctx.db
      .query("grants")
      .withIndex("by_owner_device", (q) => q.eq("ownerKey", identity.tokenIdentifier))
      .filter((q) => q.eq(q.field("deviceId"), plan.deviceId))
      .collect();
    const timestamp = Date.now();
    for (const action of actions) {
      const target = action.targetBundleIdentifier;
      const allowed = grants.some(
        (grant) =>
          grant.capability === action.capability &&
          grant.revokedAt === undefined &&
          grant.expiresAt > timestamp &&
          (grant.target === undefined ? true : target !== undefined && grant.target === target),
      );
      if (!allowed) throw new Error(`missing active grant for ${action.capability}`);
    }
    await ctx.db.patch(args.planId, { status: "approved", updatedAt: timestamp });
    return { planId: args.planId, status: "approved" as const, fingerprint: args.fingerprint };
  },
});

export const cancelActionPlan = mutationGeneric({
  args: { planId: v.id("actionPlans") },
  handler: async (ctx, args) => {
    const identity = await requireIdentity(ctx);
    const plan = await ctx.db.get(args.planId);
    if (plan === null || plan.ownerKey !== identity.tokenIdentifier) throw new Error("action plan not found");
    if (["succeeded", "failed", "cancelled"].includes(plan.status)) {
      throw new Error(`action plan cannot be cancelled while ${plan.status}`);
    }
    const status = plan.executingStep !== undefined || plan.status === "uncertain" ? "uncertain" : "cancelled";
    await ctx.db.patch(args.planId, {
      status,
      cancellationGeneration: plan.cancellationGeneration + 1,
      errorCode: "cancelled",
      updatedAt: Date.now(),
    });
    return { planId: args.planId, status };
  },
});

export const claimPlan = internalMutationGeneric({
  args: { planId: v.id("actionPlans"), ownerKey: v.string() },
  handler: async (ctx, args): Promise<PlanClaim> => {
    const plan = await ctx.db.get(args.planId);
    if (plan === null || plan.ownerKey !== args.ownerKey) throw new Error("action plan not found");
    const device = await ctx.db
      .query("devices")
      .withIndex("by_owner_device", (q) => q.eq("ownerKey", args.ownerKey))
      .filter((q) => q.eq(q.field("deviceId"), plan.deviceId))
      .first();
    if (device === null || device.revokedAt !== undefined) throw new Error("device has been revoked");
    if (plan.status !== "queued") return { claim: false, plan };
    if (plan.expiresAt <= Date.now()) {
      await ctx.db.patch(plan._id, { status: "failed", errorCode: "expired", updatedAt: Date.now() });
      return { claim: false, plan: { ...plan, status: "failed", errorCode: "expired" } };
    }
    const cancellationGeneration = plan.cancellationGeneration + 1;
    const updatedAt = Date.now();
    await ctx.db.patch(plan._id, {
      status: "planning",
      cancellationGeneration,
      errorCode: undefined,
      updatedAt,
    });
    return { claim: true, plan: { ...plan, status: "planning", cancellationGeneration, updatedAt } };
  },
});

export const savePlan = internalMutationGeneric({
  args: {
    planId: v.id("actionPlans"),
    cancellationGeneration: v.number(),
    explanation: v.string(),
    actionsJson: v.string(),
    capabilities: v.array(v.string()),
    fingerprint: v.string(),
    clarificationNeeded: v.boolean(),
  },
  handler: async (ctx, args) => {
    const plan = await ctx.db.get(args.planId);
    if (
      plan === null ||
      plan.status !== "planning" ||
      plan.cancellationGeneration !== args.cancellationGeneration
    ) {
      if (plan?.status === "cancelled") throw new Error("action plan was cancelled");
      throw new Error("action plan claim is stale");
    }
    const device = await ctx.db
      .query("devices")
      .withIndex("by_owner_device", (q) => q.eq("ownerKey", plan.ownerKey))
      .filter((q) => q.eq(q.field("deviceId"), plan.deviceId))
      .first();
    if (device === null || device.revokedAt !== undefined) throw new Error("device has been revoked");
    let actions: unknown;
    try {
      actions = JSON.parse(args.actionsJson) as unknown;
    } catch {
      throw new Error("planner action payload is invalid JSON");
    }
    const rawActions = Array.isArray(actions)
      ? actions.map((action) => {
          if (!isRecord(action)) return action;
          return {
            kind: action.kind,
            ...(action.targetBundleIdentifier === undefined
              ? {}
              : { targetBundleIdentifier: action.targetBundleIdentifier }),
            parameters: action.parameters,
            ...(action.visualTarget === undefined ? {} : { visualTarget: action.visualTarget }),
          };
        })
      : actions;
    const normalized = normalizeModelPlan({
      actions: rawActions,
      explanation: args.explanation,
      clarificationNeeded: args.clarificationNeeded,
    });
    if (normalized.fingerprint !== args.fingerprint) throw new Error("planner fingerprint mismatch");
    await ctx.db.patch(args.planId, {
      status: "awaiting_approval",
      explanation: normalized.explanation,
      actionsJson: JSON.stringify(normalized.actions),
      capabilitiesJson: JSON.stringify(normalized.capabilities),
      planFingerprint: normalized.fingerprint,
      errorCode: normalized.clarificationNeeded ? "clarification_required" : undefined,
      updatedAt: Date.now(),
    });
    return null;
  },
});

export const markPlan = internalMutationGeneric({
  args: {
    planId: v.id("actionPlans"),
    cancellationGeneration: v.number(),
    status: v.union(
      v.literal("queued"),
      v.literal("planning"),
      v.literal("awaiting_approval"),
      v.literal("approved"),
      v.literal("executing"),
      v.literal("succeeded"),
      v.literal("failed"),
      v.literal("cancelled"),
      v.literal("uncertain"),
    ),
    errorCode: v.optional(v.string()),
  },
  handler: async (ctx, args) => {
    const plan = await ctx.db.get(args.planId);
    if (
      plan === null ||
      plan.status !== "planning" ||
      plan.cancellationGeneration !== args.cancellationGeneration
    ) return null;
    await ctx.db.patch(args.planId, {
      status: args.status,
      ...(args.errorCode === undefined ? {} : { errorCode: args.errorCode }),
      updatedAt: Date.now(),
    });
    return null;
  },
});

export const getPlanInternal = internalQueryGeneric({
  args: { planId: v.id("actionPlans") },
  handler: async (ctx, args) => ctx.db.get(args.planId),
});
