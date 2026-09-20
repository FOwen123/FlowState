import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const fixture = JSON.parse(
  readFileSync("tests/fixtures/intent/en.json", "utf8"),
) as {
  groups: Array<{
    id: string;
    scenarios: Array<{
      id: string;
      utterance: string;
      context: unknown;
      expected: unknown;
    }>;
  }>;
};
describe("intent evaluation corpus quality", () => {
  it("contains at least 300 distinct inputs across independent scenario families", () => {
    const scenarios = fixture.groups.flatMap((g) => g.scenarios);
    expect(scenarios.length).toBeGreaterThanOrEqual(300);
    expect(fixture.groups.length).toBeGreaterThanOrEqual(60);
    const inputs = scenarios.map((s) =>
      JSON.stringify([s.utterance, s.context]),
    );
    expect(new Set(inputs).size).toBe(inputs.length);
    expect(new Set(fixture.groups.map((g) => g.id)).size).toBe(
      fixture.groups.length,
    );
  });
});

it("never scores an action label as a correct intent", async () => {
  const { execFileSync } = await import("node:child_process");
  const { mkdtempSync, writeFileSync, rmSync } = await import("node:fs");
  const { tmpdir } = await import("node:os");
  const { join } = await import("node:path");
  const directory = mkdtempSync(join(tmpdir(), "flowstate-intent-score-"));
  try {
    const predictions: Record<string, unknown> = {};
    for (const group of fixture.groups)
      for (const scenario of group.scenarios) {
        const expected = scenario.expected as {
          intent: string;
          action?: string;
          target?: string;
        };
        if (expected.intent === "action" && expected.action)
          predictions[`${group.id}/${scenario.id}`] = {
            intent: expected.action,
            action: expected.action,
            target: expected.target,
          };
      }
    const path = join(directory, "predictions.json");
    writeFileSync(path, JSON.stringify(predictions));
    const report = JSON.parse(
      execFileSync(
        process.execPath,
        ["scripts/evaluate-intent.ts", "--predictions", path],
        { encoding: "utf8" },
      ),
    );
    for (const metrics of Object.values(report.metrics) as Array<{
      correct: number;
    }>)
      expect(metrics.correct).toBe(0);
  } finally {
    rmSync(directory, { recursive: true });
  }
});
