import { describe, expect, it } from "vitest";
import { checkEnvironment } from "../../scripts/check-env.mjs";
describe("environment checks", () => {
  it("reports missing names without leaking configured secrets", () => {
    const result = checkEnvironment(
      { OPENAI_API_KEY: "private-do-not-print" },
      "backend",
    );
    expect(result.missing).toContain("FIRECRAWL_API_KEY");
    expect(JSON.stringify(result)).not.toContain("private-do-not-print");
  });
  it("only needs public config for the web", () => {
    expect(
      checkEnvironment(
        {
          VITE_CONVEX_URL: "https://example.convex.cloud",
          VITE_CLERK_PUBLISHABLE_KEY: "pk_test_example",
        },
        "web",
      ).missing,
    ).toEqual([]);
  });
});
