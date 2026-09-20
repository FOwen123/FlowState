import { createHash } from "node:crypto";
import { readFile, mkdir, writeFile } from "node:fs/promises";
import { dirname, relative, resolve } from "node:path";

import {
  FALLBACK_EVALUATION_LIMITS,
  INTENT_FALLBACK_PROMPT_VERSION,
  buildIntentFallbackRequest,
  parseIntentFallbackOutput,
  validateFallbackEvaluationBudget,
  type ParsedIntentFallback,
} from "../convex/lib/intent_fallback";
import { ProviderError } from "../convex/lib/http";
import { splitIntentScenarios } from "../convex/lib/intent_policy";
import {
  createOpenAIClient,
  type OpenAIResponseResult,
} from "../convex/lib/openai";

export const FROZEN_JEV_THRESHOLDS = Object.freeze({
  minimumSelectedProbability: 0.5,
  minimumTopTwoMargin: 0.8,
  minimumConfidence: 0.5,
});

const DEFAULT_MAX_CASES = 8;
const FALLBACK_MAX_OUTPUT_TOKENS = 1_024;
const FROZEN_JEV_REPORTS = Object.freeze({
  development: "/tmp/intent-development-prompt-v2.json",
  calibration: "/tmp/intent-calibration-v2.json",
  holdout: "/tmp/intent-holdout-v2.json",
});

type IntentName = "dictation" | "action" | "clarify" | "unsupported";

export type EvaluationExpected = {
  intent: IntentName | string;
  action?: string;
  target?: string;
  requiredClarification?: boolean;
};

type EvaluationExpectedInput =
  EvaluationExpected | { expected: EvaluationExpected };

export type EvaluationPrediction = {
  intent?: string;
  action?: string;
  target?: string;
  actionKind?: string;
  targetId?: string;
  decision?: string;
  requiresApproval?: boolean;
};

export type EvaluationMeasurement = {
  prediction?: EvaluationPrediction;
  source?: string;
  error?: string;
  errorClass?:
    | "provider_error"
    | "provider_response_invalid"
    | "usage_error"
    | "fallback_output_invalid";
  skipped?: string;
  usage?: { input_tokens: number; output_tokens: number; total_tokens: number };
  latencyMs?: number;
};

export type EvaluationRow = {
  expected: EvaluationExpected;
  baseline?: EvaluationMeasurement;
  cascade?: EvaluationMeasurement;
  vision?: EvaluationMeasurement;
};

type Scenario = {
  id: string;
  utterance: string;
  mode: "auto" | "dictation" | "commands";
  supportedActions: string[];
  permissibleIntents?: string[];
  expected: EvaluationExpected & { arguments?: Record<string, unknown> };
  context: Record<string, unknown>;
  grantState: Array<Record<string, unknown>>;
  screenshotRelevance: string;
  riskClass?: string;
  [key: string]: unknown;
};

type Fixture = {
  version: number;
  language: string;
  policyVersion: string;
  groups: Array<{ id: string; category?: string; scenarios: Scenario[] }>;
};

type FrozenJevValues = {
  intent: number;
  action?: number;
  target?: number;
};

export type FrozenJevRow = {
  id: string;
  expected?: EvaluationExpected;
  actual?: EvaluationPrediction;
  probabilities?: FrozenJevValues;
  topTwoMargin?: FrozenJevValues;
  confidence?: FrozenJevValues;
  model?: string;
};

type FrozenReport = {
  mode?: string;
  split?: string;
  rows: FrozenJevRow[];
  calls?: number;
  tokens?: number;
  budget?: Record<string, number>;
};

type SelectedCase = {
  scenario: Scenario;
  role:
    | "high_confidence_wrong_intent"
    | "dictation"
    | "keys"
    | "ambiguous"
    | "unsupported"
    | "vision";
  visionFixture?: string;
};

type CliArgs = {
  mode: "live" | "deterministic";
  fixture: string;
  output: string;
  seed: number;
  maxCases: number;
  maxCalls: number;
  maxTokens: number;
  devReport: string;
  calibrationReport: string;
  holdoutReport: string;
};

type Usage = {
  input_tokens: number;
  output_tokens: number;
  total_tokens: number;
};

type CallBudget = {
  maxCalls: number;
  maxTokens: number;
  calls: number;
  tokens: number;
  consecutiveFailures: number;
  stoppedReason?: string;
};

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function readFiniteNumber(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value)
    ? value
    : undefined;
}

function boundedNumber(value: unknown, label: string): number {
  const result = readFiniteNumber(value);
  if (result === undefined || result < 0 || result > 1) {
    throw new Error(`${label} must be a number between 0 and 1`);
  }
  return result;
}

function values(value: unknown, label: string): FrozenJevValues {
  if (!isRecord(value)) throw new Error(`${label} is missing`);
  const intent = boundedNumber(value.intent, `${label}.intent`);
  const action =
    value.action === undefined
      ? undefined
      : boundedNumber(value.action, `${label}.action`);
  const target =
    value.target === undefined
      ? undefined
      : boundedNumber(value.target, `${label}.target`);
  return {
    intent,
    ...(action === undefined ? {} : { action }),
    ...(target === undefined ? {} : { target }),
  };
}

function prediction(value: unknown, label: string): EvaluationPrediction {
  if (!isRecord(value)) throw new Error(`${label} is missing`);
  const result: EvaluationPrediction = {};
  for (const key of [
    "intent",
    "action",
    "target",
    "actionKind",
    "targetId",
    "decision",
  ] as const) {
    if (value[key] !== undefined && typeof value[key] !== "string") {
      throw new Error(`${label}.${key} must be text`);
    }
    if (typeof value[key] === "string") result[key] = value[key];
  }
  if (value.requiresApproval !== undefined) {
    if (typeof value.requiresApproval !== "boolean")
      throw new Error(`${label}.requiresApproval must be boolean`);
    result.requiresApproval = value.requiresApproval;
  }
  return result;
}

function parseFrozenRow(value: unknown): FrozenJevRow {
  if (!isRecord(value) || typeof value.id !== "string")
    throw new Error("frozen Jev row is invalid");
  return {
    id: value.id,
    ...(value.expected === undefined
      ? {}
      : { expected: predictionExpected(value.expected, "expected") }),
    ...(value.actual === undefined
      ? {}
      : { actual: prediction(value.actual, "actual") }),
    ...(value.probabilities === undefined
      ? {}
      : { probabilities: values(value.probabilities, "probabilities") }),
    ...(value.topTwoMargin === undefined
      ? {}
      : { topTwoMargin: values(value.topTwoMargin, "topTwoMargin") }),
    ...(value.confidence === undefined
      ? {}
      : { confidence: values(value.confidence, "confidence") }),
    ...(typeof value.model === "string" ? { model: value.model } : {}),
  };
}

function predictionExpected(value: unknown, label: string): EvaluationExpected {
  if (!isRecord(value) || typeof value.intent !== "string")
    throw new Error(`${label} is invalid`);
  return {
    intent: value.intent,
    ...(typeof value.action === "string" ? { action: value.action } : {}),
    ...(typeof value.target === "string" ? { target: value.target } : {}),
    ...(typeof value.requiredClarification === "boolean"
      ? { requiredClarification: value.requiredClarification }
      : {}),
  };
}

function normalizePrediction(
  value: EvaluationPrediction,
): EvaluationPrediction {
  const intent = value.intent;
  const action = value.action ?? value.actionKind;
  const target = value.target ?? value.targetId;
  return {
    ...(intent === undefined ? {} : { intent }),
    ...(action === undefined ? {} : { action }),
    ...(target === undefined ? {} : { target }),
    ...(value.decision === undefined ? {} : { decision: value.decision }),
    ...(value.requiresApproval === undefined
      ? {}
      : { requiresApproval: value.requiresApproval }),
  };
}

/** Compare only the registered intent/action/target; review is not execution. */
export function compareEvaluationPrediction(
  expectedInput: EvaluationExpectedInput,
  actual: EvaluationPrediction,
): boolean {
  const expected =
    "expected" in expectedInput ? expectedInput.expected : expectedInput;
  const normalized = normalizePrediction(actual);
  if (normalized.intent !== expected.intent) return false;
  if (expected.action !== undefined && normalized.action !== expected.action)
    return false;
  if (expected.target !== undefined && normalized.target !== expected.target)
    return false;
  if (
    expected.intent === "clarify" &&
    normalized.decision !== undefined &&
    normalized.decision !== "clarify"
  ) {
    return false;
  }
  if (
    expected.intent === "unsupported" &&
    normalized.decision !== undefined &&
    normalized.decision !== "unsupported"
  ) {
    return false;
  }
  if (
    expected.intent === "dictation" &&
    normalized.decision !== undefined &&
    normalized.decision !== "dictation"
  ) {
    return false;
  }
  return true;
}

/** Apply the frozen .5 probability, .8 margin and .5 confidence gates. */
export function frozenJevGate(
  row: Pick<
    FrozenJevRow,
    "actual" | "probabilities" | "topTwoMargin" | "confidence"
  >,
): boolean {
  const actual = row.actual;
  if (actual?.intent === undefined) return false;
  const stages =
    actual.intent === "action"
      ? (["intent", "action", "target"] as const)
      : (["intent"] as const);
  return stages.every((stage) => {
    const probability = row.probabilities?.[stage];
    const margin = row.topTwoMargin?.[stage];
    const confidence = row.confidence?.[stage];
    return (
      probability !== undefined &&
      margin !== undefined &&
      confidence !== undefined &&
      probability >= FROZEN_JEV_THRESHOLDS.minimumSelectedProbability &&
      margin >= FROZEN_JEV_THRESHOLDS.minimumTopTwoMargin &&
      confidence >= FROZEN_JEV_THRESHOLDS.minimumConfidence
    );
  });
}

function metric(
  rows: EvaluationRow[],
  field: "baseline" | "cascade" | "vision",
) {
  const measured = rows.filter((row) => row[field]?.prediction !== undefined);
  const correct = measured.filter((row) =>
    compareEvaluationPrediction(
      row.expected,
      row[field]?.prediction as EvaluationPrediction,
    ),
  ).length;
  const errors = rows.filter((row) => row[field]?.error !== undefined).length;
  const skipped = rows.filter(
    (row) => row[field]?.skipped !== undefined,
  ).length;
  return {
    predictions: measured.length,
    correct,
    accuracy: measured.length === 0 ? null : correct / measured.length,
    errors,
    skipped,
  };
}

export function summarizeEvaluationRows(rows: readonly EvaluationRow[]) {
  const mutableRows = [...rows];
  return {
    samples: mutableRows.length,
    baseline: metric(mutableRows, "baseline"),
    cascade: metric(mutableRows, "cascade"),
    ...(mutableRows.some((row) => row.vision !== undefined)
      ? { vision: metric(mutableRows, "vision") }
      : {}),
  };
}

function parseArgs(argv: string[]): Map<string, string> {
  const result = new Map<string, string>();
  for (let index = 0; index < argv.length; index += 1) {
    const key = argv[index];
    if (!key?.startsWith("--"))
      throw new Error(`unexpected argument ${key ?? ""}`);
    const value = argv[index + 1];
    if (!value || value.startsWith("--"))
      throw new Error(`${key} requires a value`);
    result.set(key.slice(2), value);
    index += 1;
  }
  return result;
}

function positiveInteger(
  args: Map<string, string>,
  key: string,
  fallback: number,
): number {
  const raw = args.get(key);
  if (raw === undefined) return fallback;
  const value = Number(raw);
  if (!Number.isSafeInteger(value) || value <= 0)
    throw new Error(`--${key} must be a positive integer`);
  return value;
}

function cliArgs(argv: string[]): CliArgs {
  const args = parseArgs(argv);
  const mode = args.get("mode") ?? "live";
  if (mode !== "live" && mode !== "deterministic")
    throw new Error("--mode must be live or deterministic");
  const budget = {
    maxCases: positiveInteger(args, "max-cases", DEFAULT_MAX_CASES),
    maxCalls: positiveInteger(
      args,
      "max-calls",
      FALLBACK_EVALUATION_LIMITS.maxCalls,
    ),
    maxTokens: positiveInteger(
      args,
      "max-tokens",
      FALLBACK_EVALUATION_LIMITS.maxTokens,
    ),
  };
  validateFallbackEvaluationBudget(budget);
  if (budget.maxCases > FALLBACK_EVALUATION_LIMITS.maxCases)
    throw new Error("--max-cases exceeds the bounded limit");
  if (budget.maxCalls > FALLBACK_EVALUATION_LIMITS.maxCalls)
    throw new Error("--max-calls exceeds the bounded limit");
  if (budget.maxTokens > FALLBACK_EVALUATION_LIMITS.maxTokens)
    throw new Error("--max-tokens exceeds the bounded limit");
  const seed = Number(args.get("seed") ?? "17");
  if (!Number.isSafeInteger(seed)) throw new Error("--seed must be an integer");
  return {
    mode,
    fixture: args.get("fixture") ?? "tests/fixtures/intent/en.json",
    output:
      args.get("output") ?? "docs/testing/intent/fallback-evaluation-v2.json",
    seed,
    maxCases: budget.maxCases,
    maxCalls: budget.maxCalls,
    maxTokens: budget.maxTokens,
    devReport: args.get("dev-report") ?? FROZEN_JEV_REPORTS.development,
    calibrationReport:
      args.get("calibration-report") ?? FROZEN_JEV_REPORTS.calibration,
    holdoutReport: args.get("holdout-report") ?? FROZEN_JEV_REPORTS.holdout,
  };
}

function fixtureHash(text: string): string {
  return createHash("sha256").update(text).digest("hex");
}

async function readFixture(
  path: string,
): Promise<{ fixture: Fixture; text: string }> {
  const text = await readFile(path, "utf8");
  const value = JSON.parse(text) as unknown;
  if (!isRecord(value) || !Array.isArray(value.groups))
    throw new Error("intent fixture is invalid");
  return { fixture: value as unknown as Fixture, text };
}

async function readFrozenReport(
  path: string,
): Promise<{ report: FrozenReport; text: string }> {
  const text = await readFile(path, "utf8");
  const value = JSON.parse(text) as unknown;
  if (!isRecord(value) || !Array.isArray(value.rows))
    throw new Error(`frozen Jev report is invalid: ${path}`);
  const rows = value.rows.map(parseFrozenRow);
  return {
    report: {
      rows,
      ...(typeof value.mode === "string" ? { mode: value.mode } : {}),
      ...(typeof value.split === "string" ? { split: value.split } : {}),
      ...(typeof value.calls === "number" ? { calls: value.calls } : {}),
      ...(typeof value.tokens === "number" ? { tokens: value.tokens } : {}),
      ...(isRecord(value.budget)
        ? {
            budget: Object.fromEntries(
              Object.entries(value.budget).flatMap(([key, item]) =>
                typeof item === "number" ? [[key, item]] : [],
              ),
            ),
          }
        : {}),
    },
    text,
  };
}

function findScenario(scenarios: Scenario[], id: string): Scenario {
  const scenario = scenarios.find((item) => item.id === id);
  if (!scenario) throw new Error(`development fixture does not contain ${id}`);
  return scenario;
}

function findJevRow(
  rows: FrozenJevRow[],
  id: string,
): FrozenJevRow | undefined {
  return rows.find((row) => row.id === id);
}

function jevMatchesExpected(
  row: FrozenJevRow,
  expected: EvaluationExpected,
): boolean {
  return (
    row.actual !== undefined &&
    compareEvaluationPrediction(expected, row.actual)
  );
}

function chooseHighConfidenceWrongIntent(
  rows: FrozenJevRow[],
  scenarios: Scenario[],
): Scenario {
  const developmentIds = new Set(scenarios.map((scenario) => scenario.id));
  const candidates = rows
    .filter(
      (row) =>
        developmentIds.has(row.id) &&
        row.actual !== undefined &&
        row.expected !== undefined,
    )
    .filter((row) => row.actual?.intent !== row.expected?.intent)
    .filter(
      (row) =>
        (row.probabilities?.intent ?? 0) >= 0.5 &&
        (row.confidence?.intent ?? 0) >= 0.5,
    )
    .sort(
      (a, b) =>
        (b.confidence?.intent ?? 0) +
        (b.probabilities?.intent ?? 0) -
        ((a.confidence?.intent ?? 0) + (a.probabilities?.intent ?? 0)),
    );
  const selected = candidates[0];
  if (!selected)
    throw new Error(
      "frozen Jev development report has no high-confidence wrong-intent case",
    );
  return findScenario(scenarios, selected.id);
}

function selectCases(
  fixture: Fixture,
  devReport: FrozenReport,
  seed: number,
  maxCases: number,
): SelectedCase[] {
  const scenarios = splitIntentScenarios(fixture.groups, seed).development;
  const highConfidence = chooseHighConfidenceWrongIntent(
    devReport.rows,
    scenarios,
  );
  const selected: SelectedCase[] = [
    { scenario: highConfidence, role: "high_confidence_wrong_intent" },
    {
      scenario: findScenario(scenarios, "literal-scroll/variant-1"),
      role: "dictation",
    },
    {
      scenario: findScenario(scenarios, "key-plain-escape/variant-1"),
      role: "keys",
    },
    {
      scenario: findScenario(scenarios, "ambiguous-duplicate/variant-1"),
      role: "ambiguous",
    },
    {
      scenario: findScenario(scenarios, "unsupported-password/variant-1"),
      role: "unsupported",
    },
    {
      scenario: findScenario(scenarios, "visual-dialog/variant-1"),
      role: "vision",
      visionFixture: "tests/fixtures/intent/screens/editor-save-cancel.png",
    },
    {
      scenario: findScenario(scenarios, "visual-field/variant-1"),
      role: "vision",
      visionFixture:
        "tests/fixtures/intent/screens/ambiguous-search-fields.png",
    },
    {
      scenario: findScenario(scenarios, "visual-window/variant-1"),
      role: "vision",
      visionFixture: "tests/fixtures/intent/screens/disabled-continue.png",
    },
  ];
  return selected.slice(0, maxCases);
}

function providerFailureReason(error: unknown): string {
  if (error instanceof ProviderError) return `provider_http_${error.status}`;
  if (error instanceof Error) return error.message.slice(0, 200);
  return "provider_error";
}

function providerFailureClass(
  error: unknown,
): EvaluationMeasurement["errorClass"] {
  if (error instanceof ProviderError) return "provider_error";
  if (error instanceof Error && error.message.startsWith("fallback ")) {
    return "fallback_output_invalid";
  }
  if (error instanceof Error && error.message.includes("usage")) {
    return "usage_error";
  }
  return "provider_response_invalid";
}

function isUnsupportedModel(error: unknown): boolean {
  return error instanceof ProviderError && error.status === 404;
}

function readUsage(response: OpenAIResponseResult): Usage {
  const usage = response.usage;
  if (!usage)
    throw new Error(
      "provider usage is unavailable; token budget cannot be enforced",
    );
  const input = usage.input_tokens;
  const output = usage.output_tokens;
  if (
    typeof input !== "number" ||
    !Number.isSafeInteger(input) ||
    input < 0 ||
    typeof output !== "number" ||
    !Number.isSafeInteger(output) ||
    output < 0
  ) {
    throw new Error(
      "provider usage is invalid; token budget cannot be enforced",
    );
  }
  const total = usage.total_tokens ?? input + output;
  if (!Number.isSafeInteger(total) || total < 0)
    throw new Error("provider usage total is invalid");
  return { input_tokens: input, output_tokens: output, total_tokens: total };
}

function estimateTokens(request: {
  input: unknown;
  instructions: string;
}): number {
  return (
    Math.ceil(
      (JSON.stringify(request.input).length + request.instructions.length) / 4,
    ) + FALLBACK_MAX_OUTPUT_TOKENS
  );
}

function openAiPrediction(parsed: ParsedIntentFallback): EvaluationPrediction {
  return {
    intent: parsed.intent,
    ...(parsed.actionKind === undefined ? {} : { action: parsed.actionKind }),
    ...(parsed.targetId === undefined ? {} : { target: parsed.targetId }),
    decision:
      parsed.intent === "action"
        ? "execute"
        : parsed.intent === "dictation"
          ? "dictation"
          : parsed.intent,
    requiresApproval:
      parsed.intent === "action" || parsed.intent === "dictation",
  };
}

async function readImageDataUrl(path: string): Promise<string> {
  const bytes = await readFile(path);
  return `data:image/png;base64,${bytes.toString("base64")}`;
}

async function callFallback(
  client: ReturnType<typeof createOpenAIClient> | null,
  model: string | undefined,
  scenario: Scenario,
  imageDataUrl: string | undefined,
  budget: CallBudget,
): Promise<EvaluationMeasurement> {
  if (budget.stoppedReason !== undefined)
    return { skipped: budget.stoppedReason };
  if (!client || model === undefined) {
    budget.stoppedReason = "openai_configuration_missing";
    return { skipped: budget.stoppedReason };
  }
  if (budget.calls >= budget.maxCalls) {
    budget.stoppedReason = "max_calls";
    return { skipped: budget.stoppedReason };
  }
  const request = buildIntentFallbackRequest({
    utterance: scenario.utterance,
    context: scenario.context,
    imageDataUrl,
  });
  const estimate = estimateTokens(request);
  if (budget.tokens + estimate > budget.maxTokens) {
    budget.stoppedReason = "preflight_token_budget";
    return { skipped: budget.stoppedReason };
  }
  const started = Date.now();
  budget.calls += 1;
  try {
    const response = await client.createResponse({
      input: request.input,
      instructions: request.instructions,
      model,
      maxOutputTokens: FALLBACK_MAX_OUTPUT_TOKENS,
    });
    const usage = readUsage(response);
    budget.tokens += usage.total_tokens;
    if (budget.tokens > budget.maxTokens) {
      budget.stoppedReason = "max_tokens";
      return {
        error: "reported_usage_exceeded_token_budget",
        usage,
        latencyMs: Date.now() - started,
      };
    }
    const parsed = parseIntentFallbackOutput(response.outputText);
    budget.consecutiveFailures = 0;
    return {
      prediction: openAiPrediction(parsed),
      usage,
      latencyMs: Date.now() - started,
    };
  } catch (error) {
    budget.consecutiveFailures += 1;
    if (isUnsupportedModel(error))
      budget.stoppedReason = "unsupported_model_404";
    else if (budget.consecutiveFailures >= 3)
      budget.stoppedReason = "repeated_provider_failures";
    return {
      error: providerFailureReason(error),
      errorClass: providerFailureClass(error),
      latencyMs: Date.now() - started,
    };
  }
}

function jevMeasurement(row: FrozenJevRow | undefined): EvaluationMeasurement {
  if (!row?.actual) return { skipped: "missing_frozen_jev_row" };
  return {
    prediction: normalizePrediction({
      ...row.actual,
      decision: row.actual.intent === "action" ? "execute" : row.actual.intent,
      requiresApproval: row.actual.intent === "action",
    }),
    source: "frozen_jev_report",
  };
}

function sanitizeMeasurement(
  measurement: EvaluationMeasurement | undefined,
): EvaluationMeasurement | undefined {
  if (!measurement) return undefined;
  return {
    ...(measurement.prediction === undefined
      ? {}
      : { prediction: measurement.prediction }),
    ...(measurement.source === undefined ? {} : { source: measurement.source }),
    ...(measurement.error === undefined
      ? {}
      : { error: measurement.error.slice(0, 200) }),
    ...(measurement.errorClass === undefined
      ? {}
      : { errorClass: measurement.errorClass }),
    ...(measurement.skipped === undefined
      ? {}
      : { skipped: measurement.skipped }),
    ...(measurement.usage === undefined ? {} : { usage: measurement.usage }),
    ...(measurement.latencyMs === undefined
      ? {}
      : { latencyMs: measurement.latencyMs }),
  };
}

function sanitizeRow(
  row: EvaluationRow & Record<string, unknown>,
): Record<string, unknown> {
  return {
    id: row.id,
    role: row.role,
    utterance: row.utterance,
    ...(typeof row.visionFixture === "string"
      ? { visionFixture: row.visionFixture }
      : {}),
    expected: row.expected,
    jev: row.jev,
    baseline: sanitizeMeasurement(row.baseline),
    cascade: sanitizeMeasurement(row.cascade),
    ...(row.vision === undefined
      ? {}
      : { vision: sanitizeMeasurement(row.vision) }),
  };
}

async function writeReport(
  path: string,
  report: Record<string, unknown>,
): Promise<void> {
  await mkdir(dirname(path), { recursive: true });
  await writeFile(path, `${JSON.stringify(report, null, 2)}\n`, "utf8");
}

function relativePath(path: string, base: string): string {
  const value = relative(base, resolve(path));
  return value.startsWith("..") ? path : value;
}

async function runEvaluation(args: CliArgs): Promise<Record<string, unknown>> {
  const base = process.cwd();
  const fixturePath = resolve(base, args.fixture);
  const { fixture, text: fixtureText } = await readFixture(fixturePath);
  const frozen = await Promise.all([
    readFrozenReport(args.devReport),
    readFrozenReport(args.calibrationReport),
    readFrozenReport(args.holdoutReport),
  ]);
  const dev = frozen[0];
  const calibration = frozen[1];
  const holdout = frozen[2];
  const selected = selectCases(fixture, dev.report, args.seed, args.maxCases);
  const plannerModel = process.env.FLOWSTATE_PLANNER_MODEL?.trim() || undefined;
  const apiKey = process.env.OPENAI_API_KEY?.trim() || undefined;
  const client =
    args.mode === "live" && apiKey && plannerModel
      ? createOpenAIClient({ apiKey, model: plannerModel })
      : null;
  const budget: CallBudget = {
    maxCalls: args.maxCalls,
    maxTokens: args.maxTokens,
    calls: 0,
    tokens: 0,
    consecutiveFailures: 0,
  };
  if (args.mode === "deterministic")
    budget.stoppedReason = "deterministic_mode";
  const rows: Array<EvaluationRow & Record<string, unknown>> = [];
  const devRows = dev.report.rows;
  for (const item of selected) {
    const frozenRow = findJevRow(devRows, item.scenario.id);
    const gate = frozenJevGate(frozenRow ?? {});
    const jevCorrect =
      frozenRow?.actual === undefined
        ? undefined
        : jevMatchesExpected(frozenRow, item.scenario.expected);
    const row: EvaluationRow & Record<string, unknown> = {
      id: item.scenario.id,
      role: item.role,
      utterance: item.scenario.utterance,
      ...(item.visionFixture === undefined
        ? {}
        : { visionFixture: item.visionFixture }),
      expected: item.scenario.expected,
      jev: {
        source: relativePath(args.devReport, base),
        model: frozenRow?.model ?? null,
        actual: frozenRow?.actual ?? null,
        probabilities: frozenRow?.probabilities ?? null,
        topTwoMargin: frozenRow?.topTwoMargin ?? null,
        confidence: frozenRow?.confidence ?? null,
        gate,
        correct: jevCorrect ?? null,
        highConfidenceWrongIntent: item.role === "high_confidence_wrong_intent",
      },
    };
    row.baseline = await callFallback(
      client,
      plannerModel,
      item.scenario,
      undefined,
      budget,
    );
    const jev = jevMeasurement(frozenRow);
    if (gate) row.cascade = { ...jev, source: "jev_gate_pass" };
    else if (row.baseline.prediction !== undefined) {
      row.cascade = {
        prediction: row.baseline.prediction,
        source: "text_fallback_reused_baseline",
      };
    } else {
      row.cascade = {
        skipped:
          row.baseline.error === undefined
            ? "baseline_unavailable"
            : "baseline_error",
      };
    }
    if (item.visionFixture !== undefined) {
      if (budget.stoppedReason !== undefined) {
        row.vision = { skipped: budget.stoppedReason };
      } else {
        const imageDataUrl = await readImageDataUrl(
          resolve(base, item.visionFixture),
        );
        row.vision = await callFallback(
          client,
          plannerModel,
          item.scenario,
          imageDataUrl,
          budget,
        );
      }
    }
    rows.push(row);
  }
  return {
    schemaVersion: 1,
    mode: args.mode,
    promptVersion: INTENT_FALLBACK_PROMPT_VERSION,
    generatedAt: new Date().toISOString(),
    developmentOnly: true,
    fixture: {
      path: relativePath(args.fixture, base),
      version: fixture.version,
      language: fixture.language,
      policyVersion: fixture.policyVersion,
      sha256: fixtureHash(fixtureText),
    },
    frozenJev: {
      development: {
        path: relativePath(args.devReport, base),
        sha256: fixtureHash(frozen[0].text),
        rows: dev.report.rows.length,
      },
      calibration: {
        path: relativePath(args.calibrationReport, base),
        sha256: fixtureHash(frozen[1].text),
        rows: calibration.report.rows.length,
      },
      holdout: {
        path: relativePath(args.holdoutReport, base),
        sha256: fixtureHash(frozen[2].text),
        rows: holdout.report.rows.length,
      },
      thresholds: FROZEN_JEV_THRESHOLDS,
      holdoutRetuned: false,
    },
    provider: {
      fallback: "OpenAI Responses API",
      model: plannerModel ?? null,
      modelConfigured: plannerModel !== undefined,
      apiKeyConfigured: apiKey !== undefined,
      jev:
        dev.report.rows.find((row) => row.model !== undefined)?.model ?? null,
    },
    budget: {
      maxCases: args.maxCases,
      maxCalls: args.maxCalls,
      maxTokens: args.maxTokens,
      calls: budget.calls,
      tokens: budget.tokens,
    },
    stoppedReason: budget.stoppedReason ?? null,
    limitations:
      budget.stoppedReason === "unsupported_model_404"
        ? [
            "Configured FLOWSTATE_PLANNER_MODEL returned HTTP 404; no alternate model was selected.",
          ]
        : budget.stoppedReason === "openai_configuration_missing"
          ? [
              "OPENAI_API_KEY and FLOWSTATE_PLANNER_MODEL were not both configured; live fallback predictions are unavailable.",
            ]
          : budget.stoppedReason === "deterministic_mode"
            ? [
                "Deterministic mode records frozen Jev gates without making provider calls.",
              ]
            : budget.stoppedReason === "repeated_provider_failures"
              ? [
                  "Three consecutive fallback provider failures stopped the run.",
                ]
              : [],
    rows: rows.map(sanitizeRow),
    metrics: summarizeEvaluationRows(rows),
    note: "Synthetic development cases only. No desktop, file, email, purchase, publication, or deployment effect is performed.",
  };
}

async function main(): Promise<void> {
  const args = cliArgs(process.argv.slice(2));
  const output = resolve(process.cwd(), args.output);
  try {
    const report = await runEvaluation(args);
    await writeReport(output, report);
    process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
  } catch (error) {
    const report = {
      schemaVersion: 1,
      mode: args.mode,
      generatedAt: new Date().toISOString(),
      developmentOnly: true,
      budget: {
        maxCases: args.maxCases,
        maxCalls: args.maxCalls,
        maxTokens: args.maxTokens,
        calls: 0,
        tokens: 0,
      },
      stoppedReason: "preflight_error",
      limitations: [
        error instanceof Error
          ? error.message.slice(0, 200)
          : "preflight_error",
      ],
      rows: [],
      metrics: summarizeEvaluationRows([]),
      note: "No provider call was attempted because the synthetic fixture or frozen Jev report could not be loaded.",
    };
    await writeReport(output, report);
    process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
    process.exitCode = 1;
  }
}

if (
  process.argv[1]?.endsWith("evaluate-intent-fallback.ts") ||
  process.argv[1]?.endsWith("evaluate-intent-fallback.mjs")
) {
  await main();
}
