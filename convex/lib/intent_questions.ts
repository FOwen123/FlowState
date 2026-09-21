import type {
  IntentActionKind,
  IntentToolKind,
} from "./intent_contract";

export type IntentQuestionInput = {
  supportedActions: readonly string[];
  supportedTools: readonly string[];
  focusedAppBundleIdentifier?: string;
  targetCandidates: readonly { id: string; kind?: string }[];
};

// Structured service actions are intentionally omitted from routeIntent;
// createActionPlan owns their typed parameters and approval policy.
const actionSemantics: Record<string, string> = {
  openApplication:
    "Open the named installed application through the app.open capability.",
  scroll:
    "Scroll the focused target up or down by a bounded amount; do not invent a target.",
  focus: "Focus a supplied editable or control target by verified role or label.",
  select:
    "Select a named list item without activating it; choose is not enough when activation is ambiguous.",
  click:
    "Click a supplied labeled control; use a fresh visual observation when native Accessibility cannot expose it.",
  press:
    "Press only an allowlisted navigation key or reviewed shortcut: ArrowUp, ArrowDown, ArrowLeft, ArrowRight, PageUp, PageDown, Home, End, Tab, Escape, Enter, or Command+A/C/V.",
};

const toolSemantics: Record<string, string> = {
  structuredIntegration:
    "Use a registered service integration with typed parameters and its own approval policy.",
  nativeAccessibility:
    "Use native macOS APIs or Accessibility for the supplied app/control target.",
  visualComputerUse:
    "Use only a fresh authorized visual observation and bounded computer-control route.",
};

export function buildIntentQuestionsData(input: IntentQuestionInput) {
  const actionChoices = ["none", ...input.supportedActions];
  const toolChoices = ["none", ...input.supportedTools];
  const appChoices = [
    "none",
    ...(input.focusedAppBundleIdentifier === undefined ? [] : ["focused"]),
    ...input.targetCandidates
      .filter((candidate) => candidate.kind === "app")
      .map((candidate) => candidate.id),
  ].filter((choice, index, choices) => choices.indexOf(choice) === index);
  const targetChoices = [
    "none",
    ...input.targetCandidates.map((candidate) => candidate.id),
  ];
  const riskChoices = ["reversible", "confirm", "unsupported"] as const;
  const slotChoices = ["complete", "missing"] as const;
  const clarificationChoices = ["notNeeded", "needed", "abstain"] as const;

  return {
    intent: {
      choices: ["action", "clarify", "unsupported"],
      instructions:
        "intent-questions-v3: Choose the user's top-level Mac Control intent from the registered choices. Dictation is a separate shortcut and must never be represented here. Generic type, dictate, or write requests are unsupported; do not convert them into a text-insertion action. Treat missing referents, ambiguous corrections, compound requests, protected fields, and unresolved permissions as clarification or abstention rather than execution.",
      criteria: {
        action:
          "The user requests a registered Mac action with an identifiable supplied app, target, and required slots.",
        clarify:
          "The request is ambiguous, missing a referent or required field, combines actions, or needs one short question.",
        unsupported:
          "The request is generic dictation/text entry, outside the registered capabilities, or not an English Mac Control request.",
      },
    },
    app: {
      choices: appChoices,
      instructions:
        "Choose the explicitly named installed app candidate, the focused app when the request is clearly scoped to it, or none when the app is unresolved. Never infer an app from a sole unrelated candidate.",
      criteria: Object.fromEntries(
        appChoices.map((choice) => [
          choice,
          choice === "none"
            ? "No supplied app is a safe match."
            : choice === "focused"
              ? "The request clearly targets the currently focused application."
              : `The supplied installed application candidate ${choice} is explicitly named or resolved by a user alias.`,
        ]),
      ),
    },
    action: {
      choices: actionChoices,
      instructions:
        "Choose one registered Mac Control action from the bounded supported list, or none when no action is safe. Generic text entry is not a registered action. Compound requests and missing action arguments require none plus clarification.",
      criteria: Object.fromEntries(
        actionChoices.map((choice) => [
          choice,
          choice === "none"
            ? "No registered action can be selected safely."
            : actionSemantics[choice] ??
              `The request means the registered action ${choice}.`,
        ]),
      ),
    },
    tool: {
      choices: toolChoices,
      instructions:
        "Choose only a supplied registered execution route. This is a suggestion, not permission: deterministic policy recomputes the route, grant, approval, and whether visual context is required.",
      criteria: Object.fromEntries(
        toolChoices.map((choice) => [
          choice,
          choice === "none"
            ? "No supplied execution route is safe."
            : toolSemantics[choice] ?? `The supplied route ${choice} is available.`,
        ]),
      ),
    },
    target: {
      choices: targetChoices,
      instructions:
        "Choose one supplied target candidate, or none when unresolved. Match a named or verified recent referent; a sole candidate does not resolve it, that, or another deictic phrase by itself.",
      criteria: Object.fromEntries(
        targetChoices.map((choice) => [
          choice,
          choice === "none"
            ? "No supplied target is a safe match."
            : `The supplied candidate ${choice} is the explicitly named or verified recent target; do not choose it solely because it is the only candidate.`,
        ]),
      ),
    },
    requiredSlots: {
      choices: [...slotChoices],
      instructions:
        "Decide whether every required typed slot for the selected action is present in the supplied state. Choose missing for absent URL, file ID, recipient/draft, target, key, direction, role, label, or other required data. This answer never creates missing values.",
      criteria: {
        complete: "All required typed fields are present and bounded.",
        missing: "At least one required typed field is absent, ambiguous, or unsafe.",
      },
    },
    risk: {
      choices: [...riskChoices],
      instructions:
        "Suggest the action's risk class. Deterministic policy remains authoritative and may require confirmation or reject the action regardless of this suggestion.",
      criteria: {
        reversible:
          "The proposed action is local, bounded, and reversible without external disclosure.",
        confirm:
          "The action changes data, submits, sends, uploads, or otherwise requires explicit approval.",
        unsupported:
          "The requested effect is not safe or not registered.",
      },
    },
    clarification: {
      choices: [...clarificationChoices],
      instructions:
        "Choose whether a short clarification is needed. Choose abstain when the meaning or route is too uncertain to ask a useful targeted question. Do not treat confidence as permission.",
      criteria: {
        notNeeded: "The bounded request has one clear action, app, target, route, and complete slots.",
        needed: "One short user answer can resolve a missing or ambiguous field.",
        abstain: "The request is too uncertain, unsafe, or unsupported for a useful next question.",
      },
    },
  } satisfies Record<
    string,
    { choices: readonly string[]; instructions: string; criteria: Record<string, string> }
  >;
}

export type IntentQuestionData = ReturnType<typeof buildIntentQuestionsData>;
export type ShippedIntentQuestion = keyof IntentQuestionData;
export type ShippedIntentAction = IntentActionKind;
export type ShippedIntentTool = IntentToolKind;
