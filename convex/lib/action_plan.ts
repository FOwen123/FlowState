import { asBoundedText, isRecord } from "./http";

export type ActionKind =
  | "openApplication"
  | "scroll"
  | "focus"
  | "select"
  | "press"
  | "insertText"
  | "openURL"
  | "attachFile"
  | "sendEmail";

export type VisualTarget = {
  displayId: string;
  windowId: string;
  x: number;
  y: number;
  width: number;
  height: number;
  observedAt: number;
};

export type PlannedAction = {
  kind: ActionKind;
  targetBundleIdentifier?: string;
  parameters: Record<string, string | number | boolean>;
  capability: string;
  executor: "desktop" | "service";
  requiresApproval: boolean;
  visualTarget?: VisualTarget;
};

const actionKinds = new Set<ActionKind>([
  "openApplication",
  "scroll",
  "focus",
  "select",
  "press",
  "insertText",
  "openURL",
  "attachFile",
  "sendEmail",
]);

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

function booleanParam(parameters: Record<string, unknown>, key: string): boolean {
  const value = parameters[key];
  if (typeof value !== "boolean") throw new Error(`action parameter ${key} must be boolean`);
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

function normalizeAction(value: unknown): PlannedAction {
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
      capability = "app.control";
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
    case "insertText":
      exactKeys(parameters, ["text", "replaceSelection"]);
      normalized = { text: stringParam(parameters, "text", 20_000) };
      if (parameters.replaceSelection !== undefined) normalized.replaceSelection = booleanParam(parameters, "replaceSelection");
      capability = "app.input";
      executor = "desktop";
      requiresApproval = true;
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
      requiresApproval = true;
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
  }
  if (actionKind !== "attachFile" && actionKind !== "sendEmail" && targetBundleIdentifier === undefined) {
    throw new Error(`${actionKind} requires a target bundle`);
  }
  return {
    kind: actionKind,
    ...(targetBundleIdentifier === undefined ? {} : { targetBundleIdentifier }),
    parameters: normalized,
    capability,
    executor,
    requiresApproval,
    ...(value.visualTarget === undefined ? {} : { visualTarget: parseVisualTarget(value.visualTarget) }),
  };
}

export type NormalizedPlan = {
  actions: PlannedAction[];
  explanation: string;
  clarificationNeeded: boolean;
  capabilities: string[];
  fingerprint: string;
};

function stableStringify(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(stableStringify).join(",")}]`;
  if (isRecord(value)) {
    return `{${Object.keys(value)
      .sort()
      .map((key) => `${JSON.stringify(key)}:${stableStringify(value[key])}`)
      .join(",")}}`;
  }
  return JSON.stringify(value);
}

export function normalizeModelPlan(value: unknown): NormalizedPlan {
  if (!isRecord(value)) throw new Error("planner output must be an object");
  exactKeys(value, ["actions", "explanation", "clarificationNeeded"]);
  if (!Array.isArray(value.actions) || value.actions.length === 0 || value.actions.length > 12) {
    throw new Error("planner must return between 1 and 12 actions");
  }
  const actions = value.actions.map(normalizeAction);
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

export function parsePlannerText(outputText: string): NormalizedPlan {
  const trimmed = outputText.trim().replace(/^```(?:json)?\s*/i, "").replace(/\s*```$/, "");
  let value: unknown;
  try {
    value = JSON.parse(trimmed) as unknown;
  } catch {
    throw new Error("planner returned invalid JSON");
  }
  return normalizeModelPlan(value);
}
