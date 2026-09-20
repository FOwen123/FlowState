import { internalMutationGeneric, queryGeneric } from "convex/server";
import { v } from "convex/values";

import { requireIdentity } from "./lib/identity";

type UsageKind = "research" | "planning" | "mail";

function dailyPeriod(timestamp = Date.now()): string {
  return new Date(timestamp).toISOString().slice(0, 10);
}

function limitFromEnv(name: string, fallback: number): number {
  const value = Number(process.env[name] ?? fallback);
  if (!Number.isInteger(value) || value < 1 || value > 100_000) return fallback;
  return value;
}

export function usageLimit(kind: UsageKind): number {
  if (kind === "research") return limitFromEnv("FLOWSTATE_DAILY_RESEARCH_LIMIT", 100);
  if (kind === "planning") return limitFromEnv("FLOWSTATE_DAILY_PLANNING_LIMIT", 100);
  return limitFromEnv("FLOWSTATE_DAILY_MAIL_LIMIT", 20);
}

export const get = queryGeneric({
  args: {},
  handler: async (ctx) => {
    const identity = await requireIdentity(ctx);
    const period = dailyPeriod();
    const row = await ctx.db
      .query("usageCounters")
      .withIndex("by_owner_period", (q) => q.eq("ownerKey", identity.tokenIdentifier))
      .filter((q) => q.eq(q.field("period"), period))
      .first();
    return {
      period,
      researchCount: row?.researchCount ?? 0,
      planningCount: row?.planningCount ?? 0,
      mailCount: row?.mailCount ?? 0,
      limits: {
        research: usageLimit("research"),
        planning: usageLimit("planning"),
        mail: usageLimit("mail"),
      },
    };
  },
});

export const consume = internalMutationGeneric({
  args: {
    ownerKey: v.string(),
    kind: v.union(v.literal("research"), v.literal("planning"), v.literal("mail")),
    providerBytes: v.optional(v.number()),
  },
  handler: async (ctx, args) => {
    const period = dailyPeriod();
    const existing = await ctx.db
      .query("usageCounters")
      .withIndex("by_owner_period", (q) => q.eq("ownerKey", args.ownerKey))
      .filter((q) => q.eq(q.field("period"), period))
      .first();
    const researchCount = (existing?.researchCount ?? 0) + (args.kind === "research" ? 1 : 0);
    const planningCount = (existing?.planningCount ?? 0) + (args.kind === "planning" ? 1 : 0);
    const mailCount = (existing?.mailCount ?? 0) + (args.kind === "mail" ? 1 : 0);
    const count = args.kind === "research" ? researchCount : args.kind === "planning" ? planningCount : mailCount;
    if (count > usageLimit(args.kind)) {
      throw new Error(`${args.kind} daily usage limit reached`);
    }
    const providerBytes = existing?.providerBytes ?? 0;
    const addedBytes = args.providerBytes ?? 0;
    if (!Number.isInteger(addedBytes) || addedBytes < 0 || addedBytes > 5_000_000) {
      throw new Error("providerBytes must be between 0 and 5000000");
    }
    const updatedAt = Date.now();
    if (existing === null) {
      await ctx.db.insert("usageCounters", {
        ownerKey: args.ownerKey,
        period,
        researchCount,
        planningCount,
        mailCount,
        providerBytes: addedBytes,
        updatedAt,
      });
    } else {
      await ctx.db.patch(existing._id, {
        researchCount,
        planningCount,
        mailCount,
        providerBytes: providerBytes + addedBytes,
        updatedAt,
      });
    }
    return { period, count, limit: usageLimit(args.kind) };
  },
});
