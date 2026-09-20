import { describe, expect, it, vi } from "vitest";
import { createFirecrawlClient } from "../../convex/lib/firecrawl";
import { createTypeSafeClient } from "../../convex/lib/typesafe";
import { createOpenAIClient } from "../../convex/lib/openai";
import { requestJson } from "../../convex/lib/http";

describe("provider trust boundaries", () => {
  it.each([
    "http://localhost/",
    "https://127.0.0.1/",
    "https://[::1]/",
    "https://192.168.1.1/",
    "https://user:secret@example.com/",
    "https://internal.local/",
  ])("refuses nonpublic source %s before transmission", async (url) => {
    const fetcher = vi.fn<typeof fetch>();
    await expect(
      createFirecrawlClient({ apiKey: "test", fetch: fetcher }).scrape(url),
    ).rejects.toThrow();
    expect(fetcher).not.toHaveBeenCalled();
  });
  it("rejects a model-selected candidate outside the registered set", async () => {
    const fetcher = vi
      .fn<typeof fetch>()
      .mockResolvedValue(
        new Response(
          JSON.stringify({
            model: "jev-1.13.0",
            answers: { target: { choice: "unknown", confidence: 0.9 } },
          }),
        ),
      );
    await expect(
      createTypeSafeClient({
        apiKey: "test",
        model: "jev-1.13.0",
        fetch: fetcher,
      }).chooseCandidate({
        state: "request",
        candidates: { known: "Known option" },
      }),
    ).rejects.toThrow("candidate");
  });
  it("rejects invalid confidence instead of trusting it", async () => {
    const fetcher = vi
      .fn<typeof fetch>()
      .mockResolvedValue(
        new Response(
          JSON.stringify({
            model: "jev-1.13.0",
            answers: { target: { choice: "known", confidence: 2 } },
          }),
        ),
      );
    await expect(
      createTypeSafeClient({
        apiKey: "test",
        model: "jev-1.13.0",
        fetch: fetcher,
      }).chooseCandidate({
        state: "request",
        candidates: { known: "Known option" },
      }),
    ).rejects.toThrow("confidence");
  });
  it("requires an explicit model selection", () => {
    expect(() => createTypeSafeClient({ apiKey: "test" })).toThrow("model");
    expect(() => createOpenAIClient({ apiKey: "test" })).toThrow("model");
  });
  it("bounds provider response bytes and supplies a request timeout", async () => {
    const fetcher = vi
      .fn<typeof fetch>()
      .mockResolvedValue(new Response("x".repeat(1_048_577)));
    await expect(
      requestJson("test", fetcher, "https://example.com", {}),
    ).rejects.toThrow("limit");
    expect(fetcher.mock.calls[0]?.[1]?.signal).toBeInstanceOf(AbortSignal);
  });
  it("does not retain sensitive provider error bodies", async () => {
    const fetcher = vi
      .fn<typeof fetch>()
      .mockResolvedValue(
        new Response(JSON.stringify({ echo: "secret-body" }), { status: 400 }),
      );
    try {
      await requestJson("test", fetcher, "https://example.com", {});
      throw new Error("expected rejection");
    } catch (error) {
      expect(JSON.stringify(error)).not.toContain("secret-body");
    }
  });
});
