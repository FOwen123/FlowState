import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";

import {
  DEFAULT_WORKFLOW_ROUTER_POLICY,
  WORKFLOW_ROUTER_ROUTES,
  buildWorkflowRouterRequest,
  selectWorkflowRoute,
  type WorkflowRouterContext,
  type WorkflowRouterPolicy,
  type WorkflowRouterRoute,
} from "../convex/lib/workflow_router.ts";
import {
  parseStrictTypeSafeResponse,
  type StrictTypeSafeAnswer,
} from "../convex/lib/strict_typesafe.ts";

const FIXTURE_PATH = "tests/fixtures/workflow-router/en.json";
const DEFAULT_ENV_FILE = ".env.local";
const PROMPT_VERSION = "workflow-router-v1";
const BASELINE_PROMPT_VERSION = "workflow-router-llm-baseline-v2";
const SEED = 20260922;
const TIMEOUT_MS = 15_000;
const MAX_CONSECUTIVE_FAILURES = 3;
const LIMITS = Object.freeze({
  maxCases: 24,
  maxCalls: 48,
  maxTokens: 250_000,
});
const TYPESAFE_INPUT_USD_PER_MILLION = 0.042;

type Split = "development" | "calibration" | "holdout";
type Scenario = {
  id: string;
  utterance: string;
  context?: WorkflowRouterContext;
  expectedRoute: WorkflowRouterRoute;
  harmfulIfDirectAction: boolean;
};
type Group = { id: string; category: string; scenarios: Scenario[] };
type Fixture = {
  version: number;
  language: string;
  policyVersion: string;
  groups: Group[];
};
type ScenarioWithSplit = Scenario & { split: Exclude<Split, "development"> };
type Usage = { totalTokens: number; inputTokens?: number };
type ProviderResult<T> = {
  value: T;
  latencyMs: number;
  usage: Usage;
};
type JevObservation = {
  answer: StrictTypeSafeAnswer;
  model: string;
  latencyMs: number;
  usage: Usage;
};
type BaselineObservation = {
  route: WorkflowRouterRoute;
  model: string;
  latencyMs: number;
  usage: Usage;
};
type EvaluationRow = {
  split: Exclude<Split, "development">;
  id: string;
  utterance: string;
  expectedRoute: WorkflowRouterRoute;
  harmfulIfDirectAction: boolean;
  jev?: JevObservation;
  baseline?: BaselineObservation;
  baselineAttempt?: { latencyMs: number; usage: Usage };
  errors: string[];
};

const ROUTER_POLICY_CANDIDATES = [
  { minSelectedProbability: 0.5, minTopTwoMargin: 0 },
  { minSelectedProbability: 0.6, minTopTwoMargin: 0.1 },
  { minSelectedProbability: 0.7, minTopTwoMargin: 0.2 },
  { minSelectedProbability: 0.8, minTopTwoMargin: 0.3 },
  { minSelectedProbability: 0.9, minTopTwoMargin: 0.5 },
  { minSelectedProbability: 0.95, minTopTwoMargin: 0.7 },
  { minSelectedProbability: 0.98, minTopTwoMargin: 0.85 },
] as const;

const BASELINE_INSTRUCTIONS =
  "Classify only the downstream role for a completed English voice-control utterance. Return exactly one JSON object with one key: {\"route\":\"direct_action\"} or {\"route\":\"workflow\"}. Use direct_action only for exactly one clear, complete, bounded local action. Use workflow for compounds, sequencing, negation, corrections, follow-ups, unresolved references, generated content, external requests, unsupported workflows, or uncertainty. Do not extract arguments or execute anything.";

function parseArgs(argv: string[]): Map<string, string> {
  const result = new Map<string, string>();
  for (let index = 0; index < argv.length; index += 1) {
    const raw = argv[index];
    if (!raw?.startsWith("--")) throw new Error("unexpected argument");
    const value = argv[index + 1];
    if (!value || value.startsWith("--")) throw new Error(`${raw} requires a value`);
    result.set(raw.slice(2), value);
    index += 1;
  }
  return result;
}

function positiveBounded(args: Map<string, string>, key: string, fallback: number): number {
  const raw = args.get(key);
  if (raw === undefined) return fallback;
  const value = Number(raw);
  const limit = LIMITS[key as keyof typeof LIMITS];
  if (!Number.isSafeInteger(value) || value <= 0 || value > limit) {
    throw new Error(`--${key} must be a positive integer at most ${limit}`);
  }
  return value;
}

function hash(value: string): number {
  return createHash("sha256").update(value).digest().readUInt32BE(0);
}

function splitFixture(fixture: Fixture, seed: number): Record<Split, Scenario[]> {
  const groups = [...fixture.groups].sort((a, b) =>
    hash(`${seed}:${a.id}`) - hash(`${seed}:${b.id}`),
  );
  const developmentCount = Math.max(1, Math.floor(groups.length * 0.5));
  const calibrationCount = Math.max(1, Math.floor(groups.length * 0.25));
  const result: Record<Split, Scenario[]> = {
    development: [],
    calibration: [],
    holdout: [],
  };
  groups.forEach((group, index) => {
    const split: Split =
      index < developmentCount
        ? "development"
        : index < developmentCount + calibrationCount
          ? "calibration"
          : "holdout";
    for (const scenario of group.scenarios) {
      result[split].push({ ...scenario, id: `${group.id}/${scenario.id}` });
    }
  });
  return result;
}

function fixtureHash(fixture: Fixture): string {
  return createHash("sha256").update(JSON.stringify(fixture)).digest("hex");
}

async function loadEnv(): Promise<void> {
  const path = process.env.FLOWSTATE_EVALUATION_ENV_FILE ?? DEFAULT_ENV_FILE;
  let contents: string;
  try {
    contents = await readFile(path, "utf8");
  } catch {
    return;
  }
  for (const line of contents.split(/\r?\n/)) {
    const match = line.match(/^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$/);
    if (!match) continue;
    const key = match[1];
    let value = match[2] ?? "";
    if (
      value.length >= 2 &&
      ((value.startsWith('"') && value.endsWith('"')) ||
        (value.startsWith("'") && value.endsWith("'")))
    ) {
      value = value.slice(1, -1);
    }
    if (process.env[key] === undefined) process.env[key] = value;
  }
}

function boundedFetch(input: RequestInfo | URL, init?: RequestInit): Promise<Response> {
  return fetch(input, { ...init, signal: AbortSignal.timeout(TIMEOUT_MS) });
}

function parseUsage(value: Record<string, number> | undefined): Usage {
  const inputTokens = value?.input_tokens;
  const outputTokens = value?.output_tokens;
  const totalTokens = value?.total_tokens ??
    (typeof inputTokens === "number" && typeof outputTokens === "number"
      ? inputTokens + outputTokens
      : undefined);
  if (
    typeof totalTokens !== "number" ||
    !Number.isFinite(totalTokens) ||
    totalTokens < 0
  ) {
    throw new Error("usage_missing");
  }
  return {
    totalTokens,
    ...(typeof inputTokens === "number" ? { inputTokens } : {}),
  };
}

async function requestProvider(
  provider: "typesafe" | "openai",
  url: string,
  apiKey: string,
  body: Record<string, unknown>,
): Promise<{ value: unknown; latencyMs: number }> {
  const started = performance.now();
  let response: Response;
  try {
    response = await boundedFetch(url, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${apiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(body),
    });
  } catch {
    throw new Error(`${provider}_request_failed`);
  }
  const latencyMs = Math.max(0, performance.now() - started);
  if (!response.ok) {
    await response.body?.cancel();
    throw new Error(`${provider}_status_${response.status}`);
  }
  let value: unknown;
  try {
    value = JSON.parse(await response.text()) as unknown;
  } catch {
    throw new Error(`${provider}_invalid_json`);
  }
  return { value, latencyMs };
}

async function requestJev(input: {
  apiKey: string;
  model: string;
  baseUrl: string;
  state: Record<string, unknown>;
  question: Record<string, unknown>;
}): Promise<ProviderResult<{ response: ReturnType<typeof parseStrictTypeSafeResponse> }>> {
  const result = await requestProvider(
    "typesafe",
    `${input.baseUrl.replace(/\/$/, "")}/systemone`,
    input.apiKey,
    { state: input.state, model: input.model, questions: { route: input.question } },
  );
  const response = result.value as { model?: unknown; answers?: unknown; usage?: unknown };
  const usageRecord =
    typeof response.usage === "object" && response.usage !== null
      ? Object.fromEntries(
          Object.entries(response.usage).flatMap(([key, value]) =>
            typeof value === "number" ? [[key, value]] : [],
          ),
        )
      : undefined;
  return {
    value: { response: parseStrictTypeSafeResponse(result.value, { route: { choices: WORKFLOW_ROUTER_ROUTES } }) },
    latencyMs: result.latencyMs,
    usage: parseUsage(usageRecord),
  };
}

async function requestBaseline(input: {
  apiKey: string;
  model: string;
  baseUrl: string;
  state: Record<string, unknown>;
}): Promise<ProviderResult<{ outputText: string; model: string }>> {
  const result = await requestProvider(
    "openai",
    `${input.baseUrl.replace(/\/$/, "")}/responses`,
    input.apiKey,
    {
      model: input.model,
      input: JSON.stringify(input.state),
      instructions: BASELINE_INSTRUCTIONS,
      max_output_tokens: 512,
      store: false,
    },
  );
  const response = result.value as {
    id?: unknown;
    output_text?: unknown;
    output?: unknown;
    usage?: unknown;
  };
  const usageRecord =
    typeof response.usage === "object" && response.usage !== null
      ? Object.fromEntries(
          Object.entries(response.usage).flatMap(([key, value]) =>
            typeof value === "number" ? [[key, value]] : [],
          ),
        )
      : undefined;
  return {
    value: {
      outputText: parseBaselineText(response),
      model: typeof response.id === "string" ? input.model : input.model,
    },
    latencyMs: result.latencyMs,
    usage: parseUsage(usageRecord),
  };
}

function parseBaselineRoute(output: string): WorkflowRouterRoute {
  const trimmed = output
    .trim()
    .replace(/^```(?:json)?\s*/i, "")
    .replace(/\s*```$/, "")
    .trim();
  let value: unknown;
  try {
    value = JSON.parse(trimmed) as unknown;
  } catch {
    throw new Error("baseline_invalid_json");
  }
  if (
    typeof value !== "object" ||
    value === null ||
    Array.isArray(value) ||
    Object.keys(value).length !== 1 ||
    !("route" in value) ||
    !WORKFLOW_ROUTER_ROUTES.includes(
      (value as { route?: unknown }).route as WorkflowRouterRoute,
    )
  ) {
    throw new Error("baseline_invalid_route");
  }
  return (value as { route: WorkflowRouterRoute }).route;
}

function parseBaselineText(response: {
  output_text?: unknown;
  output?: unknown;
}): string {
  if (typeof response.output_text === "string") return response.output_text;
  if (!Array.isArray(response.output)) throw new Error("baseline_missing_output");
  const chunks: string[] = [];
  for (const item of response.output) {
    if (typeof item !== "object" || item === null || !("content" in item)) continue;
    const content = (item as { content?: unknown }).content;
    if (!Array.isArray(content)) continue;
    for (const part of content) {
      if (typeof part !== "object" || part === null || !("text" in part)) continue;
      const text = (part as { text?: unknown }).text;
      if (typeof text === "string") chunks.push(text);
    }
  }
  if (chunks.length === 0) throw new Error("baseline_missing_output");
  return chunks.join("\n");
}

function routePolicy(
  thresholds: { minSelectedProbability: number; minTopTwoMargin: number } | null,
): WorkflowRouterPolicy {
  if (thresholds === null) return DEFAULT_WORKFLOW_ROUTER_POLICY;
  return {
    ...DEFAULT_WORKFLOW_ROUTER_POLICY,
    status: "enabled",
    ...thresholds,
  };
}

function metricRows(rows: EvaluationRow[], policy: WorkflowRouterPolicy) {
  const baselinePredictions = rows.filter((row) => row.baseline !== undefined);
  const baselineCorrect = baselinePredictions.filter(
    (row) => row.baseline?.route === row.expectedRoute,
  ).length;
  const baselineHarmful = baselinePredictions.filter(
    (row) => row.expectedRoute === "workflow" && row.baseline?.route === "direct_action",
  ).length;
  const jevPredictions = rows.filter((row) => row.jev !== undefined);
  const jevDecisions = jevPredictions.map((row) => ({
    row,
    decision: selectWorkflowRoute({
      answer: row.jev?.answer as StrictTypeSafeAnswer,
      policy,
    }),
  }));
  const jevCorrect = jevDecisions.filter(
    ({ row, decision }) => decision.route === row.expectedRoute,
  ).length;
  const harmfulAcceptedWrongRoute = jevDecisions.filter(
    ({ row, decision }) =>
      row.harmfulIfDirectAction && decision.accepted && decision.route === "direct_action",
  ).length;
  const directExpected = rows.filter((row) => row.expectedRoute === "direct_action").length;
  const latency = (values: number[]) => {
    const sorted = [...values].sort((a, b) => a - b);
    if (sorted.length === 0) return { p50: null, p95: null, samples: 0 };
    return {
      p50: sorted[Math.max(0, Math.ceil(sorted.length * 0.5) - 1)] ?? null,
      p95: sorted[Math.max(0, Math.ceil(sorted.length * 0.95) - 1)] ?? null,
      samples: sorted.length,
    };
  };
  const baselineLatency = latency(rows.map((row) => row.baselineAttempt?.latencyMs ?? 0).filter((value) => value > 0));
  const jevLatency = latency(jevPredictions.map((row) => row.jev?.latencyMs ?? 0));
  const jevRawCorrect = jevPredictions.filter(
    (row) => row.jev?.answer.choice === row.expectedRoute,
  ).length;
  return {
    samples: rows.length,
    baseline: {
      predictions: baselinePredictions.length,
      contractValidity: rows.length === 0 ? null : baselinePredictions.length / rows.length,
      routeCorrectness: rows.length === 0 ? null : baselineCorrect / rows.length,
      harmfulWrongDirectAction: baselineHarmful,
      latencyMs: baselineLatency,
      tokens: rows.reduce((sum, row) => sum + (row.baselineAttempt?.usage.totalTokens ?? 0), 0),
    },
    jev: {
      predictions: jevPredictions.length,
      contractValidity: rows.length === 0 ? null : jevPredictions.length / rows.length,
      routeCorrectness: rows.length === 0 ? null : jevCorrect / rows.length,
      rawChoiceCorrectness: rows.length === 0 ? null : jevRawCorrect / rows.length,
      harmfulAcceptedWrongRoute,
      directActionCoverage: directExpected === 0
        ? null
        : jevDecisions.filter(
            ({ row, decision }) => row.expectedRoute === "direct_action" && decision.accepted,
          ).length / directExpected,
      latencyMs: jevLatency,
      tokens: jevPredictions.reduce((sum, row) => sum + (row.jev?.usage.totalTokens ?? 0), 0),
      costUSD: jevPredictions.reduce(
        (sum, row) => sum + ((row.jev?.usage.inputTokens ?? 0) / 1_000_000) * TYPESAFE_INPUT_USD_PER_MILLION,
        0,
      ),
    },
  };
}

function chooseCalibrationPolicy(rows: EvaluationRow[]): {
  thresholds: { minSelectedProbability: number; minTopTwoMargin: number } | null;
  calibration: ReturnType<typeof metricRows>;
} {
  const baseline = metricRows(rows, DEFAULT_WORKFLOW_ROUTER_POLICY).baseline;
  const candidates = ROUTER_POLICY_CANDIDATES.map((thresholds) => ({
    thresholds,
    metrics: metricRows(rows, routePolicy(thresholds)),
  })).filter(({ metrics }) =>
    metrics.jev.harmfulAcceptedWrongRoute === 0 &&
    metrics.jev.contractValidity === 1 &&
    (metrics.jev.routeCorrectness ?? -1) >= (baseline.routeCorrectness ?? -1),
  );
  const selected = candidates.sort((a, b) => {
    const coverage = (b.metrics.jev.directActionCoverage ?? 0) - (a.metrics.jev.directActionCoverage ?? 0);
    if (coverage !== 0) return coverage;
    return (
      a.thresholds.minSelectedProbability + a.thresholds.minTopTwoMargin -
      (b.thresholds.minSelectedProbability + b.thresholds.minTopTwoMargin)
    );
  })[0];
  return {
    thresholds: selected?.thresholds ?? null,
    calibration: metricRows(rows, routePolicy(selected?.thresholds ?? null)),
  };
}

function deterministicReport(fixture: Fixture, splits: Record<Split, Scenario[]>) {
  return {
    schemaVersion: 1,
    mode: "deterministic",
    fixture: {
      path: FIXTURE_PATH,
      version: fixture.version,
      language: fixture.language,
      policyVersion: fixture.policyVersion,
      sha256: fixtureHash(fixture),
      groups: fixture.groups.length,
      scenarios: fixture.groups.reduce((sum, group) => sum + group.scenarios.length, 0),
    },
    promptVersions: { jev: PROMPT_VERSION, baseline: BASELINE_PROMPT_VERSION },
    seed: SEED,
    splitCounts: Object.fromEntries(
      Object.entries(splits).map(([split, scenarios]) => [split, scenarios.length]),
    ),
    policy: { status: "disabled", thresholds: null },
    gates: { accepted: false, reason: "live_comparison_required" },
    metrics: {
      development: { samples: splits.development.length },
      calibration: { samples: splits.calibration.length },
      holdout: { samples: splits.holdout.length },
    },
    note: "Deterministic fixture validation makes no provider or adoption claim.",
  };
}

class Budget {
  calls = 0;
  tokens = 0;
  consecutiveFailures = 0;
  stoppedReason: string | null = null;
  readonly maxCalls: number;
  readonly maxTokens: number;

  constructor(maxCalls: number, maxTokens: number) {
    this.maxCalls = maxCalls;
    this.maxTokens = maxTokens;
  }

  beginCall(): void {
    if (this.stoppedReason !== null) throw new Error(this.stoppedReason);
    if (this.calls >= this.maxCalls) {
      this.stoppedReason = "max_calls";
      throw new Error("max_calls");
    }
    if (this.tokens >= this.maxTokens) {
      this.stoppedReason = "max_tokens";
      throw new Error("max_tokens");
    }
    this.calls += 1;
  }

  finishCall(usage: Usage): void {
    this.tokens += usage.totalTokens;
    if (this.tokens > this.maxTokens) {
      this.stoppedReason = "max_tokens";
      throw new Error("max_tokens");
    }
    this.consecutiveFailures = 0;
  }

  failure(code: string): void {
    this.consecutiveFailures += 1;
    if (this.consecutiveFailures >= MAX_CONSECUTIVE_FAILURES) {
      this.stoppedReason = "repeated_provider_failures";
    }
    throw new Error(code);
  }
}

async function liveReport(
  fixture: Fixture,
  splits: Record<Split, Scenario[]>,
  args: Map<string, string>,
): Promise<Record<string, unknown>> {
  await loadEnv();
  const maxCases = positiveBounded(args, "max-cases", LIMITS.maxCases);
  const maxCalls = positiveBounded(args, "max-calls", LIMITS.maxCalls);
  const maxTokens = positiveBounded(args, "max-tokens", LIMITS.maxTokens);
  const typesafeKey = process.env.TYPESAFE_API_KEY?.trim();
  const jevModel = process.env.FLOWSTATE_JEV_MODEL?.trim();
  const openAIKey = process.env.OPENAI_API_KEY?.trim();
  const baselineModel = process.env.FLOWSTATE_PLANNER_MODEL?.trim();
  if (!typesafeKey || !jevModel || !openAIKey || !baselineModel) {
    return {
      schemaVersion: 1,
      mode: "live",
      status: "disabled",
      stoppedReason: "provider_configuration_missing",
      budget: { maxCases, maxCalls, maxTokens, calls: 0, tokens: 0 },
      policy: { status: "disabled", thresholds: null },
      gates: { accepted: false, reason: "provider_configuration_missing" },
      rows: [],
      note: "No provider call was attempted; secrets and model names are never included in this report.",
    };
  }
  const calibration = splits.calibration.map((scenario) => ({ ...scenario, split: "calibration" as const }));
  const holdout = splits.holdout.map((scenario) => ({ ...scenario, split: "holdout" as const }));
  const calibrationLimit = Math.min(calibration.length, Math.ceil(maxCases / 2));
  const selectedCases: ScenarioWithSplit[] = [
    ...calibration.slice(0, calibrationLimit),
    ...holdout.slice(0, maxCases - calibrationLimit),
  ];
  const budget = new Budget(maxCalls, maxTokens);
  const jevBaseUrl = process.env.TYPESAFE_BASE_URL ?? "https://api.typesafe.ai/v1";
  const baselineBaseUrl = process.env.OPENAI_BASE_URL ?? "https://api.openai.com/v1";
  const rows: EvaluationRow[] = [];
  let frozenThresholds: { minSelectedProbability: number; minTopTwoMargin: number } | null = null;
  for (const scenario of selectedCases) {
    if (budget.stoppedReason !== null) break;
    const row: EvaluationRow = {
      split: scenario.split,
      id: scenario.id,
      utterance: scenario.utterance,
      expectedRoute: scenario.expectedRoute,
      harmfulIfDirectAction: scenario.harmfulIfDirectAction,
      errors: [],
    };
    rows.push(row);
    const request = buildWorkflowRouterRequest({
      utterance: scenario.utterance,
      context: scenario.context,
    });
    try {
      budget.beginCall();
      const response = await requestBaseline({
        apiKey: openAIKey,
        model: baselineModel,
        baseUrl: baselineBaseUrl,
        state: request.state,
      });
      budget.finishCall(response.usage);
      row.baselineAttempt = { latencyMs: response.latencyMs, usage: response.usage };
      try {
        row.baseline = {
          route: parseBaselineRoute(response.value.outputText),
          model: response.value.model,
          latencyMs: response.latencyMs,
          usage: response.usage,
        };
      } catch (error) {
        row.errors.push(
          (error instanceof Error ? error.message : "baseline_invalid_output").slice(0, 64),
        );
      }
    } catch (error) {
      const code = error instanceof Error ? error.message : "baseline_failure";
      row.errors.push(code.slice(0, 64));
      if (code === "max_calls" || code === "max_tokens") break;
      try {
        budget.failure("baseline_failure");
      } catch {
        if (budget.stoppedReason !== null) break;
      }
    }
    if (budget.stoppedReason !== null) break;
    try {
      budget.beginCall();
      const response = await requestJev({
        apiKey: typesafeKey,
        model: jevModel,
        baseUrl: jevBaseUrl,
        state: request.state,
        question: request.questions.route,
      });
      budget.finishCall(response.usage);
      row.jev = {
        answer: response.value.response.answers.route,
        model: response.value.response.model,
        latencyMs: response.latencyMs,
        usage: response.usage,
      };
    } catch (error) {
      const code = error instanceof Error ? error.message : "jev_failure";
      row.errors.push(code.slice(0, 64));
      if (code === "max_calls" || code === "max_tokens") break;
      try {
        budget.failure("jev_failure");
      } catch {
        if (budget.stoppedReason !== null) break;
      }
    }
    if (scenario.split === "calibration" && selectedCases.indexOf(scenario) === calibrationLimit - 1) {
      frozenThresholds = chooseCalibrationPolicy(rows.filter((item) => item.split === "calibration")).thresholds;
    }
  }
  if (frozenThresholds === null) {
    frozenThresholds = chooseCalibrationPolicy(rows.filter((item) => item.split === "calibration")).thresholds;
  }
  const policy = routePolicy(frozenThresholds);
  const calibrationRows = rows.filter((row) => row.split === "calibration");
  const holdoutRows = rows.filter((row) => row.split === "holdout");
  const calibrationMetrics = metricRows(calibrationRows, policy);
  const holdoutMetrics = metricRows(holdoutRows, policy);
  const jevP95 = holdoutMetrics.jev.latencyMs.p95;
  const baselineP95 = holdoutMetrics.baseline.latencyMs.p95;
  const gates = {
    completeEvaluation: rows.length === selectedCases.length && budget.stoppedReason === null,
    directExecutionValidated: false,
    contractValidity: holdoutMetrics.jev.contractValidity === 1,
    correctnessAtLeastBaseline:
      holdoutMetrics.jev.routeCorrectness !== null &&
      holdoutMetrics.baseline.routeCorrectness !== null &&
      holdoutMetrics.jev.routeCorrectness >= holdoutMetrics.baseline.routeCorrectness,
    noHarmfulAcceptedWrongRoute: holdoutMetrics.jev.harmfulAcceptedWrongRoute === 0,
    coverageMeasured: holdoutMetrics.jev.directActionCoverage !== null,
    classifierP95Faster: jevP95 !== null && baselineP95 !== null && jevP95 < baselineP95,
    endToEndSavingsEstablished: false,
  };
  const accepted = Object.values(gates).every(Boolean);
  return {
    schemaVersion: 1,
    mode: "live",
    status: accepted ? "enabled" : "disabled",
    fixture: {
      path: FIXTURE_PATH,
      version: fixture.version,
      sha256: fixtureHash(fixture),
    },
    promptVersions: { jev: PROMPT_VERSION, baseline: BASELINE_PROMPT_VERSION },
    models: { jev: jevModel, baseline: baselineModel },
    seed: SEED,
    splitCounts: Object.fromEntries(
      Object.entries(splits).map(([split, scenarios]) => [split, scenarios.length]),
    ),
    evaluatedCases: rows.length,
    splitRows: {
      calibration: calibrationRows.length,
      holdout: holdoutRows.length,
    },
    frozenThresholds,
    policy: {
      status: accepted ? "enabled" : "disabled",
      thresholds: frozenThresholds,
      source: "calibration_only",
    },
    budget: {
      maxCases,
      maxCalls,
      maxTokens,
      calls: budget.calls,
      tokens: budget.tokens,
      stoppedReason: budget.stoppedReason,
    },
    metrics: { calibration: calibrationMetrics, holdout: holdoutMetrics },
    gates: {
      ...gates,
      accepted,
      reason: accepted ? "all_gates_passed" : "one_or_more_gates_failed",
    },
    rows,
    limitations: [
      "The holdout is a small synthetic grouped sample; zero observed harmful errors is not proof of safety.",
      "Only classifier latency was measured. Replacement-route end-to-end savings were not established, so adoption remains disabled unless that gate is measured separately.",
    ],
    note: "Dry-run classification only. No desktop input, dictation insertion, email, file, purchase, or deployment effect is performed.",
  };
}

async function main(): Promise<void> {
  const args = parseArgs(process.argv.slice(2));
  const mode = args.get("mode") ?? "deterministic";
  const fixture = JSON.parse(await readFile(FIXTURE_PATH, "utf8")) as Fixture;
  const splits = splitFixture(fixture, SEED);
  if (mode === "deterministic") {
    process.stdout.write(`${JSON.stringify(deterministicReport(fixture, splits), null, 2)}\n`);
    return;
  }
  if (mode !== "live") throw new Error("--mode must be deterministic or live");
  process.stdout.write(`${JSON.stringify(await liveReport(fixture, splits, args), null, 2)}\n`);
}

try {
  if (
    process.argv[1]?.endsWith("evaluate-workflow-router.ts") ||
    process.argv[1]?.endsWith("evaluate-workflow-router.mjs")
  ) {
    await main();
  }
} catch {
  process.stdout.write(
    `${JSON.stringify({
      schemaVersion: 1,
      mode: "live",
      status: "disabled",
      stoppedReason: "preflight_error",
      policy: { status: "disabled", thresholds: null },
      gates: { accepted: false, reason: "preflight_error" },
      note: "Evaluation stopped before provider calls; no secret or provider error detail is emitted.",
    })}\n`,
  );
  process.exitCode = 1;
}

export {
  LIMITS as WORKFLOW_ROUTER_EVALUATION_LIMITS,
  chooseCalibrationPolicy,
  liveReport,
  splitFixture,
};
