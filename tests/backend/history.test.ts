import { expect, it } from "vitest";
import { convexTest } from "convex-test";
import { makeFunctionReference } from "convex/server";
import schema from "../../convex/schema";
// Test-only root marker; real Convex codegen requires a configured deployment.
const modules = { ...import.meta.glob("../../convex/**/*.ts"), "../../convex/_generated/test-root.ts": async () => ({}) };
const recent = makeFunctionReference<
  "query",
  Record<string, never>,
  Array<{ id: string; title: string; status: string }>
>("history:recent");
it("only returns the signed-in owner history and denies anonymous access", async () => {
  const t = convexTest(schema, modules);
  for (const owner of ["a", "b"]) {
    const identity = t.withIdentity({
      subject: owner,
      issuer: "https://test",
      tokenIdentifier: owner,
    });
    await identity.run(async (ctx) => {
      await ctx.db.insert("workflowRuns", {
        ownerKey: owner,
        deviceId: "device-test",
        kind: "research",
        query: owner + " private question",
        status: "queued",
        cancellationGeneration: 0,
        createdAt: 1,
        updatedAt: 1,
      });
    });
  }
  const ownerA = t.withIdentity({
    subject: "a",
    issuer: "https://test",
    tokenIdentifier: "a",
  });
  const results = await ownerA.query(recent, {});
  expect(results.map((run) => run.title)).toEqual(["a private question"]);
  await expect(t.query(recent, {})).rejects.toThrow("Unauthenticated");
});
