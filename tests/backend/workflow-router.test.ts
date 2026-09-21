import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

import {
  DEFAULT_WORKFLOW_ROUTER_POLICY,
  WORKFLOW_ROUTER_ROUTES,
  buildWorkflowRouterQuestion,
  buildWorkflowRouterRequest,
  selectWorkflowRoute,
} from "../../convex/lib/workflow_router";

const fixture = JSON.parse(
  readFileSync("tests/fixtures/workflow-router/en.json", "utf8"),
) as {
  version: number;
  groups: Array<{
    id: string;
    category: string;
    scenarios: Array<{
      id: string;
      utterance: string;
      expectedRoute: string;
      harmfulIfDirectAction: boolean;
    }>;
  }>;
};

const confidentDirectAnswer = {
  choice: "direct_action",
  confidence: 0.98,
  probabilities: { direct_action: 0.98, workflow: 0.02 },
  selectedProbability: 0.98,
  topTwoMargin: 0.96,
};

describe("workflow router contract", () => {
  it("exposes exactly the two top-level role choices", () => {
    expect(WORKFLOW_ROUTER_ROUTES).toEqual(["direct_action", "workflow"]);
    expect(buildWorkflowRouterQuestion()).toMatchObject({
      choices: ["direct_action", "workflow"],
      type: "choice",
    });
  });

  it("builds a bounded role-only request without argument extraction fields", () => {
    const request = buildWorkflowRouterRequest({
      utterance: "Open Brave and search Hello World",
      context: {
        focusedApp: "com.example.Reader",
        installedApps: ["Brave", "Paint and Draw"],
        recentInteraction: "The user just finished a prior command.",
      },
    });

    expect(request.questions.route.choices).toEqual([
      "direct_action",
      "workflow",
    ]);
    expect(request.state).toEqual({
      utterance: "Open Brave and search Hello World",
      context: {
        focusedApp: "com.example.Reader",
        installedApps: ["Brave", "Paint and Draw"],
        recentInteraction: "The user just finished a prior command.",
      },
    });
    expect(JSON.stringify(request)).not.toContain("actionKind");
    expect(JSON.stringify(request)).not.toContain("targetId");
    expect(JSON.stringify(request)).not.toContain("parameters");
    expect(JSON.stringify(request.questions.route)).toContain("planner");
  });

  it("keeps a disabled policy fail-closed even for a confident direct answer", () => {
    expect(
      selectWorkflowRoute({
        answer: confidentDirectAnswer,
        policy: DEFAULT_WORKFLOW_ROUTER_POLICY,
      }),
    ).toEqual({
      route: "workflow",
      accepted: false,
      reason: "policy_disabled",
    });
  });

  it("accepts direct action only after both frozen thresholds pass", () => {
    const policy = {
      ...DEFAULT_WORKFLOW_ROUTER_POLICY,
      status: "enabled" as const,
      minSelectedProbability: 0.9,
      minTopTwoMargin: 0.7,
    };
    expect(selectWorkflowRoute({ answer: confidentDirectAnswer, policy })).toEqual({
      route: "direct_action",
      accepted: true,
      reason: "threshold_passed",
    });
    expect(
      selectWorkflowRoute({
        answer: {
          ...confidentDirectAnswer,
          selectedProbability: 0.91,
          topTwoMargin: 0.69,
        },
        policy,
      }),
    ).toEqual({
      route: "workflow",
      accepted: false,
      reason: "below_threshold",
    });
  });

  it("sends model workflow choices and malformed answers to the planner", () => {
    const policy = {
      ...DEFAULT_WORKFLOW_ROUTER_POLICY,
      status: "enabled" as const,
      minSelectedProbability: 0.9,
      minTopTwoMargin: 0.7,
    };
    expect(
      selectWorkflowRoute({
        answer: {
          ...confidentDirectAnswer,
          choice: "workflow",
          probabilities: { direct_action: 0.03, workflow: 0.97 },
          selectedProbability: 0.97,
          topTwoMargin: 0.94,
        },
        policy,
      }),
    ).toEqual({
      route: "workflow",
      accepted: false,
      reason: "model_workflow",
    });
    expect(
      selectWorkflowRoute({
        answer: {
          ...confidentDirectAnswer,
          selectedProbability: Number.NaN,
        },
        policy,
      }),
    ).toEqual({
      route: "workflow",
      accepted: false,
      reason: "invalid_answer",
    });
  });
});

describe("workflow router fixture", () => {
  it("keeps grouped synthetic cases unique and covers the risk boundaries", () => {
    const scenarios = fixture.groups.flatMap((group) => group.scenarios);
    const keys = scenarios.map((scenario) => scenario.utterance);
    expect(fixture.version).toBe(1);
    expect(fixture.groups.length).toBeGreaterThanOrEqual(12);
    expect(scenarios.length).toBeGreaterThanOrEqual(24);
    expect(new Set(keys).size).toBe(keys.length);
    expect(
      scenarios.some((scenario) =>
        scenario.utterance.includes("Open Brave and search Hello World"),
      ),
    ).toBe(true);
    expect(
      scenarios.some((scenario) =>
        scenario.utterance.toLocaleLowerCase().includes("paint and draw"),
      ),
    ).toBe(true);
    expect(
      scenarios.some(
        (scenario) =>
          scenario.expectedRoute === "workflow" &&
          scenario.harmfulIfDirectAction,
      ),
    ).toBe(true);
  });
});

describe("workflow router evaluator", () => {
  it("reports deterministic fixture and explicit disabled adoption status", () => {
    const report = JSON.parse(
      execFileSync(
        process.execPath,
        ["scripts/evaluate-workflow-router.ts", "--mode", "deterministic"],
        { encoding: "utf8" },
      ),
    ) as {
      mode: string;
      policy: { status: string; thresholds: unknown };
      gates: { accepted: boolean };
      splitCounts: Record<string, number>;
      metrics: Record<string, { samples: number }>;
    };

    expect(report.mode).toBe("deterministic");
    expect(report.policy).toEqual({ status: "disabled", thresholds: null });
    expect(report.gates.accepted).toBe(false);
    expect(report.splitCounts).toMatchObject({
      development: expect.any(Number),
      calibration: expect.any(Number),
      holdout: expect.any(Number),
    });
    expect(report.metrics.development.samples).toBeGreaterThan(0);
  });
});

it("counts a partially evaluated case when the call budget stops the run", () => {
  const source = `
    import { readFileSync } from 'node:fs';
    import { liveReport, splitFixture } from './scripts/evaluate-workflow-router.ts';
    process.env.FLOWSTATE_EVALUATION_ENV_FILE='/dev/null';
    process.env.TYPESAFE_API_KEY='synthetic'; process.env.OPENAI_API_KEY='synthetic';
    process.env.FLOWSTATE_JEV_MODEL='synthetic'; process.env.FLOWSTATE_PLANNER_MODEL='synthetic';
    globalThis.fetch=async()=>new Response(JSON.stringify({model:'synthetic',output_text:'{"route":"workflow"}',usage:{input_tokens:1,output_tokens:1,total_tokens:2}}));
    const fixture=JSON.parse(readFileSync('tests/fixtures/workflow-router/en.json','utf8'));
    const result=await liveReport(fixture,splitFixture(fixture,20260922),new Map([['max-calls','1']]));
    process.stdout.write(JSON.stringify(result));
  `;
  const report = JSON.parse(execFileSync(process.execPath, ["--input-type=module", "-e", source], {encoding:"utf8"})) as {
    rows: Array<{ errors: string[] }>;
    metrics: { calibration: { jev: { contractValidity: number } } };
    gates: { accepted: boolean };
  };
  expect(report.rows).toHaveLength(1);
  expect(report.rows[0].errors).toContain("max_calls");
  expect(report.metrics.calibration.jev.contractValidity).toBe(0);
  expect(report.gates.accepted).toBe(false);
});
