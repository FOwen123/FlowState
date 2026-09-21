import { mutationGeneric } from "convex/server";
import { v } from "convex/values";

import { requireIdentity } from "./lib/identity";
import { containsLegacyInsertTextJson } from "./lib/action_plan";
import { migrateLegacyPreferenceValue } from "./lib/locale_migration";

export const migrateLegacyLocales = mutationGeneric({
  args: { maxRecords: v.optional(v.number()) },
  handler: async (ctx, args) => {
    const identity = await requireIdentity(ctx);
    const maxRecords = args.maxRecords ?? 1_000;
    if (!Number.isInteger(maxRecords) || maxRecords < 1 || maxRecords > 1_000) {
      throw new Error("maxRecords must be an integer from 1 to 1000");
    }
    const timestamp = Date.now();
    let actionPlans = 0;
    const plans = await ctx.db
      .query("actionPlans")
      .withIndex("by_owner", (q) => q.eq("ownerKey", identity.tokenIdentifier))
      .collect();
    for (const plan of plans) {
      if (actionPlans >= maxRecords || plan.locale !== "zh-Hant") continue;
      await ctx.db.patch(plan._id, { locale: "en", updatedAt: timestamp });
      actionPlans += 1;
    }
    let preferences = 0;
    const rows = await ctx.db
      .query("preferences")
      .withIndex("by_owner_key", (q) => q.eq("ownerKey", identity.tokenIdentifier))
      .collect();
    for (const row of rows) {
      if (preferences >= maxRecords) break;
      const valueJson = migrateLegacyPreferenceValue(row.valueJson);
      if (valueJson === undefined) continue;
      await ctx.db.patch(row._id, { valueJson, updatedAt: timestamp });
      preferences += 1;
    }
    return { actionPlans, preferences };
  },
});

export const invalidateLegacyInsertTextPlans = mutationGeneric({
  args: { maxRecords: v.optional(v.number()) },
  handler: async (ctx, args) => {
    const identity = await requireIdentity(ctx);
    const maxRecords = args.maxRecords ?? 1_000;
    if (!Number.isInteger(maxRecords) || maxRecords < 1 || maxRecords > 1_000) {
      throw new Error("maxRecords must be an integer from 1 to 1000");
    }
    const plans = await ctx.db
      .query("actionPlans")
      .withIndex("by_owner", (q) => q.eq("ownerKey", identity.tokenIdentifier))
      .collect();
    let invalidated = 0;
    const timestamp = Date.now();
    for (const plan of plans) {
      if (invalidated >= maxRecords || !containsLegacyInsertTextJson(plan.actionsJson)) {
        continue;
      }
      await ctx.db.patch(plan._id, {
        status: "failed",
        actionsJson: undefined,
        capabilitiesJson: undefined,
        planFingerprint: undefined,
        cancellationGeneration: plan.cancellationGeneration + 1,
        errorCode: "legacy_insertText_invalidated",
        updatedAt: timestamp,
      });
      invalidated += 1;
    }
    return { invalidated };
  },
});
