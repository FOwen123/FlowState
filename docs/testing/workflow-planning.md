# Complete-request planning

September 22, 2026. Mac Control keeps complete exact local commands and exact installed-app matches offline. Other utterances reach the managed planner intact. Prefixes such as `open`, `select`, and `research` must not consume the rest of a workflow as an app name, label, or research query. Dictation remains a separate shortcut; Stop and Cancel remain local.

The previous app-name interception was reproduced through the native speech consumer with eight compound requests. Before the fix, opening/searching asked for an app clarification, and selecting/copying dispatched a partial selection. The regression now requires the planning setup path and zero local input events. Signed-out and disabled-cloud failures are shown in the voice HUD.

The planner receives the full request, bounded task context, and advertised application/action capabilities. The foreground app is context, not an instruction to open that app. A clarification contains zero actions and cannot be approved. Unknown or unsupported steps must not produce an executable partial workflow.

## Live planner smoke check

The script makes four synthetic OpenAI requests through the production request builder and plan validator. It never executes a plan, sends mail, or uploads a screenshot:

```sh
pnpm exec esbuild scripts/check-workflow-planner.ts --bundle --platform=node --format=esm --outfile=/tmp/flowstate-planner-check.mjs
node /tmp/flowstate-planner-check.mjs --live
```

It uses the configured planner model and existing ignored environment file. It caps each response at 1,800 output tokens. `FLOWSTATE_PLANNER_REPORT` chooses the report path; the default is `/tmp/flowstate-plan-smoke.json`.

The initial run is preserved in `intent/workflow-planner-live-v1.json`: Brave search and browser/search/TextEdit passed; cross-app scrolling had reversed directions; zero-action clarification failed validation. After explicit direction examples and the clarification contract fix, all four checks passed in `intent/workflow-planner-live-v2.json`. These are development smoke checks, not an untouched holdout or proof that all workflows work.

The planner remains bounded by registered actions. File deletion, arbitrary visual interaction, and unrestricted application automation are not made available by routing a request to an LLM. Model decisions remain proposals, and existing execution validation, cancellation, per-step verification, and approval requirements still apply.

## Deployment mismatch found

The live development deployment initially advertised an older `plans:createActionPlan` accepting only `command`, `deviceId`, `expiresAt`, and `locale`. The current Mac sends capabilities, application candidates, and context revision as well; the old validator rejects that request before creating a plan. Local model checks do not establish successful app-to-Convex execution. The deployed version and native version must agree before live acceptance can pass.

## Native integration acceptance

On the Apple M5 Pro MacBook Pro (24 GB unified memory, macOS 26.6.2), the signed-in packaged development app completed a synthetic `Open Brave and search Hello World` request through Settings → Account → Prepare plan. The app reported `Plan completed`; Brave's active URL independently matched `search.brave.com` with query `Hello World`. This exercises the production planning and execution path, not microphone capture.

An unsupported compound request returned the planner's specific capability explanation in the UI with zero executable actions. The native empty-action resolution now reaches server clarification metadata without weakening the strict nonempty executable-plan decoder.

The development deployment was synced with `convex dev --once --typecheck disable --tail-logs disable`; no server/watch process or production deployment was started. Convex's own typecheck required a separate convex/tsconfig.json, so the existing root `pnpm typecheck` (which includes convex/) supplied typechecking instead.

Live debugging also exposed the Convex Swift 0.8.1 no-result overload: it decodes `String?`, while registration, grant, and execution endpoints return objects. Those ignored responses now use an object receipt decoder. Typed plan and external-effect responses retain their strict decoders. This fixed the failure between successful device registration and plan creation.

Disabling AI commands synchronously cancels pending preparation, invalidates the execution generation, revokes the local input grant, and requests server cancellation. A fresh research-prefixed request also obtains the automatic app context before planning; it no longer depends on a previous command's grant.
