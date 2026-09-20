import { describe, expect, it, vi } from "vitest";

import { createAgentMailClient } from "../../convex/lib/agentmail";
import { createFirecrawlClient } from "../../convex/lib/firecrawl";
import { createOpenAIClient } from "../../convex/lib/openai";
import { createTypeSafeClient } from "../../convex/lib/typesafe";

type RequestCall = {
  url: string;
  init: RequestInit;
};

function fakeFetch(
  responseBody: unknown,
  status = 200,
): {
  fetch: typeof fetch;
  calls: RequestCall[];
} {
  const calls: RequestCall[] = [];
  const fetch = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
    calls.push({
      url: String(input),
      init: init ?? {},
    });
    return new Response(JSON.stringify(responseBody), {
      status,
      headers: { "content-type": "application/json" },
    });
  }) as unknown as typeof globalThis.fetch;
  return { fetch, calls };
}

describe("Firecrawl adapter", () => {
  it("uses the documented v2 search request and returns web results", async () => {
    const fixture = fakeFetch({
      success: true,
      data: {
        web: [
          {
            url: "https://example.com/article",
            title: "Example",
            description: "A public article",
            markdown: "# Example",
          },
        ],
      },
    });
    const client = createFirecrawlClient({
      apiKey: "fc-test",
      fetch: fixture.fetch,
    });

    await expect(client.search("FlowState", 3)).resolves.toEqual([
      {
        url: "https://example.com/article",
        title: "Example",
        description: "A public article",
        markdown: "# Example",
      },
    ]);

    expect(fixture.calls).toHaveLength(1);
    expect(fixture.calls[0]?.url).toBe("https://api.firecrawl.dev/v2/search");
    expect(fixture.calls[0]?.init.headers).toMatchObject({
      Authorization: "Bearer fc-test",
      "Content-Type": "application/json",
    });
    expect(JSON.parse(String(fixture.calls[0]?.init.body))).toEqual({
      query: "FlowState",
      limit: 3,
      scrapeOptions: { formats: ["markdown"] },
    });
  });

  it("rejects a non-success response instead of returning untrusted data", async () => {
    const fixture = fakeFetch({ success: false, error: "rate limited" }, 429);
    const client = createFirecrawlClient({
      apiKey: "fc-test",
      fetch: fixture.fetch,
    });

    await expect(client.search("FlowState", 3)).rejects.toMatchObject({
      provider: "firecrawl",
      status: 429,
    });
  });
});

describe("AgentMail adapter", () => {
  it("sends through the documented endpoint with an idempotency key", async () => {
    const fixture = fakeFetch({ message_id: "msg_123", thread_id: "thr_123" });
    const client = createAgentMailClient({
      apiKey: "am-test",
      fetch: fixture.fetch,
    });

    await expect(
      client.send({
        inboxId: "flowstate@example.com",
        to: ["owner@example.com"],
        subject: "Research preview",
        text: "A preview",
        idempotencyKey: "run-123-email-1",
      }),
    ).resolves.toEqual({ messageId: "msg_123", threadId: "thr_123" });

    expect(fixture.calls[0]?.url).toBe(
      "https://api.agentmail.to/v0/inboxes/flowstate%40example.com/messages/send",
    );
    expect(fixture.calls[0]?.init.headers).toMatchObject({
      Authorization: "Bearer am-test",
      "Idempotency-Key": "run-123-email-1",
      "Content-Type": "application/json",
    });
    expect(JSON.parse(String(fixture.calls[0]?.init.body))).toEqual({
      to: ["owner@example.com"],
      subject: "Research preview",
      text: "A preview",
    });
  });

  it("requires a non-empty idempotency key", async () => {
    const fixture = fakeFetch({ message_id: "msg_123", thread_id: "thr_123" });
    const client = createAgentMailClient({
      apiKey: "am-test",
      fetch: fixture.fetch,
    });

    await expect(
      client.send({
        inboxId: "flowstate@example.com",
        to: ["owner@example.com"],
        subject: "Research preview",
        text: "A preview",
        idempotencyKey: "",
      }),
    ).rejects.toThrow("idempotency key");
    expect(fixture.calls).toHaveLength(0);
  });
});

describe("TypeSafe adapter", () => {
  it("posts a typed choice question to System One", async () => {
    const fixture = fakeFetch({
      model: "jev-1.13.0",
      answers: {
        target: {
          type: "choice",
          choice: "source-1",
          probabilities: { "source-1": 0.91, "source-2": 0.09 },
          confidence: 0.91,
        },
      },
      usage: { input_tokens: 20, output_tokens: 8 },
    });
    const client = createTypeSafeClient({
      apiKey: "ts-test",
      model: "jev-1.13.0",
      fetch: fixture.fetch,
    });

    await expect(
      client.systemOne({
        state: { query: "FlowState", candidates: ["source-1", "source-2"] },
        questions: {
          target: {
            type: "choice",
            instructions: "Which source best answers the query?",
            criteria: {
              "source-1": "Directly answers the query",
              "source-2": "Related",
            },
          },
        },
      }),
    ).resolves.toMatchObject({
      model: "jev-1.13.0",
      answers: { target: { choice: "source-1", confidence: 0.91 } },
    });
    expect(fixture.calls[0]?.url).toBe("https://api.typesafe.ai/v1/systemone");
    expect(fixture.calls[0]?.init.headers).toMatchObject({
      Authorization: "Bearer ts-test",
      "Content-Type": "application/json",
    });
    expect(JSON.parse(String(fixture.calls[0]?.init.body))).toMatchObject({
      model: "jev-1.13.0",
      state: { query: "FlowState", candidates: ["source-1", "source-2"] },
    });
  });
});

describe("OpenAI adapter", () => {
  it("uses the Responses API and does not retain research prompts by default", async () => {
    const fixture = fakeFetch({
      id: "resp_123",
      output_text: "A concise preview.",
      output: [],
    });
    const client = createOpenAIClient({
      apiKey: "sk-test",
      fetch: fixture.fetch,
      model: "gpt-5-mini",
    });

    await expect(
      client.createResponse({
        input: "Summarize these public sources.",
        instructions: "Return a concise factual note with source URLs.",
      }),
    ).resolves.toEqual({ id: "resp_123", outputText: "A concise preview." });
    expect(fixture.calls[0]?.url).toBe("https://api.openai.com/v1/responses");
    expect(fixture.calls[0]?.init.headers).toMatchObject({
      Authorization: "Bearer sk-test",
      "Content-Type": "application/json",
    });
    expect(JSON.parse(String(fixture.calls[0]?.init.body))).toEqual({
      model: "gpt-5-mini",
      input: "Summarize these public sources.",
      instructions: "Return a concise factual note with source URLs.",
      store: false,
    });
  });
});
