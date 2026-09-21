# Flowstate dictation and Mac assistant TODO

Status: implemented and verified on local `main`. This plan supersedes the single-shortcut/Auto-mode direction. Checked Jev stages mean their evaluation loop completed; stages that missed a release gate remain disabled.

## Locked outcome

- Ship exactly two independently configurable, hold-only shortcuts: **Dictation** and **Mac Control**. Migrate the existing shortcut to Mac Control; default Dictation to Option-Space unless registration conflicts.
- Dictation captures the focused editable field at key-down, transcribes and conservatively cleans speech, then pastes only into that same non-secure field. It never calls Jev, screen capture, planning, or control routing.
- Mac Control never falls back to dictation or generic typing. Text is allowed only as a typed parameter of a registered action, such as a URL query, filename, recipient, or reviewed message draft.
- Mac Control is a task-scoped conversational assistant. It remembers follow-ups, speaks questions/milestones/failures/completion aloud, shows a compact live plan, and exposes a persistent **X** that cancels execution.
- Prefer structured integrations, then native APIs/Accessibility, then fresh visual observation and bounded computer control.
- Compound goals may span applications. Reobserve and verify before every step. Unrelated physical input does not cancel the task; changed target state triggers safe replanning or clarification.
- Jev selects only bounded values. OpenAI may generate prose and typed plans. Deterministic Swift/TypeScript code owns permissions, approval, execution, cancellation, and verification.
- Keep local dictation/control history for 30 days by default. Store no raw audio or screenshots; never store secure-field content.

## Non-negotiable implementation loop

For every code slice: add a behavioral test, observe it fail, implement the minimum change, run the focused test, then run the affected suite. Preserve concurrent work in `FlowStateApp.swift` and `AutomaticTargetTests.swift`; reconcile it before editing those files.

Every new Jev responsibility also passes this gate before the next stage:

1. Add grouped development/calibration/holdout cases without paraphrase leakage.
2. Run deterministic contract tests and a bounded live comparison against the route being replaced.
3. Record exact-choice correctness, consequential false-execution count, abstention/clarification rate, p50/p95 model latency, end-to-end latency, token usage, and cost.
4. Freeze prompts and thresholds before untouched holdout evaluation.
5. Adopt the Jev stage only when contract validity is 100%, the holdout has no accepted consequential wrong action, correctness is at least as good as the baseline, and p95 is faster than the replaced route. Otherwise keep the baseline and document the failed gate.

The current measured Jev routing reference is `jev-1.13.0`, prompt `intent-questions-v2`: holdout p50 278 ms, p95 324 ms, with only 15/80 rows accepted by the review gate. These figures are a comparison baseline, not a release target or automatic-execution claim.

## 0. Align authority and baseline

Files:

- Modify `PRODUCT.md`, `AGENTS.md`, `PLAN.md`, `docs/privacy.md`.
- Update `docs/testing/results.md` only with completed evidence.

TODO:

- [x] Replace Auto/Dictation/Commands mode selection, toggle, and wake-phrase scope with the two hold-only shortcut contract.
- [x] Replace "physical input pauses" with this rule: unrelated input may continue; every step reobserves; target divergence replans or clarifies; **X** is the authoritative user cancellation path.
- [x] Document spoken assistant output, task-scoped conversation, separate histories, clipboard insertion, and control-mode text prohibition.
- [x] Reconcile `main` with `origin/main` and the concurrent uncommitted speech-finalization changes before implementation. Preserve user work.
- [x] Capture the pre-change green baseline with `pnpm test`, `pnpm typecheck`, and `swift test --package-path apps/macos`.

Exit: the authority documents describe one consistent product, and baseline failures are recorded before feature changes.

## 1. Split activation by purpose

Files:

- Modify `apps/macos/Sources/FlowStateCore/SpeechSession.swift`.
- Modify `apps/macos/Sources/FlowStateCore/InputMonitors.swift`.
- Modify `apps/macos/Sources/FlowStateApp/FlowStateApp.swift`.
- Modify `apps/macos/Sources/FlowStateApp/FlowStateSettingsView.swift` and `Resources/en.lproj/Localizable.strings`.
- Modify `apps/macos/Tests/FlowStateCoreTests/InputMonitorTests.swift`, `SpeechLifecycleTests.swift`, and `apps/macos/Tests/FlowStateAppTests/SettingsDesignTests.swift`.

TODO:

- [x] Add `SpeechSessionPurpose.dictation` and `.control`; bind it at key-down and carry it through every transcript/result callback.
- [x] Replace `SpeechSettings.shortcut`, `mode`, `activation`, and wake settings with `dictationShortcut` and `controlShortcut`.
- [x] Decode legacy settings by assigning the existing shortcut to Mac Control and selecting a non-conflicting Dictation default. Persist the migrated value once.
- [x] Register two `GlobalVoiceShortcutMonitor`s. Reject identical shortcuts and registration conflicts visibly.
- [x] Hold starts capture; release finalizes once. Remove toggle/wake behavior and settings without disturbing local Stop/cancellation generation.
- [x] Show which purpose is listening in the HUD and settings accessibility labels.

Tests first:

- [x] Each shortcut starts only its assigned purpose; key repeat cannot start a second session.
- [x] Releasing one shortcut cannot finish the other purpose.
- [x] Duplicate/conflicting shortcuts fail without leaving a partial monitor registration.
- [x] Legacy settings migrate without erasing vocabulary, aliases, grants, or history.

Exit: two remappable hold-only shortcuts work independently; no downstream code infers purpose from transcript text.

## 2. Build the isolated dictation path

Files:

- Add `apps/macos/Sources/FlowStateCore/DictationOutputController.swift`.
- Add `apps/macos/Sources/FlowStateApp/DictationHistoryStore.swift`.
- Add `apps/macos/Tests/FlowStateCoreTests/DictationOutputTests.swift`.
- Add `apps/macos/Tests/FlowStateAppTests/DictationHistoryTests.swift`.
- Modify `apps/macos/Sources/FlowStateApp/FlowStateApp.swift`, `VoiceHUD.swift`, `FlowStateSettingsView.swift`, and `apps/macos/Sources/FlowStateCore/Personalization.swift`.
- Modify `apps/macos/Sources/FlowStateCore/DesktopControl.swift` only to reuse focused-element observation/identity checks; keep control execution separate.
- Add `convex/dictation.ts` and `tests/backend/dictation.test.ts` only when managed cleanup is enabled; reuse `convex/lib/openai.ts`.
- Extend `FlowStateCloud/CloudSession.swift` and its tests for the cleanup request if that endpoint is added.

TODO:

- [x] At key-down, capture app bundle, focused AX element identity, role, editability, secure state, selection, and clipboard change count. Reject missing/non-editable/secure targets immediately.
- [x] On release, apply explicit vocabulary plus conservative cleanup: punctuation, capitalization, fillers, false starts, list formatting, and number/spoken-punctuation normalization while preserving meaning and claims.
- [x] Add configurable cleanup enablement and editable cleanup instructions. Treat transcript text as untrusted data; cleanup instructions cannot authorize actions.
- [x] If cleanup is unavailable or times out, offer the raw transcript instead of losing it.
- [x] Immediately before insertion, verify the same app, element, and selection. On drift, skip insertion and show a 30-second recovery card with **Copy**, **Retry original field**, and **Dismiss**.
- [x] Implement Wispr/Handy-style paste: snapshot the clipboard, write a private uniquely identified transcript item, paste, wait for target consumption, and restore only if the clipboard still contains Flowstate’s item. Never overwrite clipboard data copied by the user during transcription.
- [x] Save final text and failure reason to local history immediately; discard audio after transcription. Add copy, per-item delete, delete-all, and configurable retention (default 30 days).
- [x] Dictation must bypass `VoiceCommandRouter`, `routeIntent`, Jev, plan creation, screen capture, and desktop-control actions.

Tests first:

- [x] Same-field insertion succeeds and restores the clipboard.
- [x] Focus/app/selection change, secure field, paste failure, user clipboard race, cancellation, and late cleanup response never paste into another target.
- [x] Failed text survives HUD expiry in history; retention deletion removes only expired local entries.
- [x] A transcript containing "open," "send," "delete," or prompt-like instructions remains text and causes no action/model route.

Exit: Dictation is a predictable text-entry product with recovery and history, independent of Mac Control.

## 3. Enforce the Mac Control boundary

Files:

- Modify `apps/macos/Sources/FlowStateCore/VoiceCommandRouter.swift`, `IntentDecision.swift`, `NativePlan.swift`, and `DesktopControl.swift`.
- Modify `apps/macos/Sources/FlowStateApp/FlowStateApp.swift`, `apps/macos/Sources/FlowStateCloud/IntentRequest.swift`, and `apps/macos/Sources/FlowStateCloud/CloudSession.swift`.
- Modify `convex/lib/intent_contract.ts`, `intent_questions.ts`, `intent_policy.ts`, `action_plan.ts`, `convex/intents.ts`, and `convex/plans.ts`.
- Modify `VoiceCommandTests.swift`, `IntentDecisionTests.swift`, `NativePlanTests.swift`, `IntentExecutionTests.swift`, `IntentRequestTests.swift`, `tests/backend/intent-routing.test.ts`, and `tests/backend/intents-convex.test.ts`.

TODO:

- [x] Remove dictation as a control intent and remove `insertText` from control-supported actions, plan vocabulary, grants, and executor dispatch.
- [x] Return one consistent assistant response for `type`, `dictate`, or `write`: "Use the Dictation shortcut to enter text."
- [x] Reject `insertText` again when decoding cloud responses and immediately before execution. A compromised/stale backend response cannot cross the boundary.
- [x] Keep explicit text only in typed registered parameters such as `openURL(query/url)`, `renameFile(name)`, `draftMessage(recipient/body)`, or other reviewed service actions. Never turn an unknown utterance into a keyboard-writing action.
- [x] Keep Enter/send/submission and external side effects behind deterministic approval policy.

Exit: no control-originated path can produce generic text insertion, including local commands, Jev, OpenAI plans, replayed plans, or executor calls.

## 4. Create the application registry and first Jev stage

Files:

- Add `apps/macos/Sources/FlowStateApp/ApplicationRegistry.swift`.
- Add `apps/macos/Tests/FlowStateAppTests/ApplicationRegistryTests.swift`.
- Modify `apps/macos/Sources/FlowStateApp/ApplicationCatalog.swift`, `apps/macos/Sources/FlowStateCore/Personalization.swift`, `apps/macos/Sources/FlowStateApp/FlowStateApp.swift`, `apps/macos/Sources/FlowStateCloud/IntentRequest.swift`, and `apps/macos/Sources/FlowStateCloud/CloudSession.swift`.
- Modify `convex/lib/intent_contract.ts`, `intent_questions.ts`, `intent_policy.ts`, and `convex/intents.ts`.
- Extend `tests/fixtures/intent/en.json`, `scripts/evaluate-intent.ts`, `tests/backend/intent-corpus.test.ts`, and `docs/testing/intent-evaluation.md`.

TODO:

- [x] Index installed/running apps using LaunchServices/NSWorkspace plus existing catalog roots; store bundle ID, display name, normalized names, user aliases, running state, supported native actions, and available structured integrations.
- [x] Resolve an exact unique name/alias deterministically. Ambiguous and unknown names produce clarification; aliases never grant permission.
- [x] Prefilter the registry locally before Jev so candidate count stays bounded and below Jev’s 255-choice limit.
- [x] In one Jev request, select app, action/tool, target, required-slot presence, risk suggestion, and clarification need. Deterministic policy independently recomputes permission and confirmation.
- [x] Supply only redacted textual candidates; screenshots and arbitrary app contents never enter Jev.
- [x] Cover closed apps and examples such as "Open Brave," duplicate display names, alias collisions, renamed apps, missing apps, and English ASR errors.
- [x] Run the Jev gate against the current routing report. Do not enable automatic cloud execution from this evaluation; retain review until evidence supports a separate policy change.

Exit: any uniquely named installed app can be grounded without hardcoded Brave/Safari cases, and the accepted Jev route is both correct and faster than the compared fallback.

## 5. Add the conversational spoken assistant

Files:

- Add `apps/macos/Sources/FlowStateCore/ControlConversationSession.swift`.
- Add `apps/macos/Sources/FlowStateApp/SpokenResponseController.swift`.
- Add `apps/macos/Sources/FlowStateApp/ControlHistoryStore.swift`.
- Add matching `ControlConversationTests.swift`, `SpokenResponseTests.swift`, and `ControlHistoryTests.swift`.
- Modify `apps/macos/Sources/FlowStateApp/FlowStateApp.swift`, `VoiceHUD.swift`, `FlowStateSettingsView.swift`, `Localization.swift`, and `Resources/en.lproj/Localizable.strings`.
- Modify `apps/macos/Sources/FlowStateCloud/IntentRequest.swift` and `CloudSession.swift` to populate existing `recentInteraction` with a bounded redacted summary.

TODO:

- [x] Keep a stable control-conversation ID across hold-to-talk activations for one task. Store bounded turns, unresolved clarification, original request, latest verified result, and approval state.
- [x] A follow-up may resolve a pending question or refer to verified task state; it cannot reuse expired grants, approvals, targets, or screenshots.
- [x] Add `AVSpeechSynthesizer` output using the selected macOS voice. Speak questions, meaningful long-task milestones, failures, and final completion; short successful tasks speak only completion.
- [x] Speak in the task's supported language. The current release remains English-only; keep locale in the response contract so future languages do not require a TTS redesign.
- [x] Summarize sensitive results generically. Never speak passwords, one-time codes, secure-field content, or full private message/account contents.
- [x] Add visible mute, replay-last-response, current listening state, compact plan, current step, and persistent **X** controls. Visual confirmation remains available while muted.
- [x] Keep local control history: request, approved plan, confirmations, step outcomes, and failure reason. Exclude raw audio/screenshots and redact sensitive parameters.
- [x] Clear active conversational context on X, sign-out, expiry, or explicit New Task; reject late replies from an earlier conversation generation.

Tests first:

- [x] Clarification → hold shortcut → answer resumes the same request.
- [x] New Task, X, sign-out, and expiry cannot inherit old referents or approvals.
- [x] Spoken completion happens only after verified completion; cancelled/failed work never says it succeeded.
- [x] Sensitive values are visible only where permitted and are not spoken or persisted.

Exit: "Open Brave" produces a grounded action and a verified spoken response such as "Brave is open," with usable follow-up context.

## 6. Connect multi-step, cross-app control

Files:

- Modify `apps/macos/Sources/FlowStateApp/FlowStateApp.swift`, `CloudAccountView.swift`, `apps/macos/Sources/FlowStateCloud/CloudSession.swift`, `apps/macos/Sources/FlowStateCore/NativePlan.swift`, and `DesktopControl.swift`.
- Modify `convex/plans.ts`, `executions.ts`, `schema.ts`, `lib/action_plan.ts`, `lib/policy.ts`, and `retention.ts`.
- Modify `NativePlanTests.swift`, `CloudPlanValidityTests.swift`, `IntentExecutionTests.swift`, `DesktopSafetyReviewTests.swift`, `tests/backend/executions.test.ts`, `policy.test.ts`, and `workflows.test.ts`.
- Add `tests/e2e/control-assistant-workflow.md`.

TODO:

- [x] Route compound control goals from the shortcut into the existing reviewed plan path instead of returning single-action clarification.
- [x] Extend plans from one bundle to multiple registry-backed targets. Every step names action, route, target, typed parameters, preconditions, verifier, risk, approval need, reversal support, and expiry.
- [x] Choose execution route in order: structured integration → native API/Accessibility → current-window visual observation and bounded computer control.
- [x] Reobserve immediately before every visible step. Unrelated physical input continues; changed expected state triggers bounded replanning when the correction is obvious, otherwise a spoken clarification. Never execute a stale step.
- [x] Show the whole compact plan. Run low-risk reversible steps automatically; pause immediately before exact consequential steps and bind approval to unchanged arguments.
- [x] Keep external effects idempotent. Reconcile uncertain send/submit/upload results before retrying.
- [x] Make **X** invalidate local/cloud generations and stop at the next safe boundary. Report completed effects; offer explicit Undo only for verified reversible actions.
- [x] Keep injected-event filtering so Flowstate does not treat its own events as user edits. Prevent concurrent visual plans from controlling the same Mac.

Exit: a request such as "Open Brave, find the project page, then prepare a message with its URL" runs as a visible, verified, cancellable cross-app plan without generic typing or stale-screen actions.

## 7. Expand Jev only through measured stages

Files:

- Modify `convex/lib/intent_questions.ts`, `intent_contract.ts`, `intent_policy.ts`, `strict_typesafe.ts`, and `convex/intents.ts`.
- Extend `tests/fixtures/intent/en.json`; add `tests/fixtures/control-decisions/en.json` for step/memory/result cases.
- Extend `scripts/evaluate-intent.ts` with named suites rather than creating separate provider clients.
- Modify `tests/backend/intent-routing.test.ts`, `intents-convex.test.ts`, and `intent-corpus.test.ts`.
- Record each accepted/rejected stage in `docs/testing/intent-evaluation.md` and sanitized reports under `docs/testing/intent/`.

Stages, each independently gated:

- [x] **A. Missing slots and risk suggestion.** Jev flags absent required fields and proposes `reversible`, `confirm`, or `unsupported`; deterministic policy stays authoritative.
- [x] **B. Plan-step validation.** After OpenAI proposes a step, Jev selects whether it matches the original intent/current bounded candidates. Dependent steps use a new request with updated verified state.
- [x] **C. Memory ranking.** Jev ranks a bounded set of redacted task memories/aliases; storage, privacy, and writes remain local policy.
- [x] **D. Result validation.** Jev selects whether a textual observation satisfies the requested outcome; native verifiers remain authoritative where exact checks exist.
- [x] **E. Route/model selection.** Jev selects deterministic handler, structured integration, planner, vision, clarification, or unsupported from registered options.

Exit: every shipped Jev role has its own untouched holdout result and is correct and faster than the route it replaces. Failed stages remain disabled and documented.

## 8. Retention, migrations, and release verification

Files:

- Modify `convex/schema.ts`, `retention.ts`, `history.ts`, and corresponding backend tests only for redacted server records that are actually needed.
- Modify `docs/privacy.md`, `README.md`, `apps/macos/README.md`, `docs/testing/results.md`, and `tests/e2e/navigation-english.md`.
- Add migration tests beside the affected native settings/history and Convex schema code.

TODO:

- [x] Add idempotent migrations for legacy shortcut/mode/activation settings and old control plans containing `insertText`.
- [x] Default local dictation/control retention to 30 days; support per-item deletion and delete-all. Keep raw audio/screenshots ephemeral.
- [x] Keep remote records redacted and minimal; schedule/test retention before claiming automatic deletion.
- [x] Run focused tests after each phase, then `swift test --package-path apps/macos`, `pnpm test`, `pnpm typecheck`, and `pnpm format:check`.
- [x] Perform manual Mac acceptance in TextEdit, Finder, Brave, and one additional installed app: both shortcuts, clipboard restoration, changed focus, multi-step plan, clarification follow-up, spoken response/mute, risk approval, X cancellation, user input during automation, permission revocation, provider outage, and history deletion.
- [x] Measure end-to-end voice-to-first-action, Jev p50/p95, planner latency, spoken completion delay, X-to-stop latency, clarification rate, unintended actions, and physical interventions.
- [x] Record only observed results in `docs/testing/results.md`; unavailable or failed capabilities remain disabled.

Final acceptance:

- Dictation always means text for the field captured at activation; it never controls the Mac.
- Mac Control always means assistant action; it never silently types the utterance.
- "Open Brave" resolves any uniquely installed app through the registry and reports verified completion aloud.
- Multi-step work is visible, risk-gated, reobserved, cancellable with X, and honest about completed/irreversible effects.
- Each shipped Jev role has held-out correctness and latency evidence showing it is the better route for that bounded decision.
