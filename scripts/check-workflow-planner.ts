import { writeFile } from "node:fs/promises";
import { buildPlannerRequest } from "../convex/lib/plan_request.ts";
import { createOpenAIClient } from "../convex/lib/openai.ts";
import {
  parsePlannerText,
  type PlanAvailability,
} from "../convex/lib/action_plan.ts";
if (!process.argv.includes("--live"))
  throw new Error(
    "Pass --live to run four synthetic planner requests. No actions are executed.",
  );
process.loadEnvFile(process.env.FLOWSTATE_EVALUATION_ENV_FILE ?? ".env.local");
const available: PlanAvailability = {
  supportedTools: ["nativeAccessibility", "structuredIntegration"],
  integrations: ["browser"],
  applicationCandidates: [
    {
      bundleIdentifier: "com.brave.Browser",
      displayName: "Brave",
      normalizedNames: ["brave"],
      supportedActions: ["openApplication", "openURL", "scroll", "press"],
      integrations: ["browser"],
    },
    {
      bundleIdentifier: "com.apple.TextEdit",
      displayName: "TextEdit",
      normalizedNames: ["textedit"],
      supportedActions: ["openApplication", "scroll", "press"],
      integrations: [],
    },
  ],
};
const client = createOpenAIClient({
  apiKey: process.env.OPENAI_API_KEY,
  model: process.env.FLOWSTATE_PLANNER_MODEL,
});
const cases = [
  { id: "brave-search", command: "Open Brave and search Hello World" },
  {
    id: "three-step",
    command: "Open Brave, search for indoor plants, then open TextEdit",
  },
  {
    id: "cross-app",
    command: "Open Brave, scroll down, then open TextEdit and scroll up",
  },
  {
    id: "unsupported-tail",
    command: "Open Brave and delete all files in my Downloads folder",
  },
];
const rows = [];
for (const c of cases) {
  const started = performance.now();
  try {
    const reply = await client.createResponse({
      ...buildPlannerRequest(c.command, available),
      maxOutputTokens: 1800,
    });
    const plan = parsePlannerText(reply.outputText, available);
    const actions = plan.actions;
    let passed = false;
    if (c.id === "brave-search")
      passed =
        !plan.clarificationNeeded &&
        actions.some(
          (a) =>
            a.kind === "openURL" &&
            a.targetBundleIdentifier === "com.brave.Browser" &&
            new URL(String(a.parameters.url)).searchParams.get("q") ===
              "Hello World",
        );
    if (c.id === "three-step")
      passed =
        !plan.clarificationNeeded &&
        actions.some(
          (a) =>
            a.kind === "openURL" &&
            new URL(String(a.parameters.url)).searchParams.get("q") ===
              "indoor plants",
        ) &&
        actions.at(-1)?.targetBundleIdentifier === "com.apple.TextEdit";
    if (c.id === "cross-app")
      passed =
        !plan.clarificationNeeded &&
        actions
          .filter((a) => a.kind === "scroll")
          .map((a) => a.parameters.lines)
          .join(",") === "-3,3" &&
        actions.at(-1)?.targetBundleIdentifier === "com.apple.TextEdit";
    if (c.id === "unsupported-tail")
      passed = plan.clarificationNeeded && actions.length === 0;
    rows.push({
      id: c.id,
      command: c.command,
      passed,
      latencyMs: Math.round(performance.now() - started),
      usage: reply.usage,
      plan,
    });
  } catch {
    rows.push({
      id: c.id,
      passed: false,
      error: "request or plan validation failed",
    });
  }
}
await writeFile(
  process.env.FLOWSTATE_PLANNER_REPORT ?? "/tmp/flowstate-plan-smoke.json",
  JSON.stringify(
    { model: process.env.FLOWSTATE_PLANNER_MODEL, executed: false, rows },
    null,
    2,
  ),
);
console.log(
  JSON.stringify(
    rows.map(({ id, passed, ...r }) => ({
      id,
      passed,
      latencyMs: "latencyMs" in r ? r.latencyMs : null,
    })),
  ),
);
if (rows.some((r) => !r.passed)) process.exitCode = 1;
