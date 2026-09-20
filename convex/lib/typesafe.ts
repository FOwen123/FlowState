import {
  asBoundedText,
  FetchImplementation,
  isRecord,
  requestJson,
  requireApiKey,
} from "./http";

export type TypeSafeQuestion =
  | {
      type: "choice";
      instructions: string | Record<string, unknown> | unknown[];
      criteria: Record<
        string,
        string | Record<string, unknown> | unknown[] | null
      >;
    }
  | {
      type: "noul";
      instructions: string | Record<string, unknown> | unknown[];
      criteria?: {
        true?: string | Record<string, unknown> | unknown[];
        false?: string | Record<string, unknown> | unknown[];
      };
    }
  | {
      type: "score";
      instructions: string | Record<string, unknown> | unknown[];
      criteria: Array<string | Record<string, unknown> | unknown[]>;
    };

export type TypeSafeSystemOneRequest = {
  state: string | Record<string, unknown> | unknown[];
  model?: string;
  questions: Record<string, TypeSafeQuestion>;
};

export type TypeSafeSystemOneResponse = {
  model: string;
  answers: Record<string, Record<string, unknown>>;
  usage?: Record<string, number>;
};

type TypeSafeClientOptions = {
  apiKey?: string;
  baseUrl?: string;
  model?: string;
  fetch?: FetchImplementation;
};

function parseResponse(value: unknown): TypeSafeSystemOneResponse {
  if (
    !isRecord(value) ||
    typeof value.model !== "string" ||
    !isRecord(value.answers)
  ) {
    throw new Error("TypeSafe returned an invalid System One response");
  }
  const answers: Record<string, Record<string, unknown>> = {};
  for (const [key, answer] of Object.entries(value.answers)) {
    if (!isRecord(answer))
      throw new Error("TypeSafe returned an invalid answer");
    answers[key] = answer;
  }
  return {
    model: value.model,
    answers,
    ...(isRecord(value.usage)
      ? {
          usage: Object.fromEntries(
            Object.entries(value.usage).flatMap(([key, item]) =>
              typeof item === "number" ? [[key, item]] : [],
            ),
          ),
        }
      : {}),
  };
}

export function createTypeSafeClient(options: TypeSafeClientOptions) {
  const apiKey = requireApiKey(options.apiKey, "TypeSafe");
  const baseUrl = (options.baseUrl ?? "https://api.typesafe.ai/v1").replace(
    /\/$/,
    "",
  );
  const model = asBoundedText(options.model, "TypeSafe model", 100);
  const fetchImplementation = options.fetch ?? globalThis.fetch;

  return {
    async systemOne(
      request: TypeSafeSystemOneRequest,
    ): Promise<TypeSafeSystemOneResponse> {
      if (Object.keys(request.questions).length === 0) {
        throw new Error("TypeSafe questions cannot be empty");
      }
      const stateJson = JSON.stringify(request.state);
      if (stateJson.length > 200_000) {
        throw new Error("TypeSafe state exceeds the 200000-character limit");
      }
      const response = await requestJson(
        "typesafe",
        fetchImplementation,
        `${baseUrl}/systemone`,
        {
          method: "POST",
          headers: {
            Authorization: `Bearer ${apiKey}`,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({
            state: request.state,
            model: request.model ?? model,
            questions: request.questions,
          }),
        },
      );
      return parseResponse(response);
    },

    async chooseCandidate(input: {
      state: string | Record<string, unknown> | unknown[];
      candidates: Record<string, string>;
    }): Promise<{ choice: string; confidence?: number }> {
      const criteria = Object.fromEntries(
        Object.entries(input.candidates).map(([key, value]) => [key, value]),
      );
      const response = await this.systemOne({
        state: input.state,
        questions: {
          target: {
            type: "choice",
            instructions: "Which candidate best matches the user's request?",
            criteria,
          },
        },
      });
      const answer = response.answers.target;
      if (!answer || typeof answer.choice !== "string") {
        throw new Error("TypeSafe choice answer is missing choice");
      }
      if (!Object.hasOwn(input.candidates, answer.choice))
        throw new Error("TypeSafe selected an unknown candidate");
      if (
        answer.confidence !== undefined &&
        (typeof answer.confidence !== "number" ||
          !Number.isFinite(answer.confidence) ||
          answer.confidence < 0 ||
          answer.confidence > 1)
      ) {
        throw new Error("TypeSafe returned invalid confidence");
      }
      const confidence =
        typeof answer.confidence === "number" ? answer.confidence : undefined;
      return {
        choice: answer.choice,
        ...(confidence === undefined ? {} : { confidence }),
      };
    },
  };
}
