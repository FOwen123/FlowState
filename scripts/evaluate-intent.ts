import { readFile } from "node:fs/promises";
import { createHash } from "node:crypto";
import { buildIntentQuestionsData } from "../convex/lib/intent_questions.ts";
import { parseStrictTypeSafeResponse } from "../convex/lib/strict_typesafe.ts";

type Scenario = {
  id: string;
  utterance: string;
  mode: "auto" | "commands" | "control";
  supportedActions: string[];
  supportedTools?: string[];
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
  "openURL",
  "attachFile",
  "sendEmail",
] as const;
const TOOLS = [
  "structuredIntegration",
  "nativeAccessibility",
  "visualComputerUse",
] as const;
const QUESTION_NAMES = [
  "intent",
  "app",
  "action",
  "tool",
  "target",
  "requiredSlots",
  "risk",
  "clarification",
] as const;
type QuestionName = (typeof QUESTION_NAMES)[number];
const PROMPT_VERSION = "intent-questions-v3";
const CANDIDATE_SET_VERSION = "fixture-candidates-v2";
const TYPESAFE_INPUT_COST_USD_PER_MILLION = 0.042;
const TYPESAFE_PRICING_SOURCE = "https://docs.typesafe.ai/models.md";
const TYPESAFE_PRICING_VERSION = "models.md-jev-1.13.0";
const DEFAULT_EVALUATION_ENV_FILE =
  "/Users/owen/Documents/Projects/FlowState/.env.local";

async function loadEvaluationEnv(): Promise<void> {
  const path =
    process.env.FLOWSTATE_EVALUATION_ENV_FILE ?? DEFAULT_EVALUATION_ENV_FILE;
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

async function requestTypeSafeStrict(
  apiKey: string,
  model: string,
  state: Record<string, unknown>,
  questions: Record<string, Record<string, unknown>>,
  strictQuestions: Record<string, { choices: readonly string[] }>,
) {
  const started = performance.now();
  const baseUrl = (
    process.env.TYPESAFE_BASE_URL ?? "https://api.typesafe.ai/v1"
  ).replace(/\/$/, "");
  let response: Response;
  try {
    response = await fetch(`${baseUrl}/systemone`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${apiKey}`,
        "Content-Type": "application/json",
      },
      signal: AbortSignal.timeout(30_000),
      body: JSON.stringify({ state, model, questions }),
    });
  } catch {
    throw new Error("typesafe request failed");
  }
  const modelLatencyMs = Math.max(0, performance.now() - started);
  if (!response.ok) {
    await response.body?.cancel();
    throw new Error(`typesafe provider status ${response.status}`);
  }
  const body = await response.text();
  if (body.length > 1_048_576) {
    throw new Error("typesafe response exceeds byte limit");
  }
  let value: unknown;
  try {
    value = JSON.parse(body) as unknown;
  } catch {
    throw new Error("typesafe provider returned invalid JSON");
  }
  return {
    parsed: parseStrictTypeSafeResponse(value, strictQuestions),
    modelLatencyMs,
  };
}

function estimatedTypeSafeCostUSD(
  usage: Record<string, number> | undefined,
): number | null {
  const inputTokens = usage?.input_tokens;
  if (
    typeof inputTokens !== "number" ||
    !Number.isFinite(inputTokens) ||
    inputTokens < 0
  ) {
    return null;
  }
  return (inputTokens / 1_000_000) * TYPESAFE_INPUT_COST_USD_PER_MILLION;
}

function typeSafePricing(model: string) {
  return {
    provider: "TypeSafe",
    model,
    inputUSDPerMillion: TYPESAFE_INPUT_COST_USD_PER_MILLION,
    outputUSDPerMillion: 0,
    source: TYPESAFE_PRICING_SOURCE,
    version: TYPESAFE_PRICING_VERSION,
  };
}

function supportedActionsForScenario(scenario: Scenario): string[] {
  return scenario.supportedActions.filter((action) =>
    ACTIONS.includes(action as (typeof ACTIONS)[number]),
  );
}

function supportedToolsForScenario(scenario: Scenario): string[] {
  if (scenario.supportedTools !== undefined) {
    return scenario.supportedTools.filter((tool) =>
      TOOLS.includes(tool as (typeof TOOLS)[number]),
    );
  }
  const tools = new Set<string>();
  const actions = supportedActionsForScenario(scenario);
  if (
    actions.some((action) =>
      ["openURL", "attachFile", "sendEmail"].includes(action),
    )
  ) {
    tools.add("structuredIntegration");
  }
  if (
    actions.some(
      (action) => !["openURL", "attachFile", "sendEmail"].includes(action),
    )
  ) {
    tools.add("nativeAccessibility");
  }
  if (scenario.screenshotRelevance === "needed") tools.add("visualComputerUse");
  if (tools.size === 0) tools.add("nativeAccessibility");
  return [...tools];
}

function targetCandidatesForScenario(
  scenario: Scenario,
): Array<{ id: string; kind?: string }> {
  const candidates = scenario.context.targetCandidates;
  if (!Array.isArray(candidates)) return [];
  return candidates.filter(
    (candidate): candidate is { id: string; kind?: string } =>
      typeof candidate === "object" &&
      candidate !== null &&
      typeof (candidate as { id?: unknown }).id === "string",
  );
}

function focusedAppBundleForScenario(scenario: Scenario): string | undefined {
  const bundle = scenario.context.focusedAppBundleIdentifier;
  return typeof bundle === "string" ? bundle : undefined;
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
    (scenario.expected.requiredClarification
      ? "clarify"
      : scenario.expected.intent)
  );
}

function expectedQuestionAnswers(
  scenario: Scenario,
): Record<QuestionName, string> {
  const action = scenario.expected.action;
  const isAction =
    scenario.expected.intent === "action" && action !== undefined;
  const tool = isAction
    ? ["openURL", "attachFile", "sendEmail"].includes(action)
      ? "structuredIntegration"
      : "nativeAccessibility"
    : "none";
  const app =
    scenario.expected.intent !== "action"
      ? "none"
      : action === "openApplication"
        ? (scenario.expected.target ?? "none")
        : focusedAppBundleForScenario(scenario) === undefined
          ? "none"
          : "focused";
  const requiredSlots = isAction
    ? scenario.expected.requiredClarification
      ? "missing"
      : "complete"
    : "missing";
  const risk =
    scenario.expected.intent !== "action"
      ? "unsupported"
      : scenario.riskClass === "approval-required"
        ? "confirm"
        : scenario.riskClass === "unsupported"
          ? "unsupported"
          : "reversible";
  return {
    intent: scenario.expected.intent,
    app,
    action: action ?? "none",
    tool,
    target: scenario.expected.target ?? "none",
    requiredSlots,
    risk,
    clarification:
      scenario.expected.intent === "unsupported"
        ? "abstain"
        : scenario.expected.requiredClarification
          ? "needed"
          : "notNeeded",
  };
}

type LatencySummary = {
  p50: number | null;
  p95: number | null;
  samples: number;
  note?: string;
};

function percentile(values: number[], percentileValue: number): number | null {
  if (values.length === 0) return null;
  const ordered = [...values].sort((a, b) => a - b);
  const index = Math.min(
    ordered.length - 1,
    Math.max(0, Math.ceil(ordered.length * percentileValue) - 1),
  );
  return ordered[index] ?? null;
}

function summarizeLatency(values: number[]): LatencySummary {
  return {
    p50: percentile(values, 0.5),
    p95: percentile(values, 0.95),
    samples: values.length,
    ...(values.length === 0
      ? { note: "No live latency is reported without measured rows." }
      : {}),
  };
}

function predictionAnswer(
  prediction: unknown,
  question: QuestionName,
): string | undefined {
  if (!prediction || typeof prediction !== "object") return undefined;
  const value = prediction as Record<string, unknown>;
  const answers = value.answers;
  if (answers && typeof answers === "object" && !Array.isArray(answers)) {
    const answer = (answers as Record<string, unknown>)[question];
    if (typeof answer === "string") return answer;
    if (
      answer &&
      typeof answer === "object" &&
      typeof (answer as { choice?: unknown }).choice === "string"
    ) {
      return (answer as { choice: string }).choice;
    }
  }
  const answer = value[question];
  return typeof answer === "string" ? answer : undefined;
}

function emptyQuestionMetrics(scenarios: Scenario[]) {
  return Object.fromEntries(
    QUESTION_NAMES.map((question) => [
      question,
      {
        samples: scenarios.length,
        predictions: 0,
        correct: null,
        accuracy: null,
        latencyMs: summarizeLatency([]),
        note: "No model accuracy is reported without predictions.",
      },
    ]),
  ) as Record<
    QuestionName,
    {
      samples: number;
      predictions: number;
      correct: number | null;
      accuracy: number | null;
      latencyMs: LatencySummary;
      note: string;
    }
  >;
}

function evaluateComparisonGate(
  candidate: { correctness: number | null; p95Ms: number | null },
  baseline: { correctness: number | null; p95Ms: number | null },
) {
  if (
    candidate.correctness === null ||
    candidate.p95Ms === null ||
    baseline.correctness === null ||
    baseline.p95Ms === null
  ) {
    return {
      status: "not_run" as const,
      accepted: false,
      reason: "live_comparison_required" as const,
    };
  }
  const correctnessAtLeastBaseline =
    candidate.correctness >= baseline.correctness;
  const p95Faster = candidate.p95Ms < baseline.p95Ms;
  return {
    status: "evaluated" as const,
    accepted: correctnessAtLeastBaseline && p95Faster,
    correctnessAtLeastBaseline,
    p95Faster,
    candidate,
    baseline,
  };
}

function questionMetrics(
  scenarios: Scenario[],
  predictions: Record<string, unknown> | null,
  measuredRows?: Array<Record<string, unknown>>,
) {
  const metrics = emptyQuestionMetrics(scenarios);
  if (predictions !== null) {
    for (const scenario of scenarios) {
      const prediction = predictions[scenario.id];
      for (const question of QUESTION_NAMES) {
        const actual = predictionAnswer(prediction, question);
        if (actual === undefined) continue;
        const metric = metrics[question];
        metric.predictions += 1;
        if (actual === expectedQuestionAnswers(scenario)[question]) {
          metric.correct = (metric.correct ?? 0) + 1;
        }
      }
    }
    for (const metric of Object.values(metrics)) {
      metric.accuracy =
        metric.predictions === 0
          ? null
          : (metric.correct ?? 0) / metric.predictions;
      metric.note =
        metric.predictions === 0
          ? "Predictions file contained no rows for this question."
          : "Measured against supplied predictions.";
    }
  }
  if (measuredRows !== undefined) {
    const latencies = new Map<QuestionName, number[]>();
    for (const row of measuredRows) {
      const latency = row.latencyMs;
      if (typeof latency !== "number" || !Number.isFinite(latency)) continue;
      for (const question of QUESTION_NAMES) {
        const values = latencies.get(question) ?? [];
        values.push(latency);
        latencies.set(question, values);
      }
    }
    for (const question of QUESTION_NAMES) {
      metrics[question].latencyMs = summarizeLatency(
        latencies.get(question) ?? [],
      );
    }
  }
  return metrics;
}

function emptyMetrics(scenarios: Scenario[]) {
  const byIntent = Object.fromEntries(
    ["action", "clarify", "unsupported"].map((intent) => [
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
    questionMetrics: emptyQuestionMetrics(scenarios),
    comparisonGate: evaluateComparisonGate(
      { correctness: null, p95Ms: null },
      { correctness: null, p95Ms: null },
    ),
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
        metrics.questionMetrics = questionMetrics(scenarios, predictions);
      }
      return [split, metrics];
    }),
  );
  return report;
}

function deterministicMainAnswers(scenario: Scenario): {
  answers: Record<QuestionName, string>;
  latencyMs: number;
} {
  const started = performance.now();
  const answers = expectedQuestionAnswers(scenario);
  return { answers, latencyMs: Math.max(0, performance.now() - started) };
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
  const baselineRows = selected.map((scenario) => {
    const baseline = deterministicMainAnswers(scenario);
    return { scenario, ...baseline };
  });
  const baseline = {
    samples: selected.length,
    exactChoiceCorrectness: selected.length === 0 ? 0 : 1,
    consequentialFalseExecution: 0,
    abstentionRate:
      selected.length === 0
        ? 0
        : baselineRows.filter((row) =>
            Object.values(row.answers).includes("abstain"),
          ).length / selected.length,
    modelLatencyMs: null,
    endToEndLatencyMs: summarizeLatency(
      baselineRows.map((row) => row.latencyMs),
    ),
    tokens: 0,
    costUSD: 0,
  };
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
    const supportedTools = supportedToolsForScenario(scenario);
    const supportedCapabilities = supportedCapabilitiesForScenario(scenario);
    const targetCandidates = targetCandidatesForScenario(scenario);
    const targetChoices = [
      "none",
      ...targetCandidates.map((candidate) => candidate.id),
    ];
    const builtQuestions = buildIntentQuestionsData({
      supportedActions,
      supportedTools,
      focusedAppBundleIdentifier: focusedAppBundleForScenario(scenario),
      targetCandidates,
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
    const started = performance.now();
    try {
      const result = await requestTypeSafeStrict(
        apiKey,
        model,
        {
          utterance: scenario.utterance,
          mode: scenario.mode,
          context: scenario.context,
          supportedActions,
          supportedTools,
          supportedCapabilities,
          policyVersion,
        },
        questions,
        strictQuestions,
      );
      const parsed = result.parsed;
      const intent = parsed.answers.intent;
      const app = parsed.answers.app;
      const action = parsed.answers.action;
      const tool = parsed.answers.tool;
      const target = parsed.answers.target;
      const requiredSlots = parsed.answers.requiredSlots;
      const risk = parsed.answers.risk;
      const clarification = parsed.answers.clarification;
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
      const measuredUsage = {
        ...usage,
        total_tokens:
          usage.total_tokens ?? usage.input_tokens + usage.output_tokens,
      };
      const callTokens = measuredUsage.total_tokens;
      tokens += callTokens;
      rows.push({
        id: scenario.id,
        expected: scenario.expected,
        actual: {
          intent: intent.choice,
          app: app.choice,
          action: action.choice,
          tool: tool.choice,
          target: target.choice,
          requiredSlots: requiredSlots.choice,
          risk: risk.choice,
          clarification: clarification.choice,
        },
        probabilities: {
          intent: intent.selectedProbability,
          app: app.selectedProbability,
          action: action.selectedProbability,
          tool: tool.selectedProbability,
          target: target.selectedProbability,
          requiredSlots: requiredSlots.selectedProbability,
          risk: risk.selectedProbability,
          clarification: clarification.selectedProbability,
        },
        topTwoMargin: {
          intent: intent.topTwoMargin,
          app: app.topTwoMargin,
          action: action.topTwoMargin,
          tool: tool.topTwoMargin,
          target: target.topTwoMargin,
          requiredSlots: requiredSlots.topTwoMargin,
          risk: risk.topTwoMargin,
          clarification: clarification.topTwoMargin,
        },
        confidence: {
          intent: intent.confidence,
          app: app.confidence,
          action: action.confidence,
          tool: tool.confidence,
          target: target.confidence,
          requiredSlots: requiredSlots.confidence,
          risk: risk.confidence,
          clarification: clarification.confidence,
        },
        model: parsed.model,
        promptVersion: PROMPT_VERSION,
        candidateSetVersion: CANDIDATE_SET_VERSION,
        supportedActions,
        supportedTools,
        supportedCapabilities,
        modelLatencyMs: result.modelLatencyMs,
        latencyMs: Math.max(0, performance.now() - started),
        usage: measuredUsage,
      });
      calls += 1;
      failures = 0;
    } catch (error) {
      rows.push({
        id: scenario.id,
        expected: scenario.expected,
        error: error instanceof Error ? error.message : "provider_error",
        latencyMs: Math.max(0, performance.now() - started),
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
  const validRows = rows.filter(
    (
      row,
    ): row is Record<string, unknown> & { actual: Record<string, string> } =>
      typeof row.actual === "object" && row.actual !== null,
  );
  const candidateCorrect = validRows.filter((row) => {
    const scenario = selected.find((item) => item.id === row.id);
    if (scenario === undefined) return false;
    const expected = expectedQuestionAnswers(scenario);
    return QUESTION_NAMES.every(
      (question) => row.actual[question] === expected[question],
    );
  }).length;
  const jev = {
    samples: selected.length,
    attempted: rows.length,
    contractValid: validRows.length,
    contractValidity: rows.length === 0 ? null : validRows.length / rows.length,
    exactChoiceCorrectness:
      validRows.length === 0 ? null : candidateCorrect / validRows.length,
    consequentialFalseExecution: 0,
    abstentionRate:
      validRows.length === 0
        ? null
        : validRows.filter((row) =>
            Object.values(row.actual).includes("abstain"),
          ).length / validRows.length,
    modelLatencyMs: summarizeLatency(
      validRows.flatMap((row) =>
        typeof row.modelLatencyMs === "number" ? [row.modelLatencyMs] : [],
      ),
    ),
    endToEndLatencyMs: summarizeLatency(
      validRows.flatMap((row) =>
        typeof row.latencyMs === "number" ? [row.latencyMs] : [],
      ),
    ),
    tokens: validRows.reduce(
      (total, row) =>
        total +
        (typeof (row.usage as { total_tokens?: unknown } | undefined)
          ?.total_tokens === "number"
          ? ((row.usage as { total_tokens: number }).total_tokens ?? 0)
          : 0),
      0,
    ),
    costUSD: (() => {
      const costs = validRows.flatMap((row) => {
        const cost = estimatedTypeSafeCostUSD(
          row.usage as Record<string, number> | undefined,
        );
        return cost === null ? [] : [cost];
      });
      return validRows.length > 0 && costs.length === validRows.length
        ? costs.reduce((total, cost) => total + cost, 0)
        : null;
    })(),
  };
  const comparisonGate = stageComparison(
    {
      exactChoiceCorrectness: baseline.exactChoiceCorrectness,
      endToEndLatencyMs: baseline.endToEndLatencyMs,
    },
    jev,
  );
  return {
    mode: "live",
    split: args.get("split") ?? "development",
    pricing: typeSafePricing(model),
    budget: { maxCases, maxCalls, maxTokens },
    calls,
    tokens,
    stoppedReason: stoppedReason ?? null,
    rows,
    baseline,
    jev,
    questionMetrics: questionMetrics(
      selected,
      Object.fromEntries(
        rows
          .filter((row) => row.actual !== undefined)
          .map((row) => [row.id, row.actual]),
      ),
      rows,
    ),
    comparisonGate,
    providerFailures: rows.flatMap((row) =>
      typeof row.error === "string"
        ? [{ id: String(row.id), error: row.error }]
        : [],
    ),
    automaticExecution: false,
    reference:
      "Historical v2 reports are retained as a non-equivalent reference; this gate compares v3 Jev with the deterministic in-process baseline.",
    note: "Live evaluation routes only; no desktop, email, file or deployment effects are performed.",
  };
}

type StageScenario = {
  id: string;
  utterance: string;
  answers: Record<string, string>;
  baseline: Record<string, string>;
  consequential: boolean;
};

type StageGroup = { id: string; scenarios: StageScenario[] };
type StageSuite = {
  id: string;
  stage: string;
  questions: Record<string, string[]>;
  groups: StageGroup[];
};
type StageFixture = {
  version: number;
  language: string;
  policyVersion: string;
  notes?: string;
  suites: StageSuite[];
};

const STAGE_SUITE_IDS = [
  "missing-slots-risk",
  "plan-step-validation",
  "memory-ranking",
  "result-validation",
  "route-model-selection",
] as const;

function resolveStageSuite(value: string, fixture: StageFixture): StageSuite {
  const normalized = value.toLocaleLowerCase();
  const index = /^[a-e]$/.test(normalized)
    ? normalized.charCodeAt(0) - "a".charCodeAt(0)
    : -1;
  const id = index >= 0 ? STAGE_SUITE_IDS[index] : normalized;
  const suite = fixture.suites.find((candidate) => candidate.id === id);
  if (suite === undefined) {
    throw new Error(`unknown Jev stage suite: ${value}`);
  }
  for (const [question, choices] of Object.entries(suite.questions)) {
    if (
      choices.length === 0 ||
      choices.length > 255 ||
      new Set(choices).size !== choices.length ||
      choices.some((choice) => choice.length === 0 || choice.length > 128)
    ) {
      throw new Error(`stage question choices are invalid for ${question}`);
    }
  }
  for (const group of suite.groups) {
    for (const scenario of group.scenarios) {
      for (const [question, answer] of Object.entries(scenario.answers)) {
        if (!suite.questions[question]?.includes(answer)) {
          throw new Error(`stage answer is not registered for ${question}`);
        }
      }
      for (const [question, answer] of Object.entries(scenario.baseline)) {
        if (!suite.questions[question]?.includes(answer)) {
          throw new Error(`stage baseline is not registered for ${question}`);
        }
      }
    }
  }
  return suite;
}

function splitStageGroups(
  groups: StageGroup[],
  seed: number,
): Record<Split, StageScenario[]> {
  const result: Record<Split, StageScenario[]> = {
    development: [],
    calibration: [],
    holdout: [],
  };
  const ordered = [...groups].sort(
    (a, b) => hash(`${seed}:${a.id}`) - hash(`${seed}:${b.id}`),
  );
  const developmentCount = Math.max(1, Math.round(ordered.length * 0.5));
  const calibrationCount = Math.max(1, Math.round(ordered.length * 0.25));
  for (const [index, group] of ordered.entries()) {
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
  return result;
}

function emptyStageLatency() {
  return { p50: null, p95: null, samples: 0 };
}

function stageComparisonGate(hasPredictions: boolean) {
  return hasPredictions
    ? {
        status: "failed" as const,
        accepted: false,
        reason: "baseline_latency_unavailable" as const,
      }
    : {
        status: "not_run" as const,
        accepted: false,
        reason: "live_comparison_required" as const,
      };
}

function stageMetrics(
  scenarios: StageScenario[],
  questions: Record<string, string[]>,
  predictions: Record<string, unknown> | null,
) {
  const questionMetrics = Object.fromEntries(
    Object.keys(questions).map((question) => [
      question,
      {
        samples: scenarios.filter(
          (scenario) => scenario.answers[question] !== undefined,
        ).length,
        predictions: 0,
        correct: null as number | null,
        accuracy: null as number | null,
        modelLatencyMs: emptyStageLatency(),
        endToEndLatencyMs: emptyStageLatency(),
        tokens: null as number | null,
        costUSD: null as number | null,
      },
    ]),
  ) as Record<
    string,
    {
      samples: number;
      predictions: number;
      correct: number | null;
      accuracy: number | null;
      modelLatencyMs: ReturnType<typeof emptyStageLatency>;
      endToEndLatencyMs: ReturnType<typeof emptyStageLatency>;
      tokens: number | null;
      costUSD: number | null;
    }
  >;
  let correct = 0;
  let predicted = 0;
  let consequentialFalseExecution = 0;
  let abstentions = 0;
  if (predictions !== null) {
    for (const scenario of scenarios) {
      const prediction = predictions[scenario.id];
      if (!prediction || typeof prediction !== "object") continue;
      const value = prediction as Record<string, unknown>;
      const answers =
        value.answers && typeof value.answers === "object"
          ? (value.answers as Record<string, unknown>)
          : value;
      let scenarioCorrect = true;
      for (const question of Object.keys(questions)) {
        const answer = answers[question];
        const actual =
          typeof answer === "string"
            ? answer
            : answer &&
                typeof answer === "object" &&
                typeof (answer as { choice?: unknown }).choice === "string"
              ? (answer as { choice: string }).choice
              : undefined;
        if (actual === undefined) continue;
        const metric = questionMetrics[question];
        metric.predictions += 1;
        predicted += 1;
        if (actual === scenario.answers[question]) {
          metric.correct = (metric.correct ?? 0) + 1;
        } else {
          scenarioCorrect = false;
        }
        if (actual === "abstain") abstentions += 1;
      }
      if (
        !scenarioCorrect &&
        scenario.consequential &&
        value.executed === true
      ) {
        consequentialFalseExecution += 1;
      }
    }
    for (const metric of Object.values(questionMetrics)) {
      metric.accuracy =
        metric.predictions === 0
          ? null
          : (metric.correct ?? 0) / metric.predictions;
    }
    correct = Object.values(questionMetrics).reduce(
      (total, metric) => total + (metric.correct ?? 0),
      0,
    );
  }
  return {
    samples: scenarios.length,
    questionMetrics,
    exactChoiceCorrectness: predicted === 0 ? null : correct / predicted,
    consequentialFalseExecution:
      predictions === null ? null : consequentialFalseExecution,
    abstentionRate: predicted === 0 ? null : abstentions / predicted,
    modelLatencyMs: emptyStageLatency(),
    endToEndLatencyMs: emptyStageLatency(),
    tokens: null,
    costUSD: null,
    baseline: {
      exactChoiceCorrectness: scenarios.length === 0 ? null : 1,
      modelLatencyMs: null,
      endToEndLatencyMs: null,
      tokens: null,
      costUSD: null,
    },
    comparisonGate: stageComparisonGate(predictions !== null),
    note:
      predictions === null
        ? "No model accuracy, latency, token, cost, or comparison result is reported without a bounded live run."
        : "Predictions were supplied, but the baseline has no measured latency; this stage is not shippable.",
  };
}

const STAGE_PROMPT_VERSION = "jev-stage-questions-v1";

type StageLiveRow = {
  id: string;
  baselineAnswers: Record<string, string>;
  actualAnswers?: Record<string, string>;
  contractValid: boolean;
  modelLatencyMs?: number;
  endToEndLatencyMs: number;
  usage?: Record<string, number>;
  error?: string;
  executed: false;
};

function stageQuestionPayload(suite: StageSuite) {
  const questions = Object.fromEntries(
    Object.entries(suite.questions).map(([question, choices]) => [
      question,
      {
        type: "choice" as const,
        instructions:
          `Jev stage ${suite.stage}: choose exactly one registered answer for ${question}. ` +
          "This is a dry-run evaluation; never execute an action or treat confidence as permission.",
        criteria: Object.fromEntries(
          choices.map((choice) => [
            choice,
            `The bounded stage answer is ${choice}.`,
          ]),
        ),
      },
    ]),
  );
  const strictQuestions = Object.fromEntries(
    Object.entries(suite.questions).map(([question, choices]) => [
      question,
      { choices },
    ]),
  );
  return { questions, strictQuestions };
}

function deterministicRouteSelection(
  route: string,
): "structuredIntegration" | "nativeAccessibility" | "visualComputerUse" {
  if (route === "structuredIntegration") return "structuredIntegration";
  if (route === "nativeAccessibility") return "nativeAccessibility";
  if (route === "visualComputerUse") return "visualComputerUse";
  throw new Error("no supported execution route");
}

function deterministicStageAnswers(
  suite: StageSuite,
  scenario: StageScenario,
): Record<string, string> {
  const answers = Object.fromEntries(
    Object.keys(suite.questions).map((question) => {
      const answer = scenario.baseline[question];
      if (
        answer === undefined ||
        !suite.questions[question]?.includes(answer)
      ) {
        throw new Error(`baseline answer is missing for ${question}`);
      }
      return [question, answer];
    }),
  );

  // The fixture baseline is the registered deterministic answer. Stage B's
  // bounded step-validation contract is checked by the backend contract
  // suite; the evaluator keeps this dry-run selector side-effect free.
  if (suite.stage === "E" && answers.route !== undefined) {
    if (answers.route === "unsupported") {
      // An unavailable route is the deterministic unsupported outcome.
    } else {
      const selected = deterministicRouteSelection(answers.route);
      if (selected !== answers.route) {
        throw new Error("deterministic route selector disagrees with baseline");
      }
    }
  }
  return answers;
}

function stageQuestionMetrics(
  suite: StageSuite,
  selected: StageScenario[],
  rows: StageLiveRow[],
) {
  return Object.fromEntries(
    Object.keys(suite.questions).map((question) => {
      const validRows = rows.filter(
        (row) =>
          row.contractValid && row.actualAnswers?.[question] !== undefined,
      );
      const correct = validRows.filter(
        (row) =>
          row.actualAnswers?.[question] === row.baselineAnswers[question],
      ).length;
      const costs = validRows.flatMap((row) =>
        estimatedTypeSafeCostUSD(row.usage) === null
          ? []
          : [estimatedTypeSafeCostUSD(row.usage) as number],
      );
      return [
        question,
        {
          samples: selected.length,
          predictions: validRows.length,
          correct: validRows.length === 0 ? null : correct,
          accuracy: validRows.length === 0 ? null : correct / validRows.length,
          modelLatencyMs: summarizeLatency(
            validRows.flatMap((row) =>
              row.modelLatencyMs === undefined ? [] : [row.modelLatencyMs],
            ),
          ),
          endToEndLatencyMs: summarizeLatency(
            validRows.map((row) => row.endToEndLatencyMs),
          ),
          tokens: validRows.reduce(
            (total, row) => total + (row.usage?.total_tokens ?? 0),
            0,
          ),
          costUSD:
            validRows.length > 0 && costs.length === validRows.length
              ? costs.reduce((total, cost) => total + cost, 0)
              : null,
        },
      ];
    }),
  );
}

function stageComparison(
  baseline: {
    exactChoiceCorrectness: number;
    endToEndLatencyMs: LatencySummary;
  },
  jev: {
    contractValidity: number | null;
    exactChoiceCorrectness: number | null;
    consequentialFalseExecution: number;
    endToEndLatencyMs: LatencySummary;
  },
) {
  const conditions = {
    contractValid: jev.contractValidity === 1,
    noConsequentialFalseExecution: jev.consequentialFalseExecution === 0,
    correctnessAtLeastBaseline:
      jev.exactChoiceCorrectness !== null &&
      jev.exactChoiceCorrectness >= baseline.exactChoiceCorrectness,
    p95Faster:
      jev.endToEndLatencyMs.p95 !== null &&
      baseline.endToEndLatencyMs.p95 !== null &&
      jev.endToEndLatencyMs.p95 < baseline.endToEndLatencyMs.p95,
  };
  const reason = conditions.contractValid
    ? conditions.noConsequentialFalseExecution
      ? conditions.correctnessAtLeastBaseline
        ? conditions.p95Faster
          ? "all_release_gates_passed"
          : "p95_not_faster_than_deterministic_baseline"
        : "correctness_below_deterministic_baseline"
      : "consequential_false_execution"
    : "contract_validity_below_100_percent";
  return {
    status: "evaluated" as const,
    accepted: Object.values(conditions).every(Boolean),
    reason,
    ...conditions,
  };
}

async function liveStageReport(
  fixture: StageFixture,
  suite: StageSuite,
  scenarios: StageScenario[],
  split: Split,
  maxCalls: number,
  maxTokens: number,
  maxCases: number,
  seed: number,
  fixtureHash: string,
) {
  const apiKey = process.env.TYPESAFE_API_KEY;
  const model = process.env.FLOWSTATE_JEV_MODEL;
  if (!apiKey || !model) {
    throw new Error(
      "TYPESAFE_API_KEY and FLOWSTATE_JEV_MODEL are required for live evaluation",
    );
  }
  const selected = scenarios.slice(0, maxCases);
  const allSplits = splitStageGroups(suite.groups, seed);
  const baselineRows = selected.map((scenario) => {
    const started = performance.now();
    const baselineAnswers = deterministicStageAnswers(suite, scenario);
    return {
      scenario,
      baselineAnswers,
      latencyMs: Math.max(0, performance.now() - started),
    };
  });
  const baselineLatency = summarizeLatency(
    baselineRows.map((row) => row.latencyMs),
  );
  const baselineCorrect = baselineRows.filter((row) =>
    Object.keys(suite.questions).every(
      (question) =>
        row.baselineAnswers[question] === row.scenario.answers[question],
    ),
  ).length;
  const baseline = {
    samples: selected.length,
    exactChoiceCorrectness:
      selected.length === 0 ? 0 : baselineCorrect / selected.length,
    consequentialFalseExecution: 0,
    abstentionRate:
      selected.length === 0
        ? 0
        : baselineRows.filter((row) =>
            Object.values(row.baselineAnswers).includes("abstain"),
          ).length / selected.length,
    modelLatencyMs: null,
    endToEndLatencyMs: baselineLatency,
    tokens: 0,
    costUSD: 0,
  };

  const { questions, strictQuestions } = stageQuestionPayload(suite);
  const rows: StageLiveRow[] = [];
  const providerFailures: Array<{ id: string; error: string }> = [];
  let calls = 0;
  let tokens = 0;
  let stoppedReason: string | undefined;
  for (const baselineRow of baselineRows) {
    if (calls >= maxCalls) {
      stoppedReason = "max_calls";
      break;
    }
    if (tokens >= maxTokens) {
      stoppedReason = "max_tokens";
      break;
    }
    const scenario = baselineRow.scenario;
    const state = {
      utterance: scenario.utterance,
      stage: suite.stage,
      suite: suite.id,
      policyVersion: fixture.policyVersion,
      dryRun: true,
    };
    const estimatedTokens = Math.ceil(
      JSON.stringify({ state, questions }).length / 4,
    );
    if (tokens + estimatedTokens > maxTokens) {
      stoppedReason = "preflight_token_budget";
      break;
    }
    const endToEndStarted = performance.now();
    let modelLatencyMs: number | undefined;
    try {
      const result = await requestTypeSafeStrict(
        apiKey,
        model,
        state,
        questions,
        strictQuestions,
      );
      modelLatencyMs = result.modelLatencyMs;
      const parsed = result.parsed;
      if (parsed.model !== model) throw new Error("provider model mismatch");
      const usage = parsed.usage;
      if (
        usage?.input_tokens === undefined ||
        usage.output_tokens === undefined
      ) {
        throw new Error(
          "provider usage is missing; token budget cannot be enforced",
        );
      }
      const measuredUsage = {
        ...usage,
        total_tokens:
          usage.total_tokens ?? usage.input_tokens + usage.output_tokens,
      };
      if (tokens + measuredUsage.total_tokens > maxTokens) {
        stoppedReason = "max_tokens";
        break;
      }
      tokens += measuredUsage.total_tokens;
      rows.push({
        id: scenario.id,
        baselineAnswers: baselineRow.baselineAnswers,
        actualAnswers: Object.fromEntries(
          Object.entries(parsed.answers).map(([question, answer]) => [
            question,
            answer.choice,
          ]),
        ),
        contractValid: true,
        modelLatencyMs,
        endToEndLatencyMs: Math.max(0, performance.now() - endToEndStarted),
        usage: measuredUsage,
        executed: false,
      });
      calls += 1;
    } catch (error) {
      const message =
        error instanceof Error ? error.message.slice(0, 240) : "provider_error";
      providerFailures.push({ id: scenario.id, error: message });
      rows.push({
        id: scenario.id,
        baselineAnswers: baselineRow.baselineAnswers,
        contractValid: false,
        ...(modelLatencyMs === undefined ? {} : { modelLatencyMs }),
        endToEndLatencyMs: Math.max(0, performance.now() - endToEndStarted),
        error: message,
        executed: false,
      });
      calls += 1;
      if (providerFailures.length >= 3) {
        stoppedReason = "repeated_provider_failures";
        break;
      }
    }
  }
  const validRows = rows.filter((row) => row.contractValid);
  const exactCorrect = validRows.filter((row) =>
    Object.keys(suite.questions).every(
      (question) =>
        row.actualAnswers?.[question] ===
        selected.find((scenario) => scenario.id === row.id)?.answers[question],
    ),
  ).length;
  const jev = {
    samples: selected.length,
    attempted: rows.length,
    contractValid: validRows.length,
    contractValidity: rows.length === 0 ? null : validRows.length / rows.length,
    exactChoiceCorrectness:
      validRows.length === 0 ? null : exactCorrect / validRows.length,
    consequentialFalseExecution: 0,
    abstentionRate:
      validRows.length === 0
        ? null
        : validRows.filter((row) =>
            Object.values(row.actualAnswers ?? {}).includes("abstain"),
          ).length / validRows.length,
    modelLatencyMs: summarizeLatency(
      validRows.flatMap((row) =>
        row.modelLatencyMs === undefined ? [] : [row.modelLatencyMs],
      ),
    ),
    endToEndLatencyMs: summarizeLatency(
      validRows.map((row) => row.endToEndLatencyMs),
    ),
    tokens: validRows.reduce(
      (total, row) => total + (row.usage?.total_tokens ?? 0),
      0,
    ),
    costUSD: (() => {
      const costs = validRows.flatMap((row) =>
        estimatedTypeSafeCostUSD(row.usage) === null
          ? []
          : [estimatedTypeSafeCostUSD(row.usage) as number],
      );
      return validRows.length > 0 && costs.length === validRows.length
        ? costs.reduce((total, cost) => total + cost, 0)
        : null;
    })(),
  };
  const metrics = {
    samples: selected.length,
    baseline,
    jev,
    questionMetrics: stageQuestionMetrics(suite, selected, rows),
    comparisonGate: stageComparison(
      {
        exactChoiceCorrectness: baseline.exactChoiceCorrectness,
        endToEndLatencyMs: baseline.endToEndLatencyMs,
      },
      jev,
    ),
    dryRun: true,
  };
  return {
    mode: "live",
    suite: suite.id,
    stage: suite.stage,
    split,
    seed,
    fixture: {
      version: fixture.version,
      language: fixture.language,
      policyVersion: fixture.policyVersion,
      sha256: fixtureHash,
      groups: suite.groups.length,
      scenarios: suite.groups.reduce(
        (total, group) => total + group.scenarios.length,
        0,
      ),
    },
    splitCounts: Object.fromEntries(
      Object.entries(allSplits).map(([name, splitScenarios]) => [
        name,
        splitScenarios.length,
      ]),
    ),
    familyIsolation: {
      groups: suite.groups.length,
      holdoutGroups: allSplits.holdout.length > 0 ? 1 : 0,
      note:
        suite.groups.length <= 4
          ? "The untouched holdout is one independent family in this bounded fixture."
          : "Groups remain intact across splits.",
    },
    prompt: {
      version: STAGE_PROMPT_VERSION,
      questionsFrozen: true,
      thresholdsFrozen: true,
    },
    pricing: typeSafePricing(model),
    budget: { maxCases, maxCalls, maxTokens },
    cases: selected.length,
    evaluatedCases: rows.length,
    calls,
    tokens,
    stoppedReason: stoppedReason ?? null,
    providerFailures,
    rows,
    metrics: { [split]: metrics },
    status: "disabled",
    automaticExecution: false,
    note: "Live Jev is measured in a dry run only. Automatic execution remains disabled unless every release gate passes.",
  };
}

function stageReport(
  fixture: StageFixture,
  suite: StageSuite,
  splits: Record<Split, StageScenario[]>,
  predictions: Record<string, unknown> | null,
  seed: number,
  fixtureHash: string,
) {
  return {
    mode: "deterministic",
    suite: suite.id,
    stage: suite.stage,
    seed,
    fixture: {
      version: fixture.version,
      language: fixture.language,
      policyVersion: fixture.policyVersion,
      sha256: fixtureHash,
      groups: suite.groups.length,
      scenarios: suite.groups.reduce(
        (total, group) => total + group.scenarios.length,
        0,
      ),
    },
    splitCounts: Object.fromEntries(
      Object.entries(splits).map(([name, scenarios]) => [
        name,
        scenarios.length,
      ]),
    ),
    metrics: Object.fromEntries(
      (Object.keys(splits) as Split[]).map((split) => [
        split,
        stageMetrics(splits[split], suite.questions, predictions),
      ]),
    ),
    status: "disabled",
    note: "Named Jev stage is disabled until its real baseline comparison passes the release gate; no live result is fabricated.",
  };
}

await loadEvaluationEnv();

const args = parseArgs(process.argv.slice(2));
const suiteArgument = args.get("suite");
const fixturePath =
  args.get("fixture") ??
  (suiteArgument === undefined
    ? "tests/fixtures/intent/en.json"
    : "tests/fixtures/control-decisions/en.json");
const fixtureText = await readFile(fixturePath, "utf8");
const fixtureHash = createHash("sha256").update(fixtureText).digest("hex");
const seed = Number(args.get("seed") ?? "17");
if (!Number.isInteger(seed)) throw new Error("--seed must be an integer");
const mode = args.get("mode") ?? "deterministic";
const predictionPath = args.get("predictions");
const predictions =
  predictionPath === undefined
    ? null
    : (JSON.parse(await readFile(predictionPath, "utf8")) as Record<
        string,
        unknown
      >);

if (suiteArgument !== undefined) {
  const fixture = JSON.parse(fixtureText) as StageFixture;
  const suite = resolveStageSuite(suiteArgument, fixture);
  const splits = splitStageGroups(suite.groups, seed);
  if (mode === "deterministic") {
    console.log(
      JSON.stringify(
        stageReport(fixture, suite, splits, predictions, seed, fixtureHash),
        null,
        2,
      ),
    );
  } else if (mode === "live") {
    const splitArgument = args.get("split");
    if (splitArgument === undefined || !(splitArgument in splits)) {
      throw new Error(
        "--split must be development, calibration or holdout for a live stage",
      );
    }
    const maxCases = positiveInteger(args, "max-cases", true);
    const maxCalls = positiveInteger(args, "max-calls", true);
    const maxTokens = positiveInteger(args, "max-tokens", true);
    const report = await liveStageReport(
      fixture,
      suite,
      splits[splitArgument as Split],
      splitArgument as Split,
      maxCalls,
      maxTokens,
      maxCases,
      seed,
      fixtureHash,
    );
    console.log(JSON.stringify(report, null, 2));
  } else {
    throw new Error("--mode must be deterministic or live");
  }
} else {
  const fixture = JSON.parse(fixtureText) as Fixture;
  const splits = splitGroups(fixture.groups, seed);
  const split = (args.get("split") ?? "development") as Split;
  if (!(split in splits))
    throw new Error("--split must be development, calibration or holdout");
  if (mode === "deterministic") {
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
}
