import { afterEach, expect, it, vi } from "vitest";
import { Webhook } from "svix";
import { anyApi } from "convex/server";
import { convexTest } from "convex-test";
import schema from "../../convex/schema";
const modules = { ...import.meta.glob("../../convex/**/*.ts"), "../../convex/_generated/test-root.ts": async () => ({}) };
const secret = "whsec_" + Buffer.from("synthetic-webhook-secret-32-bytes!").toString("base64");
afterEach(() => vi.unstubAllEnvs());
it("verifies signatures, rejects tampering and stale delivery, and deduplicates redacted metadata", async () => {
  vi.stubEnv("AGENTMAIL_WEBHOOK_SECRET", secret);
  vi.stubEnv("FLOWSTATE_AGENTMAIL_INBOX_ID", "assistant@example.test");
  const t = convexTest(schema, modules);
  const payload = JSON.stringify({ event_id: "evt_delivery", event_type: "message.delivered", delivery: { inbox_id: "assistant@example.test", message_id: "<test@example.test>", thread_id: "thread-test", recipients: ["private@example.test"] } });
  const stamp = new Date();
  const headers = { "svix-id": "msg_webhook", "svix-timestamp": String(Math.floor(stamp.getTime()/1000)), "svix-signature": new Webhook(secret).sign("msg_webhook", stamp, payload) };
  expect((await t.fetch("/agentmail/webhook", {method:"POST", headers, body:payload + " "})).status).toBe(400);
  for (let i = 0; i < 2; i++) { const response = await t.fetch("/agentmail/webhook", {method:"POST", headers, body:payload}); expect(response.status, await response.text()).toBe(200); }
  const rows = await t.run(ctx => ctx.db.query("agentMailEvents").collect());
  expect(rows).toHaveLength(1);
  expect(JSON.stringify(rows)).not.toContain("private@example.test");
  const old = new Date(Date.now() - 600_000);
  expect((await t.fetch("/agentmail/webhook", {method:"POST", headers:{...headers, "svix-timestamp":String(Math.floor(old.getTime()/1000)), "svix-signature":new Webhook(secret).sign("msg_webhook",old,payload)},body:payload})).status).toBe(400);
});
it("delivery receipts require ownership of the originating run", async () => {
  const t = convexTest(schema, modules);
  const owner = t.withIdentity({subject:"receipt-owner", tokenIdentifier:"clerk|receipt-owner"});
  await owner.mutation(anyApi.workflows.registerDevice,{deviceId:"receipt-device"});
  const run = await owner.mutation(anyApi.workflows.createResearchRun,{deviceId:"receipt-device", query:"test receipt ownership"});
  await expect(owner.query(anyApi.deliveries.forRun,{runId:run.runId})).resolves.toEqual([]);
  await expect(t.withIdentity({subject:"other",tokenIdentifier:"clerk|other"}).query(anyApi.deliveries.forRun,{runId:run.runId})).rejects.toThrow("not found");
});
