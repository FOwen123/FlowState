import { queryGeneric } from "convex/server";
import { requireIdentity } from "./lib/identity";

export const recent = queryGeneric({
  args: {},
  handler: async (ctx) => {
    const identity = await requireIdentity(ctx);
    const runs = await ctx.db
      .query("workflowRuns")
      .withIndex("by_owner", (q) => q.eq("ownerKey", identity.tokenIdentifier))
      .order("desc")
      .take(20);
    return runs.map((run) => ({
      id: String(run._id),
      title: String(run.previewTitle ?? run.query),
      status: String(run.status),
    }));
  },
});
