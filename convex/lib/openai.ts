import {
  asBoundedText,
  FetchImplementation,
  isRecord,
  readString,
  requestJson,
  requireApiKey,
} from "./http";

export type OpenAIInput = string | Array<Record<string, unknown>>;

export type OpenAIResponseResult = {
  id: string;
  outputText: string;
};


type OpenAIClientOptions = {
  apiKey?: string;
  baseUrl?: string;
  model?: string;
  fetch?: FetchImplementation;
};

function parseOutputText(value: unknown): string {
  if (!isRecord(value)) {
    throw new Error("OpenAI returned an invalid response");
  }
  if (typeof value.output_text === "string") {
    return value.output_text;
  }
  if (!Array.isArray(value.output)) {
    throw new Error("OpenAI response is missing output text");
  }
  const chunks: string[] = [];
  for (const item of value.output) {
    if (!isRecord(item) || !Array.isArray(item.content)) {
      continue;
    }
    for (const part of item.content) {
      if (isRecord(part) && typeof part.text === "string") {
        chunks.push(part.text);
      }
    }
  }
  if (chunks.length === 0) {
    throw new Error("OpenAI response contains no output text");
  }
  return chunks.join("\n");
}

export function createOpenAIClient(options: OpenAIClientOptions) {
  const apiKey = requireApiKey(options.apiKey, "OpenAI");
  const baseUrl = (options.baseUrl ?? "https://api.openai.com/v1").replace(
    /\/$/,
    "",
  );
  const model = asBoundedText(options.model, "OpenAI model", 100);
  const fetchImplementation = options.fetch ?? globalThis.fetch;

  return {
    async createResponse(input: {
      input: OpenAIInput;
      instructions?: string;
      model?: string;
    }): Promise<OpenAIResponseResult> {
      const body: Record<string, unknown> = {
        model: input.model ?? model,
        input: input.input,
        store: false,
      };
      if (input.instructions !== undefined) {
        body.instructions = asBoundedText(
          input.instructions,
          "instructions",
          20_000,
        );
      }
      const response = await requestJson(
        "openai",
        fetchImplementation,
        `${baseUrl}/responses`,
        {
          method: "POST",
          headers: {
            Authorization: `Bearer ${apiKey}`,
            "Content-Type": "application/json",
          },
          body: JSON.stringify(body),
        },
      );
      if (!isRecord(response)) {
        throw new Error("OpenAI returned an invalid response");
      }
      return {
        id: readString(response.id, "id"),
        outputText: parseOutputText(response),
      };
    },

  };
}
