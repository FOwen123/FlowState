export type IntentQuestionInput = {
  supportedActions: readonly string[];
  targetCandidates: readonly { id: string }[];
};

const actionSemantics: Record<string, string> = {
  openApplication: "Open the named installed application using its app target and app.open capability.",
  scroll: "Scroll the focused target up or down by a bounded amount; do not invent a target.",
  focus: "Focus a supplied editable or control target by verified role or label.",
  select: "Select a named list item without activating it; 'choose' is not enough when activation is ambiguous.",
  press: "Press only an allowlisted keyboard key: ArrowUp, ArrowDown, ArrowLeft, ArrowRight, PageUp, PageDown, Home, End, Tab, Escape, Enter, or Command+A/C/V for Select All/Copy/Paste. A button click is not a keyboard press.",
  insertText: "Insert the user's literal text into the verified editable target; preserve Unicode and do not rewrite commands as text.",
  openURL: "Open a supplied HTTP(S) URL through the approved service route; never invent a URL.",
  attachFile: "Attach an already approved file identifier through the approved service route; never choose an arbitrary path.",
  sendEmail: "Send an already authorized draft through the approved service route; never generate recipient, subject, or body fields.",
};

export function buildIntentQuestionsData(input: IntentQuestionInput) {
  const actionChoices = ["none", ...input.supportedActions];
  const targetChoices = ["none", ...input.targetCandidates.map((candidate) => candidate.id)];
  return {
    intent: {
      choices: ["dictation", "action", "clarify", "unsupported"],
      instructions: "intent-questions-v2: Choose the user's top-level intent from the registered choices. Interpret English requests only; preserve non-English or Unicode content literally only when the user is dictating it. Treat missing referents, ambiguous corrections, compound requests, protected fields, and unresolved permissions as clarification rather than execution.",
      criteria: {
        dictation: "The user wants literal text inserted into the focused editable target, including prose containing command words.",
        action: "The user requests exactly one registered desktop or service action with an identifiable supplied target.",
        clarify: "The request is ambiguous, has a missing referent or argument, combines multiple actions, or needs one short question.",
        unsupported: "The request is outside the registered capabilities or is not an English command/dictation request.",
      },
    },
    action: {
      choices: actionChoices,
      instructions: "Choose the single registered action from the bounded supported list, or none when no action is safe. Do not select a sole candidate for a deictic request such as 'it' or 'that' without a named or recent referent. Compound requests and missing action arguments require none plus clarification.",
      criteria: Object.fromEntries(
        actionChoices.map((choice) => [
          choice,
          choice === "none" ? "No registered action can be selected safely." : actionSemantics[choice] ?? `The request means the registered action ${choice}.`,
        ]),
      ),
    },
    target: {
      choices: targetChoices,
      instructions: "Choose one supplied target candidate, or none when unresolved. Match a named or verified recent referent; a sole candidate does not resolve 'it', 'that', or another deictic phrase by itself.",
      criteria: Object.fromEntries(
        targetChoices.map((choice) => [
          choice,
          choice === "none"
            ? "No supplied target is a safe match."
            : `The supplied candidate ${choice} is the explicitly named or verified recent target; do not choose it solely because it is the only candidate.`,
        ]),
      ),
    },
  };
}
