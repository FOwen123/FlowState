import type { StrictTypeSafeAnswer } from "./strict_typesafe";

export const WORKFLOW_ROUTER_ROUTES = ["direct_action", "workflow"] as const;
export type WorkflowRouterRoute = (typeof WORKFLOW_ROUTER_ROUTES)[number];

export const WORKFLOW_ROUTER_VERSION = "workflow-router-v1";

export type WorkflowRouterContext = {
  focusedApp?: string;
  installedApps?: readonly string[];
  recentInteraction?: string;
};

export type WorkflowRouterInput = {
  utterance: string;
  context?: WorkflowRouterContext;
};

export type WorkflowRouterState = {
  utterance: string;
  context?: WorkflowRouterContext;
};

export type WorkflowRouterQuestion = {
  type: "choice";
  choices: readonly WorkflowRouterRoute[];
  instructions: string;
  criteria: Record<WorkflowRouterRoute, string>;
};

export type WorkflowRouterRequest = {
  state: WorkflowRouterState;
  questions: { route: WorkflowRouterQuestion };
};

export type WorkflowRouterPolicy = {
  version: string;
  status: "disabled" | "enabled";
  minSelectedProbability: number;
  minTopTwoMargin: number;
};

export const DEFAULT_WORKFLOW_ROUTER_POLICY: Readonly<WorkflowRouterPolicy> =
  Object.freeze({
    version: WORKFLOW_ROUTER_VERSION,
    status: "disabled",
    minSelectedProbability: 1,
    minTopTwoMargin: 1,
  });

export type WorkflowRouterDecision = {
  route: WorkflowRouterRoute;
  accepted: boolean;
  reason:
    | "policy_disabled"
    | "model_workflow"
    | "below_threshold"
    | "threshold_passed"
    | "invalid_answer";
};

function boundedText(value: string, label: string, max: number): string {
  if (typeof value !== "string") throw new Error(`${label} must be text`);
  const trimmed = value.trim();
  if (trimmed.length === 0 || trimmed.length > max) {
    throw new Error(`${label} must contain 1-${max} characters`);
  }
  return trimmed;
}

function buildContext(
  context: WorkflowRouterContext | undefined,
): WorkflowRouterContext | undefined {
  if (context === undefined) return undefined;
  const result: WorkflowRouterContext = {};
  if (context.focusedApp !== undefined) {
    result.focusedApp = boundedText(context.focusedApp, "focusedApp", 200);
  }
  if (context.installedApps !== undefined) {
    if (
      !Array.isArray(context.installedApps) ||
      context.installedApps.length > 64
    ) {
      throw new Error("installedApps must contain at most 64 apps");
    }
    result.installedApps = context.installedApps.map((app) =>
      boundedText(app, "installed app", 200),
    );
  }
  if (context.recentInteraction !== undefined) {
    result.recentInteraction = boundedText(
      context.recentInteraction,
      "recentInteraction",
      1_000,
    );
  }
  return Object.keys(result).length === 0 ? undefined : result;
}

export function buildWorkflowRouterState(
  input: WorkflowRouterInput,
): WorkflowRouterState {
  const state: WorkflowRouterState = {
    utterance: boundedText(input.utterance, "utterance", 4_000),
  };
  const context = buildContext(input.context);
  if (context !== undefined) state.context = context;
  return state;
}

export function buildWorkflowRouterQuestion(): WorkflowRouterQuestion {
  return {
    type: "choice",
    choices: WORKFLOW_ROUTER_ROUTES,
    instructions:
      "Classify only which downstream role should receive the completed English utterance. Choose direct_action only for exactly one already-bounded local action with no sequencing, negation, follow-up, unresolved referent, or generated content. Treat an app name containing the word and as one literal name when the supplied context supports it. Choose workflow for compounds, multi-step requests, corrections or negation, follow-ups, external or unsupported requests, missing context, or any uncertainty. Do not extract an action, target, argument, URL, file, recipient, or text, and do not execute anything. The workflow planner may clarify or reject the request.",
    criteria: {
      direct_action:
        "One clear, complete, bounded local action can be handled by the direct-action route; a literal app name may contain and.",
      workflow:
        "The request needs planning, sequencing, clarification, unsupported-workflow handling, or any uncertain interpretation; send it to the planner.",
    },
  };
}

export function buildWorkflowRouterRequest(
  input: WorkflowRouterInput,
): WorkflowRouterRequest {
  return {
    state: buildWorkflowRouterState(input),
    questions: { route: buildWorkflowRouterQuestion() },
  };
}

function validProbability(value: unknown): value is number {
  return (
    typeof value === "number" &&
    Number.isFinite(value) &&
    value >= 0 &&
    value <= 1
  );
}

function validRouterAnswer(
  answer: StrictTypeSafeAnswer,
): answer is StrictTypeSafeAnswer & { choice: WorkflowRouterRoute } {
  return (
    WORKFLOW_ROUTER_ROUTES.includes(answer.choice as WorkflowRouterRoute) &&
    validProbability(answer.confidence) &&
    validProbability(answer.selectedProbability) &&
    validProbability(answer.topTwoMargin)
  );
}

export function selectWorkflowRoute(input: {
  answer: StrictTypeSafeAnswer;
  policy?: WorkflowRouterPolicy;
}): WorkflowRouterDecision {
  const policy = input.policy ?? DEFAULT_WORKFLOW_ROUTER_POLICY;
  if (!validRouterAnswer(input.answer)) {
    return { route: "workflow", accepted: false, reason: "invalid_answer" };
  }
  if (policy.status !== "enabled") {
    return { route: "workflow", accepted: false, reason: "policy_disabled" };
  }
  if (input.answer.choice === "workflow") {
    return { route: "workflow", accepted: false, reason: "model_workflow" };
  }
  if (
    !validProbability(policy.minSelectedProbability) ||
    !validProbability(policy.minTopTwoMargin) ||
    input.answer.selectedProbability < policy.minSelectedProbability ||
    input.answer.topTwoMargin < policy.minTopTwoMargin
  ) {
    return { route: "workflow", accepted: false, reason: "below_threshold" };
  }
  return { route: "direct_action", accepted: true, reason: "threshold_passed" };
}
