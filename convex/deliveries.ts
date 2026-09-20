import { internalMutationGeneric, queryGeneric } from "convex/server";
import { v } from "convex/values";
import { requireIdentity } from "./lib/identity";

export const recordEvent = internalMutationGeneric({
  args:{eventId:v.string(),eventType:v.string(),inboxId:v.string(),messageId:v.string(),threadId:v.optional(v.string())},
  handler:async(ctx,args)=>{
    if (await ctx.db.query("agentMailEvents").withIndex("by_event_id",q=>q.eq("eventId",args.eventId)).first()) return null;
    await ctx.db.insert("agentMailEvents",{...args,receivedAt:Date.now(),payloadJson:"{}"});
    return null;
  }
});
// An accepted API send is not proof of delivery. Show signed delivery events separately.
export const forRun = queryGeneric({
  args:{runId:v.id("workflowRuns")},
  handler:async(ctx,args)=>{
    const identity = await requireIdentity(ctx);
    const run = await ctx.db.get(args.runId);
    if (!run || run.ownerKey !== identity.tokenIdentifier) throw new Error("research run not found");
    const attempts = await ctx.db.query("deliveryAttempts").withIndex("by_run",q=>q.eq("runId",args.runId)).collect();
    const receipts: Array<{eventType:string;receivedAt:number}> = [];
    for (const attempt of attempts) {
      if (!attempt.externalId) continue;
      const approval = await ctx.db.get(attempt.approvalId);
      const events = await ctx.db.query("agentMailEvents").withIndex("by_message_id",q=>q.eq("messageId",attempt.externalId)).collect();
      for (const event of events) if (event.inboxId === approval?.sender) receipts.push({eventType:event.eventType,receivedAt:event.receivedAt});
    }
    return receipts.sort((a,b)=>a.receivedAt-b.receivedAt);
  }
});
