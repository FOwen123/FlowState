import { asBoundedText, isRecord } from "./http";

export type ActionKind =
  | "openApplication"
  | "scroll"
  | "focus"
  | "select"
  | "press"
  | "openURL"
  | "attachFile"
  | "sendEmail"
  | "draftMessage";

export type VisualTarget = {
  displayId: string;
  windowId: string;
  x: number;
  y: number;
  width: number;
  height: number;
  observedAt: number;
};

export type ActionRoute =
  | "structuredIntegration"
  | "nativeAccessibility"
  | "visualComputerUse";

export type StepRiskClass = "reversible" | "confirm" | "unsupported";

export type StepPreconditions = {
  targetBundleIdentifier?: string;
  requiresFreshObservation: boolean;
};

export type StepVerifier =
  | { kind: "boundedAction" }
  | { kind: "externalEffectReconciled" }
  | { kind: "visualObservation" };

export type ReversalMetadata =
  | { kind: "none"; supported: false }
  | { kind: "reconcile"; supported: false }
  | { kind: "undo"; supported: true };

export type PlannedAction = {
  kind: ActionKind;
  targetBundleIdentifier?: string;
  parameters: Record<string, string | number | boolean>;
  capability: string;
  executor: "desktop" | "service";
  requiresApproval: boolean;
  route: ActionRoute;
  riskClass: StepRiskClass;
  preconditions: StepPreconditions;
  verifier: StepVerifier;
  reversal: ReversalMetadata;
  visualTarget?: VisualTarget;
};

export type ApplicationRegistryCandidate = {
  bundleIdentifier: string;
  displayName: string;
  normalizedNames: string[];
  supportedActions: ActionKind[];
  integrations: string[];
};

export type RouteAvailability = Partial<Record<ActionRoute, boolean>>;

export type PlanAvailability = {
  supportedTools: readonly ActionRoute[];
  integrations: readonly string[];
  supportedActions?: readonly ActionKind[];
  applicationCandidates?: readonly ApplicationRegistryCandidate[];
};

const actionRoutes = new Set<ActionRoute>([
  "structuredIntegration",
  "nativeAccessibility",
  "visualComputerUse",
]);
const integrationIdPattern = /^[A-Za-z0-9._:-]{1,128}$/;

function parseAdvertisedJson(
  value: string | undefined,
  label: string,
  max: number,
): string[] {
  if (value === undefined) return [];
  let parsed: unknown;
  try {
    parsed = JSON.parse(value) as unknown;
  } catch {
    throw new Error(`${label} is invalid`);
  }
  if (
    !Array.isArray(parsed) ||
    parsed.length > max ||
    parsed.some(
      (item) =>
        typeof item !== "string" ||
        item.trim().length === 0 ||
        item.trim().length > 128 ||
        !integrationIdPattern.test(item.trim()),
    )
  ) {
    throw new Error(`${label} is invalid`);
  }
  const values = parsed.map((item) => (item as string).trim());
  if (new Set(values).size !== values.length) {
    throw new Error(`${label} must be unique`);
  }
  return values;
}

export function parsePlanAvailability(
  supportedToolsJson: string | undefined,
  integrationsJson: string | undefined,
  applicationCandidatesJson?: string,
): PlanAvailability | undefined {
  if (
    supportedToolsJson === undefined &&
    integrationsJson === undefined &&
    applicationCandidatesJson === undefined
  ) {
    return undefined;
  }
  const supportedTools = parseAdvertisedJson(
    supportedToolsJson,
    "supportedTools",
    actionRoutes.size,
  );
  if (
    (supportedToolsJson !== undefined && supportedTools.length === 0) ||
    supportedTools.some((tool) => !actionRoutes.has(tool as ActionRoute))
  ) {
    throw new Error("supportedTools is invalid");
  }
  const integrations = parseAdvertisedJson(
    integrationsJson,
    "integrations",
    32,
  );
  let applicationCandidates: ApplicationRegistryCandidate[] | undefined;
  if (applicationCandidatesJson !== undefined) {
    let parsedCandidates: unknown;
    try {
      parsedCandidates = JSON.parse(applicationCandidatesJson) as unknown;
    } catch {
      throw new Error("application candidates are invalid");
    }
    applicationCandidates = normalizeApplicationRegistryCandidates(parsedCandidates);
  }
  return {
    supportedTools: supportedTools as ActionRoute[],
    integrations,
    applicationCandidates,
  };
}

export function selectActionRoute(
  actionKind: ActionKind,
  availability: RouteAvailability,
): ActionRoute {
  if (["openURL", "attachFile", "sendEmail", "draftMessage"].includes(actionKind)) {
    if (availability.structuredIntegration === false) {
      throw new Error("no supported execution route");
    }
    return "structuredIntegration";
  }
  if (availability.nativeAccessibility !== false) return "nativeAccessibility";
  if (availability.visualComputerUse === true) return "visualComputerUse";
  throw new Error("no supported execution route");
}

function riskClassFor(
  actionKind: ActionKind,
  parameters: Record<string, string | number | boolean>,
): StepRiskClass {
  if (["attachFile", "sendEmail", "draftMessage"].includes(actionKind)) {
    return "confirm";
  }
  if (
    actionKind === "press" &&
    (parameters.key === "Enter" || parameters.modifiers !== undefined)
  ) {
    return "confirm";
  }
  return "reversible";
}

function verifierFor(actionKind: ActionKind, route: ActionRoute): StepVerifier {
  if (route === "structuredIntegration") {
    return { kind: "externalEffectReconciled" };
  }
  if (route === "visualComputerUse") return { kind: "visualObservation" };
  return { kind: "boundedAction" };
}

function reversalFor(actionKind: ActionKind): ReversalMetadata {
  if (["attachFile", "sendEmail", "draftMessage"].includes(actionKind)) {
    return { kind: "reconcile", supported: false };
  }
  return { kind: "none", supported: false };
}

const actionKinds = new Set<ActionKind>([
  "openApplication",
  "scroll",
  "focus",
  "select",
  "press",
  "openURL",
  "attachFile",
  "sendEmail",
  "draftMessage",
]);

function normalizedApplicationName(value: unknown): string {
  return asBoundedText(value, "application normalized name", 100)
    .toLocaleLowerCase()
    .replace(/\s+/g, " ");
}

export function normalizeApplicationRegistryCandidates(
  value: unknown,
): ApplicationRegistryCandidate[] {
  if (!Array.isArray(value) || value.length > 128) {
    throw new Error("application candidates are invalid");
  }
  const candidates = value.map((item) => {
    if (!isRecord(item)) throw new Error("application candidate is invalid");
    exactKeys(item, [
      "bundleIdentifier",
      "displayName",
      "normalizedNames",
      "supportedActions",
      "integrations",
    ]);
    const bundleIdentifier = asBoundedText(
      item.bundleIdentifier,
      "application bundle identifier",
      200,
    );
    if (!/^[A-Za-z0-9.-]+$/.test(bundleIdentifier) || !bundleIdentifier.includes(".")) {
      throw new Error("application bundle identifier is invalid");
    }
    const displayName = asBoundedText(item.displayName, "application display name", 300);
    if (
      !Array.isArray(item.normalizedNames) ||
      item.normalizedNames.length === 0 ||
      item.normalizedNames.length > 16
    ) {
      throw new Error("application normalized names are invalid");
    }
    const normalizedNames = item.normalizedNames.map(normalizedApplicationName);
    if (new Set(normalizedNames).size !== normalizedNames.length) {
      throw new Error("application normalized names must be unique");
    }
    if (
      !Array.isArray(item.supportedActions) ||
      item.supportedActions.length === 0 ||
      item.supportedActions.length > actionKinds.size ||
      item.supportedActions.some(
        (action) => typeof action !== "string" || !actionKinds.has(action as ActionKind),
      )
    ) {
      throw new Error("application supported actions are invalid");
    }
    const supportedActions = item.supportedActions as string[];
    if (new Set(supportedActions).size !== supportedActions.length) {
      throw new Error("application supported actions must be unique");
    }
    if (!Array.isArray(item.integrations) || item.integrations.length > 32) {
      throw new Error("application integrations are invalid");
    }
    const integrations = item.integrations.map((integration) =>
      asBoundedText(integration, "application integration", 128),
    );
    if (
      integrations.some((integration) => !integrationIdPattern.test(integration)) ||
      new Set(integrations).size !== integrations.length
    ) {
      throw new Error("application integrations are invalid");
    }
    return {
      bundleIdentifier,
      displayName,
      normalizedNames,
      supportedActions: [...supportedActions] as ActionKind[],
      integrations,
    };
  });
  const bundles = candidates.map((candidate) => candidate.bundleIdentifier);
  if (new Set(bundles).size !== bundles.length) {
    throw new Error("application bundle identifiers must be unique");
  }
  return candidates;
}

function exactKeys(value: Record<string, unknown>, allowed: readonly string[]): void {
  const allowedSet = new Set(allowed);
  for (const key of Object.keys(value)) {
    if (!allowedSet.has(key)) throw new Error(`unknown action field: ${key}`);
  }
}

function stringParam(parameters: Record<string, unknown>, key: string, max: number): string {
  return asBoundedText(parameters[key], `action parameter ${key}`, max);
}

function numberParam(parameters: Record<string, unknown>, key: string, min: number, max: number): number {
  const value = parameters[key];
  if (typeof value !== "number" || !Number.isFinite(value) || value < min || value > max) {
    throw new Error(`action parameter ${key} is out of range`);
  }
  return value;
}

function normalizedBundleIdentifier(value: unknown): string | undefined {
  if (value === undefined) return undefined;
  const bundle = asBoundedText(value, "targetBundleIdentifier", 200);
  if (!/^[A-Za-z0-9.-]+$/.test(bundle) || !bundle.includes(".")) {
    throw new Error("targetBundleIdentifier is invalid");
  }
  return bundle;
}

function parseVisualTarget(value: unknown): VisualTarget | undefined {
  if (value === undefined) return undefined;
  if (!isRecord(value)) throw new Error("visualTarget must be an object");
  exactKeys(value, ["displayId", "windowId", "x", "y", "width", "height", "observedAt"]);
  const displayId = stringParam(value, "displayId", 200);
  const windowId = stringParam(value, "windowId", 200);
  const x = numberParam(value, "x", -100_000, 100_000);
  const y = numberParam(value, "y", -100_000, 100_000);
  const width = numberParam(value, "width", 1, 100_000);
  const height = numberParam(value, "height", 1, 100_000);
  const observedAt = numberParam(value, "observedAt", 0, Date.now() + 60_000);
  return { displayId, windowId, x, y, width, height, observedAt };
}

function enforceAvailability(
  actionKind: ActionKind,
  route: ActionRoute,
  availability: PlanAvailability | undefined,
  targetBundleIdentifier: string | undefined,
): void {
  if (availability === undefined) return;
  if (!availability.supportedTools.includes(route)) {
    throw new Error(`${route} is not advertised`);
  }
  if (
    availability.supportedActions !== undefined &&
    !availability.supportedActions.includes(actionKind)
  ) {
    throw new Error(`${actionKind} is not advertised`);
  }
  if (route === "structuredIntegration" && availability.integrations.length === 0) {
    throw new Error("structured integration is not advertised");
  }
  if (
    availability.applicationCandidates !== undefined &&
    targetBundleIdentifier !== undefined
  ) {
    const candidate = availability.applicationCandidates.find(
      (item) => item.bundleIdentifier === targetBundleIdentifier,
    );
    if (candidate === undefined) {
      throw new Error("target application is not an advertised application candidate");
    }
    if (!candidate.supportedActions.includes(actionKind)) {
      throw new Error("action is not advertised for the target application");
    }
    if (
      route === "structuredIntegration" &&
      !candidate.integrations.some((integration) =>
        availability.integrations.includes(integration),
      )
    ) {
      throw new Error("structured integration is not advertised for the target application");
    }
  }
}

function normalizeAction(
  value: unknown,
  availability: PlanAvailability | undefined,
): PlannedAction {
  if (!isRecord(value)) throw new Error("each planned action must be an object");
  exactKeys(value, ["kind", "targetBundleIdentifier", "parameters", "visualTarget"]);
  const kind = value.kind;
  if (typeof kind !== "string" || !actionKinds.has(kind as ActionKind)) {
    throw new Error("planned action kind is not registered");
  }
  const actionKind = kind as ActionKind;
  if (!isRecord(value.parameters)) throw new Error("planned action parameters must be an object");
  const parameters = value.parameters;
  const targetBundleIdentifier = normalizedBundleIdentifier(value.targetBundleIdentifier);
  let normalized: Record<string, string | number | boolean>;
  let capability: string;
  let executor: "desktop" | "service";
  let requiresApproval = false;
  switch (actionKind) {
    case "openApplication":
      exactKeys(parameters, []);
      if (targetBundleIdentifier === undefined) throw new Error("openApplication requires a target bundle");
      normalized = {};
      capability = "app.open";
      executor = "desktop";
      break;
    case "scroll":
      exactKeys(parameters, ["lines"]);
      {
        const lines = numberParam(parameters, "lines", -100, 100);
        if (!Number.isInteger(lines)) throw new Error("scroll lines must be an integer");
        normalized = { lines };
      }
      capability = "app.control";
      executor = "desktop";
      break;
    case "focus":
      exactKeys(parameters, ["role", "label"]);
      normalized = { role: stringParam(parameters, "role", 100) };
      if (parameters.label !== undefined) normalized.label = stringParam(parameters, "label", 300);
      capability = "app.control";
      executor = "desktop";
      break;
    case "select":
      exactKeys(parameters, ["label"]);
      normalized = { label: stringParam(parameters, "label", 300) };
      capability = "app.control";
      executor = "desktop";
      break;
    case "press":
      exactKeys(parameters, ["key", "modifiers"]);
      {
        const key = stringParam(parameters, "key", 32);
        const safeKeys = new Set(["ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight", "PageUp", "PageDown", "Home", "End", "Tab", "Escape", "Enter", "A", "C", "V"]);
        if (!safeKeys.has(key)) throw new Error("press key is not on the safe navigation allowlist");
        normalized = { key };
        if (parameters.modifiers !== undefined) {
          const modifiers = stringParam(parameters, "modifiers", 100);
          if (modifiers !== "Shift" && modifiers !== "Command") throw new Error("press modifiers are restricted to Shift or Command");
          normalized.modifiers = modifiers;
          requiresApproval = true;
        }
        if (key === "Enter") requiresApproval = true;
      }
      capability = "app.input";
      executor = "desktop";
      break;
    case "openURL":
      exactKeys(parameters, ["url"]);
      {
        const url = stringParam(parameters, "url", 2_000);
        let parsed: URL;
        try {
          parsed = new URL(url);
        } catch {
          throw new Error("openURL parameter must be a URL");
        }
        if (parsed.protocol !== "http:" && parsed.protocol !== "https:") {
          throw new Error("openURL only accepts HTTP(S) URLs");
        }
        normalized = { url: parsed.toString() };
      }
      capability = "app.control";
      executor = "service";
      break;
    case "attachFile":
      exactKeys(parameters, ["fileId"]);
      normalized = { fileId: stringParam(parameters, "fileId", 200) };
      capability = "file.upload";
      executor = "service";
      requiresApproval = true;
      break;
    case "sendEmail":
      exactKeys(parameters, ["recipient", "subject", "body"]);
      normalized = {
        recipient: stringParam(parameters, "recipient", 320),
        subject: stringParam(parameters, "subject", 998),
        body: stringParam(parameters, "body", 100_000),
      };
      capability = "mail.send";
      executor = "service";
      requiresApproval = true;
      break;
    case "draftMessage":
      exactKeys(parameters, ["recipient", "subject", "body"]);
      normalized = {
        recipient: stringParam(parameters, "recipient", 320),
        subject: stringParam(parameters, "subject", 998),
        body: stringParam(parameters, "body", 100_000),
      };
      capability = "mail.draft";
      executor = "service";
      requiresApproval = true;
      break;
  }
  if (
    actionKind !== "attachFile" &&
    actionKind !== "sendEmail" &&
    targetBundleIdentifier === undefined
  ) {
    throw new Error(`${actionKind} requires a target bundle`);
  }
  const visualTarget =
    value.visualTarget === undefined
      ? undefined
      : parseVisualTarget(value.visualTarget);
  const route = selectActionRoute(actionKind, {
    nativeAccessibility: visualTarget === undefined,
    visualComputerUse: visualTarget !== undefined,
  });
  enforceAvailability(actionKind, route, availability, targetBundleIdentifier);
  return {
    kind: actionKind,
    ...(targetBundleIdentifier === undefined ? {} : { targetBundleIdentifier }),
    parameters: normalized,
    capability,
    executor,
    requiresApproval,
    route,
    riskClass: riskClassFor(actionKind, normalized),
    preconditions: {
      ...(targetBundleIdentifier === undefined ? {} : { targetBundleIdentifier }),
      requiresFreshObservation: route === "visualComputerUse",
    },
    verifier: verifierFor(actionKind, route),
    reversal: reversalFor(actionKind),
    ...(visualTarget === undefined ? {} : { visualTarget }),
  };
}

export type NormalizedPlan = {
  actions: PlannedAction[];
  explanation: string;
  clarificationNeeded: boolean;
  capabilities: string[];
  fingerprint: string;
};

export function stableStringify(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(stableStringify).join(",")}]`;
  if (isRecord(value)) {
    return `{${Object.keys(value)
      .sort()
      .map((key) => `${JSON.stringify(key)}:${stableStringify(value[key])}`)
      .join(",")}}`;
  }
  return JSON.stringify(value);
}

export function plannedActionFingerprint(action: PlannedAction): string {
  return stableStringify(action);
}

export function containsLegacyInsertText(value: unknown): boolean {
  if (!Array.isArray(value)) return false;
  return value.some(
    (action) =>
      isRecord(action) && action.kind === "insertText",
  );
}

export function containsLegacyInsertTextJson(value: string | undefined): boolean {
  if (value === undefined) return false;
  try {
    return containsLegacyInsertText(JSON.parse(value) as unknown);
  } catch {
    return false;
  }
}

export function normalizeModelPlan(
  value: unknown,
  availability?: PlanAvailability,
): NormalizedPlan {
  if (!isRecord(value)) throw new Error("planner output must be an object");
  exactKeys(value, ["actions", "explanation", "clarificationNeeded"]);
  const needsClarification = value.clarificationNeeded === true;
  if (!Array.isArray(value.actions) || value.actions.length > 12 ||
      (needsClarification ? value.actions.length !== 0 : value.actions.length === 0)) {
    throw new Error("planner must return 1 to 12 actions, or zero actions when clarification is needed");
  }
  const actions = value.actions.map((action) =>
    normalizeAction(action, availability),
  );
  const explanation = asBoundedText(value.explanation ?? "", "planner explanation", 2_000);
  const clarificationNeeded = value.clarificationNeeded === true;
  if (value.clarificationNeeded !== undefined && typeof value.clarificationNeeded !== "boolean") {
    throw new Error("clarificationNeeded must be boolean");
  }
  const capabilities = [...new Set(actions.map((action) => action.capability))].sort();
  const fingerprint = stableStringify({ actions, capabilities });
  if (fingerprint.length > 50_000) throw new Error("planner output exceeds the size limit");
  return { actions, explanation, clarificationNeeded, capabilities, fingerprint };
}

export function normalizeStoredActions(
  value: unknown,
  availability?: PlanAvailability,
): PlannedAction[] {
  if (!Array.isArray(value) || value.length === 0 || value.length > 12) {
    throw new Error("stored action plan must contain 1 to 12 actions");
  }
  return value.map((action) => {
    if (!isRecord(action)) throw new Error("stored action is invalid");
    const allowed = new Set([
      "kind",
      "targetBundleIdentifier",
      "parameters",
      "visualTarget",
      "capability",
      "executor",
      "requiresApproval",
      "route",
      "riskClass",
      "preconditions",
      "verifier",
      "reversal",
    ]);
    if (Object.keys(action).some((key) => !allowed.has(key))) {
      throw new Error("stored action contains an unknown field");
    }
    const normalized = normalizeModelPlan({
      actions: [
        {
          kind: action.kind,
          ...(action.targetBundleIdentifier === undefined
            ? {}
            : { targetBundleIdentifier: action.targetBundleIdentifier }),
          parameters: action.parameters,
          ...(action.visualTarget === undefined
            ? {}
            : { visualTarget: action.visualTarget }),
        },
      ],
      explanation: "stored",
      clarificationNeeded: false,
    }, availability).actions[0];
    if (normalized === undefined) throw new Error("stored action is invalid");
    for (const key of [
      "capability",
      "executor",
      "requiresApproval",
      "route",
      "riskClass",
      "preconditions",
      "verifier",
      "reversal",
    ] as const) {
      if (
        action[key] !== undefined &&
        stableStringify(action[key]) !== stableStringify(normalized[key])
      ) {
        throw new Error(`stored action ${key} does not match policy`);
      }
    }
    return normalized;
  });
}

export function parsePlannerText(
  outputText: string,
  availability?: PlanAvailability,
): NormalizedPlan {
  const trimmed = outputText.trim().replace(/^```(?:json)?\s*/i, "").replace(/\s*```$/, "");
  let value: unknown;
  try {
    value = JSON.parse(trimmed) as unknown;
  } catch {
    throw new Error("planner returned invalid JSON");
  }
  return normalizeModelPlan(value, availability);
}
