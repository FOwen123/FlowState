import { execFileSync } from "node:child_process";
import { describe, expect, it } from "vitest";

describe("Mac Control Jev evaluation report", () => {
  it("reports every shipped question and leaves the live comparison gate open", () => {
    const report = JSON.parse(
      execFileSync(
        process.execPath,
        ["scripts/evaluate-intent.ts", "--mode", "deterministic"],
        { encoding: "utf8" },
      ),
    ) as {
      versions: { promptVersion: string };
      metrics: Record<
        string,
        {
          questionMetrics: Record<string, { samples: number; latencyMs: unknown }>;
          comparisonGate: { status: string; accepted: boolean };
        }
      >;
    };

    expect(report.versions.promptVersion).toBe("intent-questions-v3");
    for (const metrics of Object.values(report.metrics)) {
      expect(Object.keys(metrics.questionMetrics)).toEqual([
        "intent",
        "app",
        "action",
        "tool",
        "target",
        "requiredSlots",
        "risk",
        "clarification",
      ]);
      for (const question of Object.values(metrics.questionMetrics)) {
        expect(question.samples).toBeGreaterThan(0);
        expect(question.latencyMs).toMatchObject({
          p50: null,
          p95: null,
        });
      }
      expect(metrics.comparisonGate).toEqual({
        status: "not_run",
        accepted: false,
        reason: "live_comparison_required",
      });
    }
  });
});
