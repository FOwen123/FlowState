import { isRecord } from "./http";
import type { StrictTypeSafeQuestion } from "./typesafe";
import { buildIntentQuestionsData } from "./intent_questions";

// routeIntent is Mac Control only. Structured service actions are planned via
// createActionPlan, where their typed parameters and approval policy live.
export const ACTION_KINDS = [
  "openApplication",
  "scroll",
  "focus",
  "select",
  "press",
  "click",
] as const;

export type IntentActionKind = (typeof ACTION_KINDS)[number];
export const TOOL_KINDS = [
  "structuredIntegration",
  "nativeAccessibility",
  "visualComputerUse",
] as const;
export type IntentToolKind = (typeof TOOL_KINDS)[number];
export type IntentMode = "auto" | "commands" | "control";
export type IntentName = "action" | "clarify" | "unsupported";
export type IntentRiskClass = "reversible" | "confirm" | "unsupported";
export type IntentSlotStatus = "complete" | "missing";
export type IntentClarification = "notNeeded" | "needed" | "abstain";
export type CandidateKind = "app" | "window" | "control" | "file";

export type IntentCandidate = {
  id: string;
  label: string;
  normalizedNames?: string[];
  matchedAlias?: string;
  bundleIdentifier?: string;
  kind: CandidateKind;
  isRunning?: boolean;
  supportedActions?: IntentActionKind[];
  integrations?: string[];
};

export type IntentContext = {
  focusedAppBundleIdentifier?: string;
  focusedRole?: string;
  editable?: boolean;
  targetCandidates: IntentCandidate[];
  recentInteraction?: string;
};

export type IntentObservation = {
  id: string;
  displayId: string;
  windowId: string;
  observedAt: number;
  geometry: {
    x: number;
    y: number;
    width: number;
    height: number;
    scale: number;
  };
  imageDataUrl?: string;
};

export type IntentRouteRequest = {
  deviceId: string;
  sessionId: string;
  utteranceId: string;
  contextRevision: number;
  utterance: string;
  mode: IntentMode;
  context: IntentContext;
  supportedActions: IntentActionKind[];
  supportedTools: IntentToolKind[];
  supportedCapabilities: string[];
  policyVersion: string;
  observation?: IntentObservation;
};

const CAPABILITIES = new Set([
  "app.open",
  "app.observe",
  "app.control",
  "app.input",
  "app.upload",
  "file.read",
  "file.upload",
  "mail.read",
  "mail.send",
  "mail.draft",
  "spend.confirm",
]);

const ID_PATTERN = /^[A-Za-z0-9._:-]{1,128}$/;
const BUNDLE_PATTERN = /^[A-Za-z0-9.-]{3,200}$/;
const INTEGRATION_PATTERN = /^[A-Za-z0-9._:-]{1,128}$/;

function exactKeys(
  value: Record<string, unknown>,
  allowed: readonly string[],
  label: string,
): void {
  const expected = new Set(allowed);
  for (const key of Object.keys(value)) {
    if (!expected.has(key))
      throw new Error(`${label} contains an unknown field`);
  }
}

function boundedString(
  value: unknown,
  label: string,
  min: number,
  max: number,
): string {
  if (typeof value !== "string") throw new Error(`${label} must be text`);
  const trimmed = value.trim();
  if (trimmed.length < min || trimmed.length > max) {
    throw new Error(`${label} must contain ${min}-${max} characters`);
  }
  return trimmed;
}

function id(value: unknown, label: string): string {
  const result = boundedString(value, label, 1, 128);
  if (!ID_PATTERN.test(result)) throw new Error(`${label} is invalid`);
  return result;
}

function bundle(value: unknown, label: string): string {
  const result = boundedString(value, label, 3, 200);
  if (!BUNDLE_PATTERN.test(result) || !result.includes(".")) {
    throw new Error(`${label} is invalid`);
  }
  return result;
}

function normalizedName(value: unknown, label: string): string {
  const result = boundedString(value, label, 1, 100)
    .toLocaleLowerCase()
    .replace(/[^a-z0-9]+/g, " ")
    .trim()
    .replace(/\s+/g, " ");
  if (result.length === 0) throw new Error(`${label} is invalid`);
  return result;
}

function validateCandidate(value: unknown): IntentCandidate {
  if (!isRecord(value)) throw new Error("intent candidate must be an object");
  exactKeys(
    value,
    [
      "id",
      "label",
      "normalizedNames",
      "matchedAlias",
      "bundleIdentifier",
      "kind",
      "isRunning",
      "supportedActions",
      "integrations",
    ],
    "intent candidate",
  );
  const candidateId = id(value.id, "candidate id");
  if (candidateId === "none") throw new Error("candidate id is reserved");
  const label = boundedString(value.label, "candidate label", 1, 300);
  let normalizedNames: string[] | undefined;
  if (value.normalizedNames !== undefined) {
    if (
      !Array.isArray(value.normalizedNames) ||
      value.normalizedNames.length === 0 ||
      value.normalizedNames.length > 16
    ) {
      throw new Error("candidate normalizedNames are invalid");
    }
    normalizedNames = value.normalizedNames.map((name) =>
      normalizedName(name, "candidate normalized name"),
    );
    if (new Set(normalizedNames).size !== normalizedNames.length) {
      throw new Error("candidate normalizedNames must be unique");
    }
  }
  const matchedAlias =
    value.matchedAlias === undefined
      ? undefined
      : normalizedName(value.matchedAlias, "candidate matchedAlias");
  if (value.bundleIdentifier !== undefined)
    bundle(value.bundleIdentifier, "candidate bundleIdentifier");
  if (
    value.kind !== "app" &&
    value.kind !== "window" &&
    value.kind !== "control" &&
    value.kind !== "file"
  ) {
    throw new Error("candidate kind is invalid");
  }
  let isRunning: boolean | undefined;
  if (value.isRunning !== undefined) {
    if (typeof value.isRunning !== "boolean") {
      throw new Error("candidate isRunning is invalid");
    }
    isRunning = value.isRunning;
  }
  let supportedActions: IntentActionKind[] | undefined;
  if (value.supportedActions !== undefined) {
    if (
      !Array.isArray(value.supportedActions) ||
      value.supportedActions.length > ACTION_KINDS.length ||
      value.supportedActions.some(
        (action) =>
          typeof action !== "string" ||
          !ACTION_KINDS.includes(action as IntentActionKind),
      )
    ) {
      throw new Error("candidate supportedActions are invalid");
    }
    supportedActions = [...new Set(value.supportedActions)] as IntentActionKind[];
    if (supportedActions.length !== value.supportedActions.length) {
      throw new Error("candidate supportedActions must be unique");
    }
  }
  let integrations: string[] | undefined;
  if (value.integrations !== undefined) {
    if (
      !Array.isArray(value.integrations) ||
      value.integrations.length > 32 ||
      value.integrations.some(
        (integration) =>
          typeof integration !== "string" ||
          !INTEGRATION_PATTERN.test(integration.trim()) ||
          integration.trim().length === 0,
      )
    ) {
      throw new Error("candidate integrations are invalid");
    }
    integrations = value.integrations.map((integration) => integration.trim());
    if (new Set(integrations).size !== integrations.length) {
      throw new Error("candidate integrations must be unique");
    }
  }
  return {
    id: candidateId,
    label,
    ...(normalizedNames === undefined ? {} : { normalizedNames }),
    ...(matchedAlias === undefined ? {} : { matchedAlias }),
    ...(value.bundleIdentifier === undefined
      ? {}
      : {
          bundleIdentifier: bundle(
            value.bundleIdentifier,
            "candidate bundleIdentifier",
          ),
        }),
    kind: value.kind,
    ...(isRunning === undefined ? {} : { isRunning }),
    ...(supportedActions === undefined ? {} : { supportedActions }),
    ...(integrations === undefined ? {} : { integrations }),
  };
}

function validateObservation(value: unknown): IntentObservation {
  if (!isRecord(value)) throw new Error("observation must be an object");
  exactKeys(
    value,
    ["id", "displayId", "windowId", "observedAt", "geometry", "imageDataUrl"],
    "observation",
  );
  const observedAt = value.observedAt;
  if (
    typeof observedAt !== "number" ||
    !Number.isFinite(observedAt) ||
    observedAt < Date.now() - 30_000 ||
    observedAt > Date.now() + 60_000
  ) {
    throw new Error("observation timestamp is invalid");
  }
  const geometry = value.geometry;
  if (!isRecord(geometry)) throw new Error("observation geometry is required");
  exactKeys(
    geometry,
    ["x", "y", "width", "height", "scale"],
    "observation geometry",
  );
  for (const key of ["x", "y", "width", "height", "scale"]) {
    if (typeof geometry[key] !== "number" || !Number.isFinite(geometry[key]))
      throw new Error("observation geometry is invalid");
  }
  const bounds = geometry as IntentObservation["geometry"];
  if (
    bounds.width <= 0 ||
    bounds.height <= 0 ||
    bounds.scale <= 0 ||
    bounds.scale > 8
  )
    throw new Error("observation geometry is invalid");
  if (value.imageDataUrl !== undefined) {
    if (
      typeof value.imageDataUrl !== "string" ||
      value.imageDataUrl.length > 2_000_000
    ) {
      throw new Error("observation image exceeds the 2MB limit");
    }
    if (
      !/^data:image\/(?:png|jpeg);base64,[A-Za-z0-9+/=]+$/.test(
        value.imageDataUrl,
      )
    ) {
      throw new Error("observation image must be a PNG or JPEG data URL");
    }
  }
  return {
    id: id(value.id, "observation id"),
    displayId: boundedString(value.displayId, "observation displayId", 1, 200),
    windowId: boundedString(value.windowId, "observation windowId", 1, 200),
    observedAt,
    geometry: bounds,
    ...(value.imageDataUrl === undefined
      ? {}
      : { imageDataUrl: value.imageDataUrl }),
  };
}

export function validateIntentRouteRequest(value: unknown): IntentRouteRequest {
  if (!isRecord(value)) throw new Error("intent request must be an object");
  exactKeys(
    value,
    [
      "deviceId",
      "sessionId",
      "utteranceId",
      "contextRevision",
      "utterance",
      "mode",
      "context",
      "supportedActions",
      "supportedTools",
      "supportedCapabilities",
      "policyVersion",
      "observation",
    ],
    "intent request",
  );
  const contextValue = value.context;
  if (!isRecord(contextValue))
    throw new Error("intent context must be an object");
  exactKeys(
    contextValue,
    [
      "focusedAppBundleIdentifier",
      "focusedRole",
      "editable",
      "targetCandidates",
      "recentInteraction",
    ],
    "intent context",
  );
  if (
    !Array.isArray(contextValue.targetCandidates) ||
    contextValue.targetCandidates.length > 100
  ) {
    throw new Error("intent context candidates are invalid");
  }
  const candidates = contextValue.targetCandidates.map(validateCandidate);
  if (
    new Set(candidates.map((candidate) => candidate.id)).size !==
    candidates.length
  ) {
    throw new Error("intent context candidate IDs must be unique");
  }
  const supportedActions = value.supportedActions;
  if (
    !Array.isArray(supportedActions) ||
    supportedActions.length === 0 ||
    supportedActions.some(
      (action) =>
        typeof action !== "string" ||
        !ACTION_KINDS.includes(action as IntentActionKind),
    )
  ) {
    throw new Error("supportedActions are invalid");
  }
  const uniqueActions = [...new Set(supportedActions)] as IntentActionKind[];
  const supportedTools = value.supportedTools;
  if (
    !Array.isArray(supportedTools) ||
    supportedTools.length === 0 ||
    supportedTools.some(
      (tool) =>
        typeof tool !== "string" ||
        !TOOL_KINDS.includes(tool as IntentToolKind),
    )
  ) {
    throw new Error("supportedTools are invalid");
  }
  const uniqueTools = [...new Set(supportedTools)] as IntentToolKind[];
  const supportedCapabilities = value.supportedCapabilities;
  if (
    !Array.isArray(supportedCapabilities) ||
    supportedCapabilities.some(
      (capability) =>
        typeof capability !== "string" || !CAPABILITIES.has(capability),
    )
  ) {
    throw new Error("supportedCapabilities are invalid");
  }
  const uniqueCapabilities = [...new Set(supportedCapabilities)] as string[];
  if (
    typeof value.contextRevision !== "number" ||
    !Number.isInteger(value.contextRevision) ||
    value.contextRevision < 0 ||
    value.contextRevision > 2_147_483_647
  ) {
    throw new Error("contextRevision must be a non-negative integer");
  }
  if (value.mode !== "auto" && value.mode !== "commands" && value.mode !== "control") {
    throw new Error("intent mode is invalid");
  }
  const context: IntentContext = {
    ...(contextValue.focusedAppBundleIdentifier === undefined
      ? {}
      : {
          focusedAppBundleIdentifier: bundle(
            contextValue.focusedAppBundleIdentifier,
            "focusedAppBundleIdentifier",
          ),
        }),
    ...(contextValue.focusedRole === undefined
      ? {}
      : {
          focusedRole: boundedString(
            contextValue.focusedRole,
            "focusedRole",
            1,
            200,
          ),
        }),
    ...(contextValue.editable === undefined
      ? {}
      : { editable: contextValue.editable === true }),
    targetCandidates: candidates,
    ...(contextValue.recentInteraction === undefined
      ? {}
      : {
          recentInteraction: boundedString(
            contextValue.recentInteraction,
            "recentInteraction",
            1,
            1_000,
          ),
        }),
  };
  if (
    contextValue.editable !== undefined &&
    typeof contextValue.editable !== "boolean"
  ) {
    throw new Error("editable must be boolean");
  }
  return {
    deviceId: id(value.deviceId, "deviceId"),
    sessionId: id(value.sessionId, "sessionId"),
    utteranceId: id(value.utteranceId, "utteranceId"),
    contextRevision: value.contextRevision,
    utterance: boundedString(value.utterance, "utterance", 1, 4_000),
    mode: value.mode,
    context,
    supportedActions: uniqueActions,
    supportedTools: uniqueTools,
    supportedCapabilities: uniqueCapabilities,
    policyVersion: boundedString(value.policyVersion, "policyVersion", 1, 100),
    ...(value.observation === undefined
      ? {}
      : { observation: validateObservation(value.observation) }),
  };
}

export function requiredCapability(action: IntentActionKind): string {
  switch (action) {
    case "openApplication":
      return "app.open";
    case "scroll":
    case "focus":
    case "select":
      return "app.control";
    case "press":
      return "app.input";
    case "click":
      return "app.control";
  }
}

export function buildIntentQuestions(
  request: IntentRouteRequest,
): Record<
  string,
  StrictTypeSafeQuestion & {
    instructions: string;
    criteria: Record<string, string>;
  }
> {
  return buildIntentQuestionsData({
    supportedActions: request.supportedActions,
    supportedTools: request.supportedTools,
    focusedAppBundleIdentifier: request.context.focusedAppBundleIdentifier,
    targetCandidates: request.context.targetCandidates,
  });
}
