import { pathToFileURL } from "node:url";
const groups = {
  web: ["VITE_CONVEX_URL", "VITE_CLERK_PUBLISHABLE_KEY"],
  backend: [
    "CLERK_JWT_ISSUER_DOMAIN",
    "FIRECRAWL_API_KEY",
    "OPENAI_API_KEY",
    "AGENTMAIL_API_KEY",
    "TYPESAFE_API_KEY",
    "FLOWSTATE_AGENTMAIL_INBOX_ID",
    "FLOWSTATE_ALLOWED_TEST_RECIPIENTS",
    "FLOWSTATE_PLANNER_MODEL",
    "FLOWSTATE_JEV_MODEL",
  ],
};
export function checkEnvironment(env, group) {
  if (!(group in groups)) throw new Error("Choose web or backend");
  const missing = groups[group].filter((name) => !env[name]?.trim());
  return { group, missing, ready: missing.length === 0 };
}
if (
  process.argv[1] &&
  import.meta.url === pathToFileURL(process.argv[1]).href
) {
  const group = process.argv[2] || "backend";
  try {
    const result = checkEnvironment(process.env, group);
    console.log(
      result.ready
        ? `${group}: required values present (credentials not validated)`
        : `${group}: missing ${result.missing.join(", ")}`,
    );
    process.exitCode = result.ready ? 0 : 1;
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
