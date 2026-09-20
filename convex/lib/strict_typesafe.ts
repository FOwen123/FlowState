export type StrictTypeSafeQuestion = {
  choices: readonly string[];
};

export type StrictTypeSafeAnswer = {
  choice: string;
  confidence: number;
  probabilities: Record<string, number>;
  selectedProbability: number;
  topTwoMargin: number;
};

export type StrictTypeSafeResponse = {
  model: string;
  answers: Record<string, StrictTypeSafeAnswer>;
  usage?: Record<string, number>;
};

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function exactKeys(value: Record<string, unknown>, allowed: readonly string[], label: string): void {
  const expected = new Set(allowed);
  if (Object.keys(value).some((key) => !expected.has(key))) {
    throw new Error(`${label} contains unknown fields`);
  }
}

function parseStrictEnvelope(value: unknown): {
  model: string;
  answers: Record<string, Record<string, unknown>>;
  usage?: Record<string, number>;
} {
  if (!isRecord(value) || typeof value.model !== "string" || !isRecord(value.answers)) {
    throw new Error("TypeSafe returned an invalid System One response");
  }
  exactKeys(value, ["model", "answers", "usage"], "TypeSafe response");
  const answers: Record<string, Record<string, unknown>> = {};
  for (const [key, answer] of Object.entries(value.answers)) {
    if (!isRecord(answer)) throw new Error("TypeSafe returned an invalid answer");
    answers[key] = answer;
  }
  if (value.usage === undefined) return { model: value.model, answers };
  if (!isRecord(value.usage)) throw new Error("TypeSafe returned invalid usage");
  exactKeys(value.usage, ["input_tokens", "output_tokens", "total_tokens", "estimated_cost_usd"], "TypeSafe usage");
  const usage: Record<string, number> = {};
  for (const [key, item] of Object.entries(value.usage)) {
    if (typeof item !== "number" || !Number.isFinite(item) || item < 0) {
      throw new Error("TypeSafe returned invalid usage");
    }
    usage[key] = item;
  }
  return { model: value.model, answers, usage };
}

function exactChoiceKeys(
  value: Record<string, unknown>,
  choices: readonly string[],
  label: string,
): void {
  const expected = new Set(choices);
  const actual = Object.keys(value);
  if (actual.length !== expected.size || actual.some((key) => !expected.has(key))) {
    throw new Error(`${label} probabilities do not match the registered choices`);
  }
}

export function parseStrictTypeSafeResponse(
  value: unknown,
  questions: Record<string, StrictTypeSafeQuestion>,
): StrictTypeSafeResponse {
  const parsed = parseStrictEnvelope(value);
  const questionIds = Object.keys(questions);
  const answerIds = Object.keys(parsed.answers);
  if (
    answerIds.length !== questionIds.length ||
    answerIds.some((questionId) => !Object.hasOwn(questions, questionId))
  ) {
    throw new Error("TypeSafe answer question IDs do not match the request");
  }

  const answers: Record<string, StrictTypeSafeAnswer> = {};
  for (const questionId of questionIds) {
    const question = questions[questionId];
    const answer = parsed.answers[questionId];
    const allowedAnswerFields = new Set(["type", "questionId", "choice", "probabilities", "confidence"]);
    if (!answer || Object.keys(answer).some((key) => !allowedAnswerFields.has(key))) {
      throw new Error(`TypeSafe answer for ${questionId} contains unknown fields`);
    }
    if (answer.type !== "choice") throw new Error(`TypeSafe answer for ${questionId} is not a choice`);
    if (answer.questionId !== undefined && answer.questionId !== questionId) {
      throw new Error(`TypeSafe answer question ID mismatch for ${questionId}`);
    }
    if (typeof answer.choice !== "string" || !question.choices.includes(answer.choice)) {
      throw new Error(`TypeSafe answer for ${questionId} selected an unknown choice`);
    }
    if (!isRecord(answer.probabilities)) {
      throw new Error(`TypeSafe answer for ${questionId} has invalid probabilities`);
    }
    exactChoiceKeys(answer.probabilities, question.choices, `question ${questionId}`);
    const probabilities: Record<string, number> = {};
    let total = 0;
    for (const choice of question.choices) {
      const probability = answer.probabilities[choice];
      if (
        typeof probability !== "number" ||
        !Number.isFinite(probability) ||
        probability < 0 ||
        probability > 1
      ) {
        throw new Error(`TypeSafe answer for ${questionId} has invalid probabilities`);
      }
      probabilities[choice] = probability;
      total += probability;
    }
    if (Math.abs(total - 1) > 0.001) {
      throw new Error(`TypeSafe answer for ${questionId} probabilities do not sum to one`);
    }
    if (
      typeof answer.confidence !== "number" ||
      !Number.isFinite(answer.confidence) ||
      answer.confidence < 0 ||
      answer.confidence > 1
    ) {
      throw new Error(`TypeSafe answer for ${questionId} has invalid confidence`);
    }
    const selectedProbability = probabilities[answer.choice];
    const sorted = Object.values(probabilities).sort((a, b) => b - a);
    if (selectedProbability !== sorted[0]) {
      throw new Error(`TypeSafe answer for ${questionId} contradicts its probabilities`);
    }
    answers[questionId] = {
      choice: answer.choice,
      confidence: answer.confidence,
      probabilities,
      selectedProbability,
      topTwoMargin: selectedProbability - (sorted[1] ?? 0),
    };
  }
  return {
    model: parsed.model,
    answers,
    ...(parsed.usage === undefined ? {} : { usage: parsed.usage }),
  };
}
