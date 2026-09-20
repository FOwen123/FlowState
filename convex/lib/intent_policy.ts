import { isRecord } from "./http";
import {
  ACTION_KINDS,
  requiredCapability,
  type IntentActionKind,
  type IntentName,
  type IntentRouteRequest,
} from "./intent_contract";

export type IntentStage = "intent" | "action" | "target";

export type IntentThresholds = {
  minimumSelectedProbability: number;
  minimumTopTwoMargin: number;
  minimumConfidence: number;
};

export type IntentPolicy = {
  version: string;
  revision: string;
  status: "unmeasured" | "measured";
  thresholds?: Partial<Record<IntentStage, IntentThresholds>>;
  requireReview?: boolean;
};

export const DEFAULT_INTENT_POLICY: IntentPolicy = {
  version: "intent-v1",
  revision: "jev-1.13.0-en-v2-review",
  status: "measured",
  // Calibration and untouched holdout each accepted only 15/80 cases. This
  // selects review proposals; it does not establish unattended safety.
  requireReview: true,
  thresholds: Object.fromEntries(
    ["intent", "action", "target"].map((stage) => [
      stage,
      {
        minimumSelectedProbability: 0.5,
        minimumTopTwoMargin: 0.8,
        minimumConfidence: 0.5,
      },
    ]),
  ),
};

export type IntentAnswer = {
  choice: string;
  confidence: number;
  selectedProbability: number;
  topTwoMargin: number;
};

export type IntentGrant = {
  capability: string;
  target?: string;
  expiresAt: number;
  revokedAt?: number;
};

export type IntentActionProposal = {
  kind: IntentActionKind;
  targetBundleIdentifier?: string;
  parameters: Record<string, string | number | boolean>;
  capability: string;
  executor: "desktop" | "service";
  requiresApproval: boolean;
  targetId?: string;
};

export type IntentDecision = {
  decision: "execute" | "dictation" | "clarify" | "unsupported" | "abstain";
  reason: string;
  intent: "dictation" | "action" | "clarify" | "unsupported" | null;
  action: IntentActionProposal | null;
  clarification: string | null;
  confidence: {
    intent: IntentAnswer | null;
    action: IntentAnswer | null;
    target: IntentAnswer | null;
  };
};

export type FallbackParameters = {
  direction?: "up" | "down";
  amount?: number;
  role?: string;
  label?: string;
  key?: string;
  modifiers?: "Shift" | "Command";
};

export type ParsedFallbackDecision = {
  intent: IntentName;
  actionKind?: IntentActionKind;
  targetId?: string;
  parameters?: FallbackParameters;
};

type Scenario = { id: string; [key: string]: unknown };
type ScenarioGroup<T extends Scenario> = {
  id: string;
  category?: string;
  scenarios: T[];
};

function stableHash(value: string): number {
  let hash = 2_166_136_261;
  for (let index = 0; index < value.length; index += 1) {
    hash ^= value.charCodeAt(index);
    hash = Math.imul(hash, 16_777_619);
  }
  return hash >>> 0;
}

export function splitIntentScenarios<T extends Scenario>(
  groups: ScenarioGroup<T>[],
  seed: number,
): Record<
  "development" | "calibration" | "holdout",
  Array<T & { id: string }>
> {
  const result: Record<
    "development" | "calibration" | "holdout",
    Array<T & { id: string }>
  > = {
    development: [],
    calibration: [],
    holdout: [],
  };
  const byCategory = new Map<string, ScenarioGroup<T>[]>();
  for (const group of groups) {
    const category = group.category ?? "uncategorized";
    const categoryGroups = byCategory.get(category) ?? [];
    categoryGroups.push(group);
    byCategory.set(category, categoryGroups);
  }
  for (const category of [...byCategory.keys()].sort()) {
    const orderedGroups = (byCategory.get(category) ?? []).sort(
      (a, b) => stableHash(`${seed}:${a.id}`) - stableHash(`${seed}:${b.id}`),
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
      const split =
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

function answerPasses(
  answer: IntentAnswer | undefined,
  threshold: IntentThresholds | undefined,
): boolean {
  if (!answer || !threshold) return false;
  return (
    answer.selectedProbability >= threshold.minimumSelectedProbability &&
    answer.topTwoMargin >= threshold.minimumTopTwoMargin &&
    answer.confidence >= threshold.minimumConfidence
  );
}

function confidenceOf(
  answers: Record<string, IntentAnswer>,
  key: string,
): IntentAnswer | null {
  return answers[key] ?? null;
}

function hasGrant(
  grants: IntentGrant[],
  capability: string,
  target: string | undefined,
  now: number,
): boolean {
  return grants.some(
    (grant) =>
      grant.capability === capability &&
      grant.revokedAt === undefined &&
      grant.expiresAt > now &&
      (grant.target === undefined
        ? target === undefined
        : target !== undefined && grant.target === target),
  );
}

const SAFE_KEYS = [
  "ArrowUp",
  "ArrowDown",
  "ArrowLeft",
  "ArrowRight",
  "PageUp",
  "PageDown",
  "Home",
  "End",
  "Tab",
  "Escape",
  "Enter",
  "A",
  "C",
  "V",
] as const;

function canonicalKey(value: string): (typeof SAFE_KEYS)[number] | null {
  return (
    SAFE_KEYS.find((key) => key.toLowerCase() === value.toLowerCase()) ?? null
  );
}

function keyFromUtterance(
  utterance: string,
): (typeof SAFE_KEYS)[number] | null {
  const aliases: Array<[RegExp, (typeof SAFE_KEYS)[number]]> = [
    [/\barrow\s*up\b/i, "ArrowUp"],
    [/\barrow\s*down\b/i, "ArrowDown"],
    [/\barrow\s*left\b/i, "ArrowLeft"],
    [/\barrow\s*right\b/i, "ArrowRight"],
    [/\bpage\s*up\b/i, "PageUp"],
    [/\bpage\s*down\b/i, "PageDown"],
    [/\bhome\b/i, "Home"],
    [/\bend\b/i, "End"],
    [/\btab\b/i, "Tab"],
    [/\bescape\b/i, "Escape"],
    [/\benter\b/i, "Enter"],
    [/\bselect\s+all\b/i, "A"],
    [/\bcopy\b/i, "C"],
    [/\bpaste\b/i, "V"],
  ];
  return aliases.find(([pattern]) => pattern.test(utterance))?.[1] ?? null;
}

function fallbackId(value: unknown, label: string): string {
  if (
    typeof value !== "string" ||
    !/^[A-Za-z0-9._:-]{1,128}$/.test(value) ||
    value === "none"
  ) {
    throw new Error(`fallback ${label} is invalid`);
  }
  return value;
}

function fallbackText(value: unknown, label: string, max: number): string {
  if (
    typeof value !== "string" ||
    value.trim().length === 0 ||
    value.length > max
  ) {
    throw new Error(`fallback ${label} is invalid`);
  }
  return value;
}

function fallbackParameters(
  value: unknown,
  actionKind: IntentActionKind,
): FallbackParameters | undefined {
  if (value === undefined) return undefined;
  if (!isRecord(value))
    throw new Error("fallback parameters must be an object");
  const allowedByAction: Record<IntentActionKind, readonly string[]> = {
    openApplication: [],
    scroll: ["direction", "amount"],
    focus: ["role", "label"],
    select: ["label"],
    press: ["key", "modifiers"],
    insertText: [],
    openURL: [],
    attachFile: [],
    sendEmail: [],
  };
  const allowed = new Set(allowedByAction[actionKind]);
  if (Object.keys(value).some((key) => !allowed.has(key))) {
    throw new Error(`fallback parameters are not allowed for ${actionKind}`);
  }
  const parameters: FallbackParameters = {};
  if (value.direction !== undefined) {
    if (value.direction !== "up" && value.direction !== "down") {
      throw new Error("fallback direction is invalid");
    }
    parameters.direction = value.direction;
  }
  if (value.amount !== undefined) {
    if (
      typeof value.amount !== "number" ||
      !Number.isInteger(value.amount) ||
      value.amount < 1 ||
      value.amount > 100
    ) {
      throw new Error("fallback amount is invalid");
    }
    parameters.amount = value.amount;
  }
  if (value.role !== undefined)
    parameters.role = fallbackText(value.role, "role", 100);
  if (value.label !== undefined)
    parameters.label = fallbackText(value.label, "label", 300);
  if (value.key !== undefined) {
    if (typeof value.key !== "string" || canonicalKey(value.key) === null)
      throw new Error("fallback key is invalid");
    parameters.key = canonicalKey(value.key) as string;
  }
  if (value.modifiers !== undefined) {
    if (value.modifiers !== "Shift" && value.modifiers !== "Command")
      throw new Error("fallback modifiers are invalid");
    parameters.modifiers = value.modifiers;
  }
  return Object.keys(parameters).length === 0 ? undefined : parameters;
}

/** Parse the bounded fallback envelope before any action proposal is built. */
export function parseFallbackDecision(value: unknown): ParsedFallbackDecision {
  if (!isRecord(value) || Array.isArray(value))
    throw new Error("fallback returned an invalid decision");
  const allowed = new Set(["intent", "actionKind", "targetId", "parameters"]);
  if (Object.keys(value).some((key) => !allowed.has(key)))
    throw new Error("fallback returned unknown fields");
  if (
    value.intent !== "dictation" &&
    value.intent !== "action" &&
    value.intent !== "clarify" &&
    value.intent !== "unsupported"
  ) {
    throw new Error("fallback returned an invalid intent");
  }
  const intent = value.intent as IntentName;
  if (intent !== "action") {
    if (
      value.actionKind !== undefined ||
      value.targetId !== undefined ||
      value.parameters !== undefined
    ) {
      throw new Error("fallback non-action decision contains action fields");
    }
    return { intent };
  }
  let actionKind: IntentActionKind | undefined;
  if (value.actionKind !== undefined) {
    if (
      typeof value.actionKind !== "string" ||
      !ACTION_KINDS.includes(value.actionKind as IntentActionKind)
    ) {
      throw new Error("fallback action is invalid");
    }
    actionKind = value.actionKind as IntentActionKind;
  }
  const targetId =
    value.targetId === undefined
      ? undefined
      : fallbackId(value.targetId, "target");
  const parameters =
    actionKind === undefined
      ? undefined
      : fallbackParameters(value.parameters, actionKind);
  if (actionKind === undefined && value.parameters !== undefined) {
    throw new Error("fallback parameters require an action");
  }
  return {
    intent,
    ...(actionKind === undefined ? {} : { actionKind }),
    ...(targetId === undefined ? {} : { targetId }),
    ...(parameters === undefined ? {} : { parameters }),
  };
}

export function buildActionProposal(
  request: IntentRouteRequest,
  actionKind: IntentActionKind,
  targetId: string,
  fallback?: FallbackParameters,
): IntentActionProposal | null {
  if (!request.supportedActions.includes(actionKind)) return null;
  const candidate = request.context.targetCandidates.find(
    (item) => item.id === targetId,
  );
  if (!candidate) return null;
  if (actionKind === "openApplication" && candidate.kind !== "app") return null;
  if (
    (actionKind === "focus" || actionKind === "select") &&
    candidate.kind !== "control"
  )
    return null;
  const targetBundleIdentifier =
    candidate.bundleIdentifier ?? request.context.focusedAppBundleIdentifier;
  if (
    ["scroll", "focus", "select", "press", "insertText"].includes(actionKind) &&
    targetBundleIdentifier !== request.context.focusedAppBundleIdentifier
  )
    return null;
  if (
    actionKind !== "attachFile" &&
    actionKind !== "sendEmail" &&
    targetBundleIdentifier === undefined
  ) {
    return null;
  }
  let parameters: Record<string, string | number | boolean>;
  let requiresApproval = false;
  switch (actionKind) {
    case "openApplication":
      if (
        /\b(?:it|that|this|one)\b/i.test(request.utterance) &&
        !request.utterance.toLowerCase().includes(candidate.label.toLowerCase())
      )
        return null;
      parameters = {};
      break;
    case "scroll": {
      const down = /\b(?:down|lower|forward)\b/i.test(request.utterance);
      const up = /\b(?:up|higher|back)\b/i.test(request.utterance);
      const direction =
        fallback?.direction ?? (down === up ? undefined : down ? "down" : "up");
      if (direction === undefined) return null;
      const number = request.utterance.match(/\b(\d{1,2})\b/);
      const amount = fallback?.amount ?? (number ? Number(number[1]) : 3);
      if (!Number.isInteger(amount) || amount < 1 || amount > 100) return null;
      parameters = { lines: direction === "down" ? -amount : amount };
      break;
    }
    case "focus": {
      const role = fallback?.role ?? request.context.focusedRole;
      if (!role) return null;
      parameters = { role };
      if (fallback?.label !== undefined) parameters.label = fallback.label;
      break;
    }
    case "select":
      parameters = { label: fallback?.label ?? candidate.label };
      break;
    case "press": {
      const requestedKey = fallback?.key ?? keyFromUtterance(request.utterance);
      const key =
        requestedKey === undefined || requestedKey === null
          ? null
          : canonicalKey(requestedKey);
      if (!key) return null;
      parameters = { key };
      if (["A", "C", "V"].includes(key)) {
        if (
          fallback?.modifiers !== undefined &&
          fallback.modifiers !== "Command"
        )
          return null;
        parameters.modifiers = "Command";
      }
      if (fallback?.modifiers !== undefined) {
        parameters.modifiers = fallback.modifiers;
        requiresApproval = true;
      }
      requiresApproval ||= key === "Enter";
      break;
    }
    case "insertText":
      parameters = {
        text: dictationText(request.utterance),
        replaceSelection: true,
      };
      requiresApproval = true;
      break;
    case "openURL":
    case "attachFile":
    case "sendEmail":
      return null;
  }
  return {
    kind: actionKind,
    ...(targetBundleIdentifier === undefined ? {} : { targetBundleIdentifier }),
    parameters,
    capability: requiredCapability(actionKind),
    executor: ["openURL", "attachFile", "sendEmail"].includes(actionKind)
      ? "service"
      : "desktop",
    requiresApproval,
    targetId,
  };
}

function dictationText(utterance: string): string {
  const explicitType = utterance.match(/^\s*(?:please\s+)?type\s+(.+)$/i);
  return explicitType?.[1] ?? utterance;
}

function dictationAction(request: IntentRouteRequest): IntentActionProposal {
  return {
    kind: "insertText",
    ...(request.context.focusedAppBundleIdentifier === undefined
      ? {}
      : { targetBundleIdentifier: request.context.focusedAppBundleIdentifier }),
    parameters: {
      text: dictationText(request.utterance),
      replaceSelection: true,
    },
    capability: "app.input",
    executor: "desktop",
    requiresApproval: true,
  };
}

export function decideIntent(input: {
  request: IntentRouteRequest;
  answers: Record<string, IntentAnswer>;
  grants: IntentGrant[];
  policy: IntentPolicy;
  now?: number;
}): IntentDecision {
  const { request, answers, policy } = input;
  const confidence = {
    intent: confidenceOf(answers, "intent"),
    action: confidenceOf(answers, "action"),
    target: confidenceOf(answers, "target"),
  };
  const base = {
    intent: null,
    action: null,
    clarification: null,
    confidence,
  } as const;
  if (policy.version !== request.policyVersion) {
    return { ...base, decision: "abstain", reason: "policy_version_mismatch" };
  }
  if (policy.status !== "measured") {
    return { ...base, decision: "abstain", reason: "policy_unmeasured" };
  }
  const intentAnswer = answers.intent;
  if (!answerPasses(intentAnswer, policy.thresholds?.intent)) {
    return { ...base, decision: "abstain", reason: "intent_threshold" };
  }
  if (
    (request.mode === "commands" && intentAnswer.choice === "dictation") ||
    (request.mode === "dictation" && intentAnswer.choice === "action")
  ) {
    return {
      ...base,
      decision: "clarify",
      reason: "mode_conflict",
      clarification: "That request does not match the selected voice mode.",
    };
  }
  if (intentAnswer.choice === "dictation") {
    const target = request.context.focusedAppBundleIdentifier;
    if (
      !request.supportedActions.includes("insertText") ||
      !request.supportedCapabilities.includes("app.input")
    ) {
      return {
        ...base,
        decision: "unsupported",
        reason: "dictation_input_not_supported",
        intent: "unsupported",
      };
    }
    if (
      !request.context.editable ||
      !hasGrant(input.grants, "app.input", target, input.now ?? Date.now())
    ) {
      return {
        ...base,
        decision: "clarify",
        reason: "dictation_target_or_grant_missing",
        intent: "dictation",
        clarification: "Which editable field should receive that text?",
      };
    }
    return {
      ...base,
      decision: "dictation",
      reason: "policy_pass",
      intent: "dictation",
      action: dictationAction(request),
    };
  }
  if (intentAnswer.choice === "unsupported") {
    return {
      ...base,
      decision: "unsupported",
      reason: "intent_unsupported",
      intent: "unsupported",
    };
  }
  if (intentAnswer.choice === "clarify") {
    return {
      ...base,
      decision: "clarify",
      reason: "model_requested_clarification",
      intent: "clarify",
      clarification: "What should I do with that request?",
    };
  }
  const actionAnswer = answers.action;
  const targetAnswer = answers.target;
  if (
    !answerPasses(actionAnswer, policy.thresholds?.action) ||
    !answerPasses(targetAnswer, policy.thresholds?.target)
  ) {
    return {
      ...base,
      decision: "abstain",
      reason: "action_or_target_threshold",
      intent: "action",
    };
  }
  if (actionAnswer.choice === "none" || targetAnswer.choice === "none") {
    return {
      ...base,
      decision: "clarify",
      reason: "action_or_target_unresolved",
      intent: "clarify",
      clarification: "Which action or target did you mean?",
    };
  }
  const actionKind = actionAnswer.choice as IntentActionKind;
  const proposal = buildActionProposal(
    request,
    actionKind,
    targetAnswer.choice,
  );
  if (!proposal) {
    return {
      ...base,
      decision: "unsupported",
      reason: "action_not_supported",
      intent: "action",
    };
  }
  const target = proposal.targetBundleIdentifier;
  const now = input.now ?? Date.now();
  if (!request.supportedCapabilities.includes(proposal.capability)) {
    return {
      ...base,
      decision: "unsupported",
      reason: "capability_not_supported",
      intent: "action",
    };
  }
  if (!hasGrant(input.grants, proposal.capability, target, now)) {
    return {
      ...base,
      decision: "clarify",
      reason: "grant_missing_or_expired",
      intent: "action",
      clarification:
        "FlowState needs permission for that target before acting.",
    };
  }
  proposal.requiresApproval ||= policy.requireReview === true;
  return {
    ...base,
    decision: "execute",
    reason: "policy_pass",
    intent: "action",
    action: proposal,
  };
}

export function decideFallback(input: {
  request: IntentRouteRequest;
  intent: "dictation" | "action" | "clarify" | "unsupported";
  actionKind?: string;
  targetId?: string;
  parameters?: FallbackParameters;
  grants: IntentGrant[];
  now?: number;
}): IntentDecision {
  const base = {
    intent: input.intent,
    action: null,
    clarification: null,
    confidence: { intent: null, action: null, target: null },
  } as const;
  if (
    (input.request.mode === "commands" && input.intent === "dictation") ||
    (input.request.mode === "dictation" && input.intent === "action")
  ) {
    return {
      ...base,
      decision: "clarify",
      reason: "mode_conflict",
      clarification: "That request does not match the selected voice mode.",
    };
  }
  if (input.intent === "dictation") {
    const target = input.request.context.focusedAppBundleIdentifier;
    if (
      !input.request.supportedActions.includes("insertText") ||
      !input.request.supportedCapabilities.includes("app.input")
    ) {
      return {
        ...base,
        decision: "unsupported",
        reason: "dictation_input_not_supported",
        intent: "unsupported",
      };
    }
    if (
      !input.request.context.editable ||
      !hasGrant(input.grants, "app.input", target, input.now ?? Date.now())
    ) {
      return {
        ...base,
        decision: "clarify",
        reason: "dictation_target_or_grant_missing",
        clarification: "Which editable field should receive that text?",
      };
    }
    return {
      ...base,
      decision: "dictation",
      reason: "fallback_validated",
      action: dictationAction(input.request),
    };
  }
  if (input.intent === "clarify") {
    return {
      ...base,
      decision: "clarify",
      reason: "fallback_requested_clarification",
      clarification: "Could you clarify the action or target?",
    };
  }
  if (input.intent === "unsupported") {
    return { ...base, decision: "unsupported", reason: "fallback_unsupported" };
  }
  const actionKind = input.actionKind;
  const targetId = input.targetId;
  if (!actionKind || !targetId || !requestActionKind(actionKind)) {
    return {
      ...base,
      decision: "clarify",
      intent: "action",
      reason: "fallback_action_or_target_missing",
      clarification: "Which registered action and target should I use?",
    };
  }
  const proposal = buildActionProposal(
    input.request,
    actionKind,
    targetId,
    input.parameters,
  );
  if (proposal === null) {
    return {
      ...base,
      decision: "unsupported",
      intent: "action",
      reason: "fallback_action_not_supported",
    };
  }
  if (!input.request.supportedCapabilities.includes(proposal.capability)) {
    return {
      ...base,
      decision: "unsupported",
      intent: "action",
      reason: "fallback_capability_not_supported",
    };
  }
  if (
    !hasGrant(
      input.grants,
      proposal.capability,
      proposal.targetBundleIdentifier,
      input.now ?? Date.now(),
    )
  ) {
    return {
      ...base,
      decision: "clarify",
      intent: "action",
      reason: "fallback_grant_missing_or_expired",
      clarification:
        "FlowState needs permission for that target before acting.",
    };
  }
  // Fallback has no calibrated execution confidence; always review its proposal.
  proposal.requiresApproval = true;
  return {
    ...base,
    decision: "execute",
    intent: "action",
    reason: "fallback_validated",
    action: proposal,
  };
}

function requestActionKind(value: string): value is IntentActionKind {
  return [
    "openApplication",
    "scroll",
    "focus",
    "select",
    "press",
    "insertText",
    "openURL",
    "attachFile",
    "sendEmail",
  ].includes(value as IntentActionKind);
}
