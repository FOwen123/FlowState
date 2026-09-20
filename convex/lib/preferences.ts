const MAX_VALUE_BYTES = 16_000;
const MAX_DEPTH = 8;

export function normalizePreferenceKey(key: string): string {
  const normalized = key.trim();
  if (!/^[A-Za-z][A-Za-z0-9_.:-]{0,127}$/.test(normalized)) {
    throw new Error("preference key must use 1-128 safe characters");
  }
  return normalized;
}

function assertSafeJson(value: unknown, depth: number): void {
  if (depth > MAX_DEPTH) throw new Error("preference value is too deeply nested");
  if (value === null || typeof value === "boolean" || typeof value === "number") {
    if (typeof value === "number" && !Number.isFinite(value)) {
      throw new Error("preference value contains a non-finite number");
    }
    return;
  }
  if (typeof value === "string") {
    if (value.length > 4_000) throw new Error("preference string is too long");
    return;
  }
  if (Array.isArray(value)) {
    if (value.length > 100) throw new Error("preference array is too large");
    for (const item of value) assertSafeJson(item, depth + 1);
    return;
  }
  if (typeof value === "object") {
    const entries = Object.entries(value);
    if (entries.length > 100) throw new Error("preference object is too large");
    for (const [key, item] of entries) {
      if (key === "__proto__" || key === "constructor" || key === "prototype") {
        throw new Error("preference contains a reserved key");
      }
      assertSafeJson(item, depth + 1);
    }
    return;
  }
  throw new Error("preference value must be JSON");
}

export function normalizePreferenceValue(valueJson: string): string {
  if (typeof valueJson !== "string" || valueJson.length === 0) {
    throw new Error("preference value must be JSON");
  }
  if (valueJson.length > MAX_VALUE_BYTES) {
    throw new Error("preference value exceeds the 16000-byte limit");
  }
  let value: unknown;
  try {
    value = JSON.parse(valueJson) as unknown;
  } catch {
    throw new Error("preference value must be valid JSON");
  }
  assertSafeJson(value, 0);
  return JSON.stringify(value);
}

export function parsePreferenceValue(valueJson: string): unknown {
  try {
    return JSON.parse(valueJson) as unknown;
  } catch {
    return null;
  }
}
