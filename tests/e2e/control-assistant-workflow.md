# Control assistant acceptance workflow

Use this checklist only with a freshly packaged local debug app. Record an item as passed only when the named observable result is seen; a unit test or source inspection is not runtime evidence.

## Safety setup

1. Disable real mail, upload, purchase, publication, and account-changing integrations. Use disposable local content.
2. Confirm the running bundle is `com.flowstate.dev`, signed with the stable development identity, and has Microphone and Accessibility access. Grant Screen Recording only for the visual-route cases.
3. Open TextEdit with a disposable document, Finder with a disposable folder, Brave with a local or disposable page, and one additional installed app.
4. Open FlowState's Tasks & history settings. Clear active control context and note the configured Dictation and Mac Control shortcuts.

Setup is complete when the four target apps are available, both shortcuts are visibly distinct, and FlowState reports the required permissions without changing any target content.

## Dictation boundary

1. Focus a non-secure TextEdit field, hold Dictation, say `Open Brave`, then release.
   - Pass: the literal words are inserted in the original field and Brave does not open.
2. Start Dictation in TextEdit, change focus to Notes before release, and wait for completion.
   - Pass: neither app receives text; the recovery card offers **Copy**, **Retry original field**, and **Dismiss**, and shows its expiry.
3. Copy a unique marker, dictate into TextEdit without changing the clipboard, and inspect the clipboard after insertion.
   - Pass: the text is inserted and the marker is restored.
4. Repeat while copying a different marker during transcription.
   - Pass: FlowState leaves the newer marker untouched.
5. Let a failed recovery card expire, then open Dictation history, copy the entry, delete it, and run delete-all with a second entry.
   - Pass: expired HUD content remains recoverable until deleted; per-item and delete-all affect only dictation history.

The boundary passes when no dictation case creates a control task, model route, screen capture, or Mac action.

## Conversational control

1. Hold Mac Control, say `Open Brave`, and release.
   - Pass: the registry resolves the installed bundle, the compact plan names Brave, Brave opens, verification observes Brave, and only then the assistant speaks a completion such as “Brave is open.”
2. Say `Type hello` with Mac Control.
   - Pass: no text is inserted and the assistant responds, “Use the Dictation shortcut to enter text.”
3. Trigger an ambiguous installed-app name or alias.
   - Pass: FlowState speaks and displays one bounded clarification; answering with the same shortcut resumes the original task.
4. Toggle mute, complete a short verified action, replay the last response, then select **New Task**.
   - Pass: muted completion remains visible but silent, replay speaks once, and New Task cannot resolve a follow-up from the prior task.
5. Inspect Control history and delete one entry, then all entries.
   - Pass: requests, reviewed plans, confirmations, outcomes, and failures are present with sensitive parameters redacted; raw audio and screenshots are absent.

The conversation passes when questions, failures, meaningful milestones, and verified completion are spoken according to policy and stale generations never speak success.

## Multi-app execution and cancellation

1. Request: `Open Brave, find the project page, then prepare a message with its URL.`
   - Pass: the visible plan spans registry-backed targets; every step shows route, target, typed parameters, verifier, risk, and approval state.
2. While a reversible step runs, move the pointer or type in an unrelated app without changing the planned target.
   - Pass: the task continues and reobserves before the next visible step.
3. Change the expected target before the next step.
   - Pass: the stale step does not execute; FlowState safely replans an obvious correction or asks a spoken clarification.
4. Reach the consequential message step.
   - Pass: FlowState pauses immediately before the exact effect and binds approval to unchanged arguments. No send occurs in this acceptance run.
5. Start a multi-step task and press the persistent **X** during a long step.
   - Pass: local and cloud generations invalidate, work stops at the next safe boundary, completed effects are reported honestly, and Undo is offered only for verified reversible effects.
6. Revoke Accessibility or disconnect the provider during a task.
   - Pass: execution fails closed, speaks a failure rather than completion, retains a redacted failure record, and cannot resume with expired approval or target state.

The workflow passes when only one visual plan controls the Mac, each step uses fresh state, retries cannot duplicate uncertain external effects, and X-to-stop latency is measured.

## Evidence record

For every run record the date, commit, bundle signature, app and macOS versions, transcript, route per step, approvals, observed verifier result, voice-to-first-action time, spoken-completion delay, X-to-stop time, Jev/model p50 and p95 for the evaluated suite, clarification count, unintended actions, and physical interventions. Record failures and disabled routes as failures or unavailable; preserve no raw audio, screenshots, secrets, or secure-field values.

