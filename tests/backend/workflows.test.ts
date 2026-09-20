import { afterEach, describe, expect, it, vi } from "vitest";
import { anyApi } from "convex/server";
import { convexTest } from "convex-test";

import schema from "../../convex/schema";

const modules = {
  ...import.meta.glob("../../convex/**/*.ts"),
  // convex-test needs the generated-root marker; real codegen replaces this
  // anchor after a Convex deployment is configured.
  "../../convex/_generated/test-root.ts": async () => ({}),
};

const api = anyApi as typeof anyApi;
const ownerA = { tokenIdentifier: "clerk|owner-a", subject: "owner-a" };
const ownerB = { tokenIdentifier: "clerk|owner-b", subject: "owner-b" };

afterEach(() => {
  vi.unstubAllGlobals();
  delete process.env.FLOWSTATE_ALLOWED_TEST_RECIPIENTS;
  delete process.env.FLOWSTATE_AGENTMAIL_INBOX_ID;
  delete process.env.AGENTMAIL_API_KEY;
  delete process.env.FIRECRAWL_API_KEY;
  delete process.env.TYPESAFE_API_KEY;
  delete process.env.OPENAI_API_KEY;
  delete process.env.FLOWSTATE_JEV_MODEL;
  delete process.env.FLOWSTATE_PLANNER_MODEL;
});

async function createReadyRun() {
  const t = convexTest(schema, modules);
  const user = t.withIdentity(ownerA);
  await user.mutation(api.workflows.registerDevice, { deviceId: "device-owner-a" });
  const { runId } = await user.mutation(api.workflows.createResearchRun, {
    deviceId: "device-owner-a",
    query: "Summarize this article with sources",
    sourceUrl: "https://example.com/article",
  });
  await t.run(async (ctx) => {
    await ctx.db.patch(runId, {
      status: "awaiting_approval",
      previewTitle: "Example article",
      previewBody: "A reviewed public article note.",
      updatedAt: Date.now(),
    });
  });
  return { t, user, runId };
}

describe("authenticated workflow state", () => {
  it("scopes devices and runs to the authenticated owner", async () => {
    const t = convexTest(schema, modules);
    const userA = t.withIdentity(ownerA);
    const userB = t.withIdentity(ownerB);
    await userA.mutation(api.workflows.registerDevice, { deviceId: "device-shared" });
    await userB.mutation(api.workflows.registerDevice, { deviceId: "device-shared" });
    const { runId } = await userA.mutation(api.workflows.createResearchRun, {
      deviceId: "device-shared",
      query: "Summarize a public article",
    });

    await expect(
      userB.query(api.workflows.getResearchRun, { runId }),
    ).rejects.toThrow("not found");
    await expect(
      userB.mutation(api.workflows.createResearchRun, {
        deviceId: "device-shared",
        query: "This must not access owner A",
      }),
    ).resolves.toMatchObject({ status: "queued" });
  });

  it("requires approval content to match the persisted preview", async () => {
    process.env.FLOWSTATE_ALLOWED_TEST_RECIPIENTS = "owner@example.com";
    const { user, runId } = await createReadyRun();

    await expect(
      user.mutation(api.workflows.approveResearchEmail, {
        runId,
        recipient: "owner@example.com",
        subject: "Changed title",
        body: "A reviewed public article note.",
      }),
    ).rejects.toThrow("match the current research preview");

    await expect(
      user.mutation(api.workflows.approveResearchEmail, {
        runId,
        recipient: "owner@example.com",
        subject: "Example article",
        body: "A reviewed public article note.",
      }),
    ).resolves.toMatchObject({ status: "approved" });
    await expect(
      user.mutation(api.workflows.approveResearchEmail, {
        runId,
        recipient: "owner@example.com",
        subject: "Example article",
        body: "A reviewed public article note.",
      }),
    ).rejects.toThrow("not awaiting email approval");
  });
});

describe("delivery recovery", () => {
  it("runs public research through Firecrawl, Jev, OpenAI, and AgentMail", async () => {
    process.env.FLOWSTATE_ALLOWED_TEST_RECIPIENTS = "owner@example.com";
    process.env.FLOWSTATE_AGENTMAIL_INBOX_ID = "flowstate@example.com";
    process.env.AGENTMAIL_API_KEY = "am-test";
    process.env.FIRECRAWL_API_KEY = "fc-test";
    process.env.TYPESAFE_API_KEY = "ts-test";
    process.env.OPENAI_API_KEY = "sk-test";
    process.env.FLOWSTATE_JEV_MODEL = "jev-latest";
    process.env.FLOWSTATE_PLANNER_MODEL = "gpt-5-mini";
    const t = convexTest(schema, modules);
    const user = t.withIdentity(ownerA);
    await user.mutation(api.workflows.registerDevice, { deviceId: "device-research" });
    const { runId } = await user.mutation(api.workflows.createResearchRun, {
      deviceId: "device-research",
      query: "Summarize this article with sources",
      sourceUrl: "https://example.com/article",
    });
    const fetch = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input);
      if (url.endsWith("/scrape")) {
        return new Response(
          JSON.stringify({
            success: true,
            data: {
              markdown: "# Example\nThis is public article content.",
              metadata: { title: "Example article" },
            },
          }),
          { status: 200 },
        );
      }
      if (url.endsWith("/systemone")) {
        return new Response(
          JSON.stringify({
            model: "jev-1.13.0",
            answers: {
              target: {
                type: "choice",
                choice: "source-0",
                confidence: 0.98,
              },
            },
          }),
          { status: 200 },
        );
      }
      if (url.endsWith("/responses")) {
        return new Response(
          JSON.stringify({ id: "resp_123", output_text: "A sourced research note." }),
          { status: 200 },
        );
      }
      if (url.includes("/messages/send")) {
        expect(init?.headers).toMatchObject({ "Idempotency-Key": expect.any(String) });
        return new Response(
          JSON.stringify({ message_id: "msg_123", thread_id: "thread_123" }),
          { status: 200 },
        );
      }
      throw new Error(`unexpected provider URL: ${url}`);
    });
    vi.stubGlobal("fetch", fetch);

    await expect(user.action(api.workflows.runResearch, { runId })).resolves.toMatchObject({
      status: "ready",
      title: "Example article",
    });
    const preview = await user.query(api.workflows.getResearchRun, { runId });
    expect(preview.note).toMatchObject({ title: "Example article", body: "A sourced research note." });
    const { approvalId } = await user.mutation(api.workflows.approveResearchEmail, {
      runId,
      recipient: "owner@example.com",
      subject: preview.note?.title ?? "",
      body: preview.note?.body ?? "",
    });
    const approved = await user.query(api.workflows.getResearchRun, { runId });
    expect(approved.approval).toMatchObject({ id: String(approvalId), status: "approved" });
    const concurrentSends = await Promise.allSettled([
      user.action(api.workflows.sendApprovedResearchEmail, { runId, approvalId }),
      user.action(api.workflows.sendApprovedResearchEmail, { runId, approvalId }),
    ]);
    expect(concurrentSends.filter((result) => result.status === "fulfilled")).toHaveLength(1);
    expect(
      concurrentSends.find((result) => result.status === "fulfilled"),
    ).toMatchObject({ status: "fulfilled", value: { status: "sent", messageId: "msg_123" } });
    expect(fetch).toHaveBeenCalledTimes(4);
    await expect(
      user.action(api.workflows.sendApprovedResearchEmail, { runId, approvalId }),
    ).resolves.toMatchObject({ status: "sent", messageId: "msg_123" });
    expect(fetch).toHaveBeenCalledTimes(4);
  });

  it("marks a network failure uncertain and blocks a second send", async () => {
    process.env.FLOWSTATE_ALLOWED_TEST_RECIPIENTS = "owner@example.com";
    process.env.FLOWSTATE_AGENTMAIL_INBOX_ID = "flowstate@example.com";
    process.env.AGENTMAIL_API_KEY = "am-test";
    const { t, user, runId } = await createReadyRun();
    const { approvalId } = await user.mutation(api.workflows.approveResearchEmail, {
      runId,
      recipient: "owner@example.com",
      subject: "Example article",
      body: "A reviewed public article note.",
    });
    const fetch = vi.fn(async () => {
      throw new TypeError("network disconnected");
    });
    vi.stubGlobal("fetch", fetch);

    await expect(
      user.action(api.workflows.sendApprovedResearchEmail, { runId, approvalId }),
    ).rejects.toThrow("request failed");
    expect(fetch).toHaveBeenCalledTimes(1);
    await expect(
      user.action(api.workflows.sendApprovedResearchEmail, { runId, approvalId }),
    ).rejects.toThrow("pending or uncertain");
    expect(fetch).toHaveBeenCalledTimes(1);

    const view = await user.query(api.workflows.getResearchRun, { runId });
    expect(view.runStatus).toBe("uncertain");
    expect(view.approval?.status).toBe("approved");
    await expect(t.run(async (ctx) => ctx.db.query("deliveryAttempts").collect())).resolves.toHaveLength(1);
  });

  it("treats an HTTP provider failure as uncertain after the send attempt", async () => {
    process.env.FLOWSTATE_ALLOWED_TEST_RECIPIENTS = "owner@example.com";
    process.env.FLOWSTATE_AGENTMAIL_INBOX_ID = "flowstate@example.com";
    process.env.AGENTMAIL_API_KEY = "am-test";
    const { user, runId } = await createReadyRun();
    const { approvalId } = await user.mutation(api.workflows.approveResearchEmail, {
      runId,
      recipient: "owner@example.com",
      subject: "Example article",
      body: "A reviewed public article note.",
    });
    const fetch = vi.fn(async () => new Response(JSON.stringify({ code: "upstream_error" }), { status: 500 }));
    vi.stubGlobal("fetch", fetch);

    await expect(
      user.action(api.workflows.sendApprovedResearchEmail, { runId, approvalId }),
    ).rejects.toThrow("request failed");
    expect(fetch).toHaveBeenCalledTimes(1);
    await expect(
      user.action(api.workflows.sendApprovedResearchEmail, { runId, approvalId }),
    ).rejects.toThrow("pending or uncertain");
    expect(fetch).toHaveBeenCalledTimes(1);
    await expect(user.query(api.workflows.getResearchRun, { runId })).resolves.toMatchObject({
      runStatus: "uncertain",
    });
  });

  it("does not save a late preview after an in-flight research run is cancelled", async () => {
    process.env.FIRECRAWL_API_KEY = "fc-test";
    process.env.TYPESAFE_API_KEY = "ts-test";
    process.env.OPENAI_API_KEY = "sk-test";
    process.env.FLOWSTATE_JEV_MODEL = "jev-1.13.0";
    process.env.FLOWSTATE_PLANNER_MODEL = "gpt-5-mini";
    const t = convexTest(schema, modules);
    const user = t.withIdentity(ownerA);
    await user.mutation(api.workflows.registerDevice, { deviceId: "device-cancel" });
    const { runId } = await user.mutation(api.workflows.createResearchRun, {
      deviceId: "device-cancel",
      query: "Summarize this article with sources",
      sourceUrl: "https://example.com/article",
    });

    let releaseScrape: (response: Response) => void = () => {
      throw new Error("scrape response was not initialized");
    };
    const scrapeStarted = new Promise<void>((resolve) => {
      const scrapeResponse = new Promise<Response>((resolveResponse) => {
        releaseScrape = resolveResponse;
      });
      vi.stubGlobal(
        "fetch",
        vi.fn(async (input: RequestInfo | URL) => {
          const url = String(input);
          if (url.endsWith("/scrape")) {
            resolve();
            return scrapeResponse;
          }
          if (url.endsWith("/systemone")) {
            return new Response(
              JSON.stringify({
                model: "jev-1.13.0",
                answers: {
                  target: { type: "choice", choice: "source-0", confidence: 0.98 },
                },
              }),
              { status: 200 },
            );
          }
          if (url.endsWith("/responses")) {
            return new Response(
              JSON.stringify({ id: "resp_cancel", output_text: "A late note." }),
              { status: 200 },
            );
          }
          throw new Error(`unexpected provider URL: ${url}`);
        }),
      );
    });

    const running = user.action(api.workflows.runResearch, { runId });
    await scrapeStarted;
    await expect(user.mutation(api.workflows.cancelResearch, { runId })).resolves.toMatchObject({
      status: "cancelled",
    });
    releaseScrape(
      new Response(
        JSON.stringify({
          success: true,
          data: {
            markdown: "# Example\nThis is public article content.",
            metadata: { title: "Example article" },
          },
        }),
        { status: 200 },
      ),
    );
    await expect(running).rejects.toThrow("cancelled");
    await expect(user.query(api.workflows.getResearchRun, { runId })).resolves.toMatchObject({
      runStatus: "cancelled",
      note: null,
      sources: [],
    });
  });
});
