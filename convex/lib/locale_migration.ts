import { isRecord } from "./http";

const localeFields = new Set([
  "language",
  "locale",
  "interfaceLanguage",
  "speechLanguage",
  "assistantLanguage",
  "interfaceLocale",
  "speechLocale",
  "assistantLocale",
]);

function migrateValue(value: unknown): { value: unknown; changed: boolean } {
  if (Array.isArray(value)) {
    let changed = false;
    const migrated = value.map((item) => {
      const result = migrateValue(item);
      changed ||= result.changed;
      return result.value;
    });
    return { value: migrated, changed };
  }
  if (!isRecord(value)) return { value, changed: false };
  let changed = false;
  const migrated: Record<string, unknown> = {};
  for (const [key, item] of Object.entries(value)) {
    if (localeFields.has(key) && item === "zh-Hant") {
      migrated[key] = "en";
      changed = true;
      continue;
    }
    const nested = migrateValue(item);
    migrated[key] = nested.value;
    changed ||= nested.changed;
  }
  return { value: migrated, changed };
}

export function migrateLegacyPreferenceValue(
  valueJson: string,
): string | undefined {
  let value: unknown;
  try {
    value = JSON.parse(valueJson) as unknown;
  } catch {
    return undefined;
  }
  const migrated = migrateValue(value);
  return migrated.changed ? JSON.stringify(migrated.value) : undefined;
}
