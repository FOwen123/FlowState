import { httpRouter, httpActionGeneric, makeFunctionReference, FunctionReference } from "convex/server";
import { Webhook } from "svix";
import { isRecord } from "./lib/http";

const saveEvent = makeFunctionReference<"mutation", {eventId:string; eventType:string; inboxId:string; messageId:string; threadId?:string}, null>("deliveries:recordEvent") as unknown as FunctionReference<"mutation", "internal", {eventId:string; eventType:string; inboxId:string; messageId:string; threadId?:string}, null>;
const router = httpRouter();
router.route({path:"/agentmail/webhook", method:"POST", handler:httpActionGeneric(async (ctx, request) => {
  const secret = process.env.AGENTMAIL_WEBHOOK_SECRET;
  if (!secret) return new Response("Webhook is not configured", {status:503});
  // Bound the raw body before signature verification. Never persist message content.
  const reader = request.body?.getReader();
  if (!reader) return new Response("Missing body", {status:400});
  let size = 0;
  const chunks: Uint8Array[] = [];
  while (true) {
    const {done,value} = await reader.read();
    if (done) break;
    size += value.length;
    if (size > 262144) { await reader.cancel(); return new Response("Payload too large", {status:413}); }
    chunks.push(value);
  }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk,offset); offset += chunk.length; }
  let payload: unknown;
  try { const raw = new TextDecoder().decode(bytes); new Webhook(secret).verify(raw, Object.fromEntries(request.headers)); payload = JSON.parse(raw) as unknown; }
  catch { return new Response("Invalid signature", {status:400}); }
  const eventParts: Record<string,string> = {"message.sent":"send","message.delivered":"delivery","message.bounced":"bounce","message.complained":"complaint","message.rejected":"reject"};
  if (!isRecord(payload) || typeof payload.event_type !== "string") return new Response("Invalid event",{status:400});
  const part = eventParts[payload.event_type];
  if (!part) return new Response("Ignored",{status:200});
  const detail = payload[part];
  if (!isRecord(detail) || typeof payload.event_id !== "string" || payload.event_id.length > 256 ||
      typeof detail.inbox_id !== "string" || detail.inbox_id !== process.env.FLOWSTATE_AGENTMAIL_INBOX_ID ||
      typeof detail.message_id !== "string" || detail.message_id.length > 998 ||
      (detail.thread_id !== undefined && (typeof detail.thread_id !== "string" || detail.thread_id.length > 256))) {
    return new Response("Invalid event", {status:400});
  }
  await ctx.runMutation(saveEvent, {eventId:payload.event_id,eventType:payload.event_type,inboxId:detail.inbox_id,messageId:detail.message_id,...(typeof detail.thread_id === "string" ? {threadId:detail.thread_id} : {})});
  return new Response("OK",{status:200});
})});
export default router;
