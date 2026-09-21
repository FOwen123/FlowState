import { createServer } from "node:http";
import { execFile, execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { promisify } from "node:util";
import { describe, expect, it } from "vitest";

const execFileAsync = promisify(execFile);

const fixture = JSON.parse(
  readFileSync("tests/fixtures/control-decisions/en.json", "utf8"),
) as {
  suites: Array<{
    id: string;
    stage: string;
    questions: Record<string, string[]>;
    groups: Array<{
      id: string;
      scenarios: Array<{ id: string; utterance: string }>;
    }>;
  }>;
};

describe("named Jev stage suites", () => {
  it("keeps five independently grouped stages with no repeated inputs", () => {
    expect(fixture.suites.map((suite) => suite.id)).toEqual([
      "missing-slots-risk",
      "plan-step-validation",
      "memory-ranking",
      "result-validation",
      "route-model-selection",
    ]);
    const inputs = fixture.suites.flatMap((suite) =>
      suite.groups.flatMap((group) =>
        group.scenarios.map((scenario) => `${suite.id}:${scenario.utterance}`),
      ),
    );
    expect(new Set(inputs).size).toBe(inputs.length);
    for (const suite of fixture.suites) {
      expect(suite.groups).toHaveLength(4);
      expect(Object.keys(suite.questions).length).toBeGreaterThan(0);
    }
  });

  it("reports every stage without claiming a live gate", () => {
    const report = JSON.parse(
      execFileSync(
        process.execPath,
        [
          "scripts/evaluate-intent.ts",
          "--mode",
          "deterministic",
          "--suite",
          "missing-slots-risk",
        ],
        { encoding: "utf8" },
      ),
    ) as {
      suite: string;
      metrics: Record<
        string,
        {
          comparisonGate: { status: string; accepted: boolean };
          modelLatencyMs: { p50: number | null; p95: number | null };
          endToEndLatencyMs: { p50: number | null; p95: number | null };
          tokens: number | null;
          costUSD: number | null;
        }
      >;
    };
    expect(report.suite).toBe("missing-slots-risk");
    for (const metrics of Object.values(report.metrics)) {
      expect(metrics.comparisonGate).toMatchObject({
        status: "not_run",
        accepted: false,
      });
      expect(metrics.modelLatencyMs).toEqual({
        p50: null,
        p95: null,
        samples: 0,
      });
      expect(metrics.endToEndLatencyMs).toEqual({
        p50: null,
        p95: null,
        samples: 0,
      });
      expect(metrics.tokens).toBeNull();
      expect(metrics.costUSD).toBeNull();
    }
  });

  it("runs a bounded live stage adapter against a strict local provider fixture", async () => {
    const server = createServer((request, response) => {
      const chunks: Buffer[] = [];
      request.on("data", (chunk: Buffer) => chunks.push(chunk));
      request.on("end", () => {
        const body = JSON.parse(Buffer.concat(chunks).toString("utf8")) as {
          questions: Record<string, { criteria?: Record<string, unknown> }>;
        };
        const answers = Object.fromEntries(
          Object.entries(body.questions).map(([questionId, question]) => {
            const choices = Object.keys(question.criteria ?? {});
            const choice = choices[0] ?? "none";
            return [
              questionId,
              {
                type: "choice",
                questionId,
                choice,
                probabilities: Object.fromEntries(
                  choices.map((candidate) => [
                    candidate,
                    candidate === choice ? 1 : 0,
                  ]),
                ),
                confidence: 1,
              },
            ];
          }),
        );
        response.writeHead(200, { "content-type": "application/json" });
        response.end(
          JSON.stringify({
            model: "jev-test",
            answers,
            usage: {
              input_tokens: 20,
              output_tokens: 10,
              total_tokens: 30,
              estimated_cost_usd: 999,
            },
          }),
        );
      });
    });
    await new Promise<void>((resolve, reject) => {
      server.once("error", reject);
      server.listen(0, "127.0.0.1", resolve);
    });
    const address = server.address();
    if (address === null || typeof address === "string") {
      server.close();
      throw new Error("test provider did not expose a port");
    }
    try {
      const result = await execFileAsync(
        process.execPath,
        [
          "scripts/evaluate-intent.ts",
          "--mode",
          "live",
          "--suite",
          "A",
          "--split",
          "development",
          "--max-cases",
          "2",
          "--max-calls",
          "2",
          "--max-tokens",
          "1000",
        ],
        {
          env: {
            ...process.env,
            TYPESAFE_API_KEY: "test-key",
            FLOWSTATE_JEV_MODEL: "jev-test",
            TYPESAFE_BASE_URL: `http://127.0.0.1:${address.port}/v1`,
          },
          maxBuffer: 2_000_000,
        },
      );
      const report = JSON.parse(result.stdout) as {
        mode: string;
        status: string;
        pricing: {
          inputUSDPerMillion: number;
          outputUSDPerMillion: number;
          source: string;
          version: string;
        };
        splitCounts: Record<string, number>;
        evaluatedCases: number;
        familyIsolation: { holdoutGroups: number };
        providerFailures: unknown[];
        metrics: {
          development: {
            baseline: {
              samples: number;
              endToEndLatencyMs: { samples: number; p95: number | null };
            };
            jev: {
              contractValidity: number | null;
              modelLatencyMs: { samples: number; p95: number | null };
              endToEndLatencyMs: { samples: number; p95: number | null };
              exactChoiceCorrectness: number | null;
              consequentialFalseExecution: number | null;
              abstentionRate: number | null;
              tokens: number | null;
              costUSD: number | null;
            };
            comparisonGate: { status: string; accepted: boolean };
          };
        };
      };
      expect(report.mode).toBe("live");
      expect(report.status).toBe("disabled");
      expect(report.pricing).toMatchObject({
        inputUSDPerMillion: 0.042,
        outputUSDPerMillion: 0,
        source: "https://docs.typesafe.ai/models.md",
        version: "models.md-jev-1.13.0",
      });
      expect(report.splitCounts).toEqual({
        development: 2,
        calibration: 1,
        holdout: 1,
      });
      expect(report.evaluatedCases).toBe(2);
      expect(report.familyIsolation.holdoutGroups).toBe(1);
      expect(report.providerFailures).toEqual([]);
      expect(report.metrics.development.baseline.samples).toBe(2);
      expect(
        report.metrics.development.baseline.endToEndLatencyMs.samples,
      ).toBe(2);
      expect(report.metrics.development.jev.contractValidity).toBe(1);
      expect(report.metrics.development.jev.modelLatencyMs.samples).toBe(2);
      expect(report.metrics.development.jev.endToEndLatencyMs.samples).toBe(2);
      expect(
        report.metrics.development.jev.exactChoiceCorrectness,
      ).not.toBeNull();
      expect(report.metrics.development.jev.consequentialFalseExecution).toBe(
        0,
      );
      expect(report.metrics.development.jev.abstentionRate).not.toBeNull();
      expect(report.metrics.development.jev.tokens).toBe(60);
      expect(report.metrics.development.jev.costUSD).toBeCloseTo(0.00000168);
      expect(report.metrics.development.comparisonGate).toMatchObject({
        status: "evaluated",
        accepted: false,
      });

      const mainResult = await execFileAsync(
        process.execPath,
        [
          "scripts/evaluate-intent.ts",
          "--mode",
          "live",
          "--split",
          "development",
          "--max-cases",
          "1",
          "--max-calls",
          "1",
          "--max-tokens",
          "10000",
        ],
        {
          env: {
            ...process.env,
            TYPESAFE_API_KEY: "test-key",
            FLOWSTATE_JEV_MODEL: "jev-test",
            TYPESAFE_BASE_URL: `http://127.0.0.1:${address.port}/v1`,
          },
          maxBuffer: 2_000_000,
        },
      );
      const mainReport = JSON.parse(mainResult.stdout) as {
        pricing: { inputUSDPerMillion: number; outputUSDPerMillion: number };
        jev: { tokens: number; costUSD: number | null };
      };
      expect(mainReport.pricing).toMatchObject({
        inputUSDPerMillion: 0.042,
        outputUSDPerMillion: 0,
      });
      expect(mainReport.jev.tokens).toBe(30);
      expect(mainReport.jev.costUSD).toBeCloseTo(0.00000084);
    } finally {
      await new Promise<void>((resolve) => server.close(() => resolve()));
    }
  });
});
