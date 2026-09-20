export function checkEnvironment(
  env: Record<string, string | undefined>,
  group: string,
): { group: string; missing: string[]; ready: boolean };
