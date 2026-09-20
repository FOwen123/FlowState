export type JsonObject = { [key: string]: JsonValue };
export type JsonValue =
  null | boolean | number | string | JsonValue[] | JsonObject;

export type FetchImplementation = typeof fetch;

export class ProviderError extends Error {
  readonly provider: string;
  readonly status: number;

  constructor(provider: string, status: number) {
    super(`${provider} request failed with HTTP ${status}`);
    this.name = "ProviderError";
    this.provider = provider;
    this.status = status;
  }
}

export function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export function readString(value: unknown, field: string): string {
  if (typeof value !== "string" || value.length === 0) {
    throw new Error(`Provider response is missing ${field}`);
  }
  return value;
}

export async function readJson(response: Response): Promise<unknown> {
  const reader = response.body?.getReader();
  if (!reader) return null;
  const chunks: Uint8Array[] = [];
  let size = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > 1_048_576) {
        await reader.cancel();
        throw new Error("Provider response exceeds byte limit");
      }
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  const text = new TextDecoder().decode(bytes);
  if (!text) return null;
  try {
    return JSON.parse(text) as unknown;
  } catch {
    throw new Error("Provider returned invalid JSON");
  }
}

export async function requestJson(
  provider: string,
  fetchImplementation: FetchImplementation,
  url: string,
  init: RequestInit,
): Promise<unknown> {
  let response: Response;
  const timeout = AbortSignal.timeout(30_000);
  try {
    response = await fetchImplementation(url, {
      ...init,
      signal: init.signal ? AbortSignal.any([init.signal, timeout]) : timeout,
    });
  } catch {
    // A network failure may occur after a provider accepted a request.
    throw new ProviderError(provider, 0);
  }
  if (!response.ok) {
    await response.body?.cancel();
    throw new ProviderError(provider, response.status);
  }
  return readJson(response);
}

export function requireApiKey(
  apiKey: string | undefined,
  provider: string,
): string {
  if (typeof apiKey !== "string" || apiKey.trim().length === 0) {
    throw new Error(`${provider} API key is not configured`);
  }
  return apiKey.trim();
}

export function asBoundedText(
  value: unknown,
  field: string,
  maxLength: number,
): string {
  if (typeof value !== "string" || value.trim().length === 0) {
    throw new Error(`${field} must be a non-empty string`);
  }
  const result = value.trim();
  if (result.length > maxLength) {
    throw new Error(`${field} exceeds the ${maxLength}-character limit`);
  }
  return result;
}
