# Implementation and verification record

## September 20, 2026 — core development, codex/flowstate-foundation

Computer: MacBook Pro, Apple M5 Pro (15 CPU cores), 24 GB unified memory, macOS 26.6.2 (25G83). Tools: Xcode 27.0, Swift 6.4, Node 24.15.0, pnpm 11.10.0. Inventory checked locally. No pull request or production deployment created.

Sections 1–11 of PLAN.md are not complete. Remaining work includes core behavior and acceptance, not just polish. The native package now requires macOS 26.2 or newer; other hardware/OS combinations are unverified.

## Implemented slices

- Native menu/settings UI, Apple SpeechAnalyzer capture, English/Traditional Chinese command routing, push-to-talk/toggle/wake configuration, local stop, explicit per-app input/capture grants, interruption checks and text undo.
- Strict reviewed cloud-plan bridge for opening an app, bounded scrolling and text insertion. Server reservations prevent replay; uncertain/cancelled outcomes stay distinct. Other proposed action kinds are rejected by the current native bridge.
- Official Clerk/Convex Swift integration and web login wiring. Real signed-in login has not been exercised.
- Account-scoped devices, grants, explicit preferences, usage counters, deletion/retention functions and workflow state.
- Paper-derived web landing/workspace and native settings palette. Web memory, permissions and privacy controls; local native vocabulary/app-alias application. Cross-device memory synchronization remains pending.
- Public research through Firecrawl and managed models; exact assistant-email review, durable attempts and signed delivery receipts.

## Automated checks

| Check | Evidence |
|---|---|
| `pnpm test` | 75 tests passed across 15 files |
| `pnpm typecheck` | Passed |
| `pnpm test:browser` | 3 Chromium tests passed; in-memory bundles, no dev server |
| `pnpm test:native` | 64 core tests reported (two opt-in OS tests skipped), 5 cloud and 2 app lifecycle tests passed; earlier opt-in live test passed separately |
| `pnpm format:check` | Passed for its configured paths; no separate lint script exists |
| `git diff --check` | Passed |
| Local debug packaging | Already-compiled executable packaged with usage descriptions/public config; Apple Development codesign verification passed; signature identity now remains stable across rebuilds |
| Debug launch | Updated packaged process started successfully after one launch-services retry; microphone retry requested with Control–Shift–Space |
| Opt-in real TextEdit test | Passed: activate from another app, insert English/Traditional Chinese text, restore exact prior text, observe a changed scrollbar value |

Behavioral regressions were observed failing before fixes, including sender-review binding, cancellation during speech preparation, symlink file-boundary escape, final transcript handling, duplicate native execution and cancellation of reserved cloud steps. See test sources for assertions. Synthetic tests do not access private screens/audio or inject live desktop input.

## Live development services

Convex development deployment `blissful-capybara-761` was provisioned and pushed with a one-shot development CLI command. Actual generated API/types are present. This was not a production deploy or a persistent development server.

- Firecrawl extracted the public example.com page.
- TypeSafe/Jev returned a bounded command candidate for English/Traditional Chinese fixture input.
- OpenAI returned generated text.
- A live managed plan produced reviewed open-application and scroll actions. The first probe failed safely because the model omitted the scroll target; clarifying the per-action schema fixed the repeat. The successful proposal was discarded without native execution.
- AgentMail inbox access succeeded after the owner updated the key.
- Real Convex public research produced a sourced bilingual example.com note.
- One explicitly authorized, clearly labeled test message was sent to the approved recipient. Provider acceptance and signed `message.sent` / `message.delivered` events were verified. Delivery means recipient-server acceptance, not inbox placement or reading. Do not repeat the send without new authorization.

The live workflow used a synthetic administrator CLI identity for integration testing, not a real Clerk login. It establishes service wiring and delivery, not end-user authentication acceptance. The AgentMail webhook is inbox-scoped, validates Svix signatures/timestamps and deduplicates events; only event metadata is retained.

The signed-out configured Clerk web assets loaded through an in-memory browser route without page errors. Native hosted auth compiled; interactive auth remains untested.

## Speech evidence

Apple's English speech asset was present. The Traditional Chinese asset was installed through AssetInventory. Both short synthetic file probes transcribed successfully. English analyzer time was approximately 0.182 s and zh-TW 0.173 s. CLI peak RSS was about 198 MB, excluding Apple's external speech service. These are not total model-memory or microphone-latency measurements. See [speech evaluation](speech-evaluation.md).

## Menu and microphone debugging

The gear button returned Accessibility success without opening Settings. Replacing SettingsLink with an explicit app activation and openSettings action made the same live check pass. Voice settings and the menu now display the transcript; a nonactivating floating panel shows preparing/listening/errors with Finish/Stop controls. Its waveform indicates session activity, not measured microphone loudness.

The real app crash before the audio-tap fix was EXC_BREAKPOINT in `_swift_task_checkIsolatedSwift`, on `RealtimeMessenger.mServiceQueue`, in `AnalyzerSpeechCapture.start`'s tap closure. After the callback became explicitly `@Sendable`, the same live Start/Stop path survived and displayed Listening. The language asset was installed from the packaged app, not inferred from CLI availability.

Reproduction/acceptance commands: `FLOWSTATE_UI_SMOKE=1 swift scripts/macos-menu-smoke.swift settings` and the explicit `voice` variant. The latter briefly activates the microphone and presses Stop; use it only with local/provider action grants disabled. It logs no transcripts. No real speech quality, focus-preservation or complete workflow claim follows from this short check.

## Remaining acceptance and implementation

The owner granted Microphone and Accessibility. A real disposable TextEdit test now verifies activation, bilingual insertion, exact Undo and native accessible scrolling. Its initial failure exposed missing app activation; another failure showed posted scroll events did not move the document. The final path uses a writable AX scrollbar and checks observed movement. Unsupported views fail visibly.

Microphone testing found Option–Space conflicts with Codex’s mascot shortcut. Configurable shortcuts with a Control–Shift–Space default compile and pass modifier/settings migration tests; the opt-in native hotkey registration check passed (exclusive registration, conflict detection, release on deallocation). The updated app launched. Inspection confirmed it is a menu-bar app (absent from Command–Tab) and the newly signed build required a fresh microphone grant. Voice settings now expose listening status and transcript plus manual Start/Finish buttons; Microphone permission was then confirmed Ready in the running app. Live Start initially reported a missing app language asset; installing it exposed a real audio-thread crash. An explicit Sendable audio-tap callback removed the inherited main-actor assertion. The repeated menu Start check now reaches Listening, shows the floating panel, and Stop succeeds without crashing. The owner then supplied a screenshot showing a real transcript, “Hello, can you hear me? Um. Scroll?”, in both the menu and HUD. This verifies a microphone transcription reached the UI. It does not establish language accuracy, shortcut-only activation, or scrolling: the phrase was ambiguous, cloud interpretation was off, and no target app was granted. Real microphone accuracy, wake/stop latency, permission denial/revocation, physical takeover, live screen capture and authenticated native/web sessions remain unverified.

Gmail in Brave is the selected personal-mail target; ChatGPT in Brave is the creative target. A reviewed Gmail draft handoff is implemented but not live-verified; it opens a compose URL in Brave and does not send. Gmail chooses the signed-in account; the user must verify its sender. Full browser adapters remain pending. Creative file attachment/retrieval/sharing, visual target grounding, synchronized native/web memory, fully voice-accessible review/recovery, scheduled retention and broad multi-app workflows remain incomplete. File grants and planner action schemas alone do not implement those workflows.

Request quotas are counts, not monetary budgets. Whole-window capture has no field-level redaction. Uncertain sends require manual provider-history reconciliation; blind retry is disabled. Signed/notarized distribution, clean-machine testing and hackathon submission remain outside verified completion.
