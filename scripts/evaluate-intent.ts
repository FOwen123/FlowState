import { readFile } from "node:fs/promises";
import { createHash } from "node:crypto";
import { buildIntentQuestionsData } from "../convex/lib/intent_questions.ts";
import { parseStrictTypeSafeResponse } from "../convex/lib/strict_typesafe.ts";

type Scenario = {
  id: string;
  utterance: string;
  mode: "auto" | "dictation" | "commands";
  supportedActions: string[];
  permissibleIntents: string[];
  expected: {
    intent: string;
    action?: string;
    target?: string;
    requiredClarification: boolean;
  };
  context: Record<string, unknown>;
  grantState: Array<Record<string, unknown>>;
  screenshotRelevance: string;
  riskClass: string;
};

type Group = { id: string; category?: string; scenarios: Scenario[] };
type Fixture = {
  version: number;
  language: string;
  policyVersion: string;
  groups: Group[];
};
type Split = "development" | "calibration" | "holdout";

const ACTIONS = [
  "openApplication",
  "scroll",
  "focus",
  "select",
  "press",
  "insertText",
  "openURL",
  "attachFile",
  "sendEmail",
] as const;
const PROMPT_VERSION = "intent-questions-v2";
const CANDIDATE_SET_VERSION = "fixture-candidates-v1";

function supportedActionsForScenario(scenario: Scenario): string[] {
  return [...scenario.supportedActions];
}

function supportedCapabilitiesForScenario(scenario: Scenario): string[] {
  return [
    ...new Set(
      scenario.grantState
        .filter(
          (grant) =>
            grant.active === true && typeof grant.capability === "string",
        )
        .map((grant) => grant.capability as string),
    ),
  ];
}

function hash(value: string): number {
  let result = 2_166_136_261;
  for (let index = 0; index < value.length; index += 1) {
    result ^= value.charCodeAt(index);
    result = Math.imul(result, 16_777_619);
  }
  return result >>> 0;
}

function splitGroups(groups: Group[], seed: number): Record<Split, Scenario[]> {
  const result: Record<Split, Scenario[]> = {
    development: [],
    calibration: [],
    holdout: [],
  };
  const byCategory = new Map<string, Group[]>();
  for (const group of groups) {
    const categoryGroups =
      byCategory.get(group.category ?? "uncategorized") ?? [];
    categoryGroups.push(group);
    byCategory.set(group.category ?? "uncategorized", categoryGroups);
  }
  for (const category of [...byCategory.keys()].sort()) {
    const orderedGroups = (byCategory.get(category) ?? []).sort(
      (a, b) => hash(`${seed}:${a.id}`) - hash(`${seed}:${b.id}`),
    );
    const developmentCount = Math.max(
      1,
      Math.round(orderedGroups.length * 0.5),
    );
    const calibrationCount = Math.max(
      1,
      Math.round(orderedGroups.length * 0.25),
    );
    for (const [index, group] of orderedGroups.entries()) {
      const split: Split =
        index < developmentCount
          ? "development"
          : index < developmentCount + calibrationCount
            ? "calibration"
            : "holdout";
      for (const scenario of group.scenarios) {
        result[split].push({ ...scenario, id: `${group.id}/${scenario.id}` });
      }
    }
  }
  return result;
}

function parseArgs(argv: string[]): Map<string, string> {
  const result = new Map<string, string>();
  for (let index = 0; index < argv.length; index += 1) {
    const value = argv[index];
    if (!value?.startsWith("--"))
      throw new Error(`unexpected argument ${value ?? ""}`);
    const next = argv[index + 1];
    if (!next || next.startsWith("--"))
      throw new Error(`${value} requires a value`);
    result.set(value.slice(2), next);
    index += 1;
  }
  return result;
}

function positiveInteger(
  args: Map<string, string>,
  key: string,
  required: boolean,
): number | undefined {
  const raw = args.get(key);
  if (raw === undefined) {
    if (required) throw new Error(`--${key} is required`);
    return undefined;
  }
  const value = Number(raw);
  if (!Number.isInteger(value) || value <= 0)
    throw new Error(`--${key} must be a positive integer`);
  return value;
}

function expectedAction(scenario: Scenario): string {
  return (
    scenario.expected.action ??
    (scenario.expected.intent === "dictation"
      ? "insertText"
      : scenario.expected.requiredClarification
        ? "clarify"
        : scenario.expected.intent)
  );
}

function emptyMetrics(scenarios: Scenario[]) {
  const byIntent = Object.fromEntries(
    ["dictation", "action", "clarify", "unsupported"].map((intent) => [
      intent,
      scenarios.filter((scenario) => scenario.expected.intent === intent)
        .length,
    ]),
  );
  const byAction = Object.fromEntries(
    ACTIONS.map((action) => [
      action,
      scenarios.filter((scenario) => expectedAction(scenario) === action)
        .length,
    ]),
  );
  return {
    samples: scenarios.length,
    byIntent,
    byAction,
    predictions: 0,
    correct: null,
    accuracy: null,
    note: "No model accuracy is reported without predictions.",
  };
}

function comparePrediction(scenario: Scenario, prediction: unknown): boolean {
  if (!prediction || typeof prediction !== "object") return false;
  const value = prediction as Record<string, unknown>;
  const actualIntent =
    typeof value.intent === "string" ? value.intent : value.decision;
  if (actualIntent !== scenario.expected.intent) return false;
  if (
    scenario.expected.action !== undefined &&
    value.action !== scenario.expected.action
  )
    return false;
  if (
    scenario.expected.target !== undefined &&
    value.target !== scenario.expected.target
  )
    return false;
  return true;
}

function deterministicReport(
  splits: Record<Split, Scenario[]>,
  predictions: Record<string, unknown> | null,
) {
  const report = Object.fromEntries(
    (Object.keys(splits) as Split[]).map((split) => {
      const scenarios = splits[split];
      const metrics = emptyMetrics(scenarios);
      if (predictions !== null) {
        const predicted = scenarios.filter((scenario) =>
          Object.hasOwn(predictions, scenario.id),
        );
        const correct = predicted.filter((scenario) =>
          comparePrediction(scenario, predictions[scenario.id]),
        ).length;
        metrics.predictions = predicted.length;
        metrics.correct = correct;
        metrics.accuracy =
          predicted.length === 0 ? null : correct / predicted.length;
        metrics.note =
          predicted.length === 0
            ? "Predictions file contained no rows for this split."
            : "Measured against supplied predictions.";
      }
      return [split, metrics];
    }),
  );
  return report;
}

async function liveReport(
  scenarios: Scenario[],
  args: Map<string, string>,
  maxCalls: number,
  maxTokens: number,
  maxCases: number,
  policyVersion: string,
) {
  const apiKey = process.env.TYPESAFE_API_KEY;
  const model = process.env.FLOWSTATE_JEV_MODEL;
  if (!apiKey || !model)
    throw new Error(
      "TYPESAFE_API_KEY and FLOWSTATE_JEV_MODEL are required for live evaluation",
    );
  const selected = scenarios.slice(0, maxCases);
  const rows: Array<Record<string, unknown>> = [];
  let calls = 0;
  let tokens = 0;
  let failures = 0;
  let stoppedReason: string | undefined;
  for (const scenario of selected) {
    if (calls >= maxCalls) {
      stoppedReason = "max_calls";
      break;
    }
    if (tokens >= maxTokens) {
      stoppedReason = "max_tokens";
      break;
    }
    const supportedActions = supportedActionsForScenario(scenario);
    const supportedCapabilities = supportedCapabilitiesForScenario(scenario);
    const targetChoices = [
      "none",
      ...((
        scenario.context.targetCandidates as Array<{ id: string }> | undefined
      )?.map((candidate) => candidate.id) ?? []),
    ];
    const builtQuestions = buildIntentQuestionsData({
      supportedActions,
      targetCandidates:
        (scenario.context.targetCandidates as
          Array<{ id: string }> | undefined) ?? [],
    });
    const questions = Object.fromEntries(
      Object.entries(builtQuestions).map(([key, question]) => [
        key,
        {
          type: "choice",
          instructions: question.instructions,
          criteria: question.criteria,
        },
      ]),
    );
    const strictQuestions = Object.fromEntries(
      Object.entries(builtQuestions).map(([key, question]) => [
        key,
        { choices: question.choices },
      ]),
    );
    const estimatedTokens = Math.ceil(
      JSON.stringify({ scenario, questions }).length / 4,
    );
    if (tokens + estimatedTokens > maxTokens) {
      stoppedReason = "preflight_token_budget";
      break;
    }
    const started = Date.now();
    try {
      const response = await fetch("https://api.typesafe.ai/v1/systemone", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${apiKey}`,
          "Content-Type": "application/json",
        },
        signal: AbortSignal.timeout(30_000),
        body: JSON.stringify({
          model,
          state: {
            utterance: scenario.utterance,
            mode: scenario.mode,
            context: scenario.context,
            supportedActions,
            supportedCapabilities,
            policyVersion,
          },
          questions,
        }),
      });
      if (!response.ok) throw new Error(`provider status ${response.status}`);
      const parsed = parseStrictTypeSafeResponse(
        (await response.json()) as unknown,
        strictQuestions,
      );
      const intent = parsed.answers.intent;
      const action = parsed.answers.action;
      const target = parsed.answers.target;
      if (!targetChoices.includes(target.choice))
        throw new Error("provider returned an unknown target");
      const usage = parsed.usage;
      if (
        usage?.input_tokens === undefined ||
        usage.output_tokens === undefined
      ) {
        throw new Error(
          "provider usage is missing; token budget cannot be enforced",
        );
      }
      const callTokens = usage.input_tokens + usage.output_tokens;
      tokens += callTokens;
      rows.push({
        id: scenario.id,
        expected: scenario.expected,
        actual: {
          intent: intent.choice,
          action: action.choice,
          target: target.choice,
        },
        probabilities: {
          intent: intent.selectedProbability,
          action: action.selectedProbability,
          target: target.selectedProbability,
        },
        topTwoMargin: {
          intent: intent.topTwoMargin,
          action: action.topTwoMargin,
          target: target.topTwoMargin,
        },
        confidence: {
          intent: intent.confidence,
          action: action.confidence,
          target: target.confidence,
        },
        model: parsed.model,
        promptVersion: PROMPT_VERSION,
        candidateSetVersion: CANDIDATE_SET_VERSION,
        supportedActions,
        supportedCapabilities,
        latencyMs: Date.now() - started,
        usage,
      });
      calls += 1;
      failures = 0;
    } catch (error) {
      rows.push({
        id: scenario.id,
        expected: scenario.expected,
        error: error instanceof Error ? error.message : "provider_error",
        latencyMs: Date.now() - started,
      });
      calls += 1;
      failures += 1;
      if (
        error instanceof Error &&
        error.message.includes("usage is missing")
      ) {
        stoppedReason = "unknown_usage";
        break;
      }
      if (failures >= 3) {
        stoppedReason = "repeated_provider_failures";
        break;
      }
    }
  }
  return {
    mode: "live",
    split: args.get("split") ?? "development",
    budget: { maxCases, maxCalls, maxTokens },
    calls,
    tokens,
    stoppedReason: stoppedReason ?? null,
    rows,
    note: "Live evaluation routes only; no desktop, email, file or deployment effects are performed.",
  };
}

const args = parseArgs(process.argv.slice(2));
const fixturePath = args.get("fixture") ?? "tests/fixtures/intent/en.json";
const fixtureText = await readFile(fixturePath, "utf8");
const fixtureHash = createHash("sha256").update(fixtureText).digest("hex");
const fixture = JSON.parse(fixtureText) as Fixture;
const seed = Number(args.get("seed") ?? "17");
if (!Number.isInteger(seed)) throw new Error("--seed must be an integer");
const splits = splitGroups(fixture.groups, seed);
const mode = args.get("mode") ?? "deterministic";
const split = (args.get("split") ?? "development") as Split;
if (!(split in splits))
  throw new Error("--split must be development, calibration or holdout");
if (mode === "deterministic") {
  const predictionPath = args.get("predictions");
  const predictions =
    predictionPath === undefined
      ? null
      : (JSON.parse(await readFile(predictionPath, "utf8")) as Record<
          string,
          unknown
        >);
  console.log(
    JSON.stringify(
      {
        mode,
        seed,
        fixture: {
          version: fixture.version,
          language: fixture.language,
          policyVersion: fixture.policyVersion,
          groups: fixture.groups.length,
          scenarios: fixture.groups.reduce(
            (total, group) => total + group.scenarios.length,
            0,
          ),
        },
        versions: {
          fixtureSha256: fixtureHash,
          promptVersion: PROMPT_VERSION,
          candidateSetVersion: CANDIDATE_SET_VERSION,
        },
        splitCounts: Object.fromEntries(
          Object.entries(splits).map(([name, scenarios]) => [
            name,
            scenarios.length,
          ]),
        ),
        metrics: deterministicReport(splits, predictions),
        policy: {
          version: fixture.policyVersion,
          status: "unmeasured",
          thresholds: null,
        },
        note: "Deterministic validation reports fixture and supplied predictions only; no accuracy or release threshold is fabricated.",
      },
      null,
      2,
    ),
  );
} else if (mode === "live") {
  const maxCases = positiveInteger(args, "max-cases", true);
  const maxCalls = positiveInteger(args, "max-calls", true);
  const maxTokens = positiveInteger(args, "max-tokens", true);
  const report = await liveReport(
    splits[split],
    args,
    maxCalls,
    maxTokens,
    maxCases,
    fixture.policyVersion,
  );
  console.log(
    JSON.stringify(
      {
        seed,
        fixture: {
          path: fixturePath,
          version: fixture.version,
          sha256: fixtureHash,
        },
        versions: {
          promptVersion: PROMPT_VERSION,
          candidateSetVersion: CANDIDATE_SET_VERSION,
        },
        ...report,
      },
      null,
      2,
    ),
  );
} else {
  throw new Error("--mode must be deterministic or live");
}
