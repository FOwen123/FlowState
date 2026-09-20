# FlowState implementation checklist

Updated September 20, 2026. Product authority: [PRODUCT.md](PRODUCT.md). Contributor rules: [AGENTS.md](AGENTS.md). Account/configuration checklist: [ENVIRONMENT.md](ENVIRONMENT.md).

Implementation has started. See [verification results](docs/testing/results.md) for completed evidence and [setup instructions](docs/setup.md) for configuration. Unchecked items remain open acceptance gates; some contain partial implementation. Paths below are planning targets and may be consolidated in the actual code. Keep modules together until their responsibilities justify splitting them. Complete each slice with failing behavioral tests, implementation, relevant checks, and observed user-facing behavior. Do not start servers, production builds, or deployments merely to check this document.

## Test computer and environments

Verified on the current local host, September 20, 2026:

| Target | Configuration | Use |
|---|---|---|
| Primary Mac | MacBook Pro; Apple M5 Pro, 15 CPU cores; 24 GB unified memory; macOS 26.6.2 | Native UI, microphone, bilingual speech, Accessibility, capture, physical takeover, performance and end-to-end workflows |
| Installed tools | Xcode 27.0; Swift 6.4; Node 24.15.0; pnpm 11.10.0 | Baseline inventory; validate dependency compatibility and pin supported versions during setup |
| Development services | Separate Convex development deployment and provider test resources; not yet configured | Authentication, database isolation, model calls, research and approved email tests |
| Browser on primary Mac | Brave for intended daily use; Safari for native baseline | Public web companion, cross-app workflows and focus checks; record installed versions at test time |
| Release validation | Separate macOS test account, then a second clean supported Mac when available | Fresh onboarding, signing, permissions, update and uninstall; second computer not yet supplied |

Native unit tests now run with synthetic capture data; the native app has not been exercised interactively. Do not infer Intel, older macOS, lower-memory, or other Mac compatibility from this machine. Hostinger VPS is not required for the selected managed architecture and cannot validate native macOS behavior. Cloud CI can later run portable checks, but does not replace microphone, permissions, or input-control tests on a Mac.

For every measured run, record commit, OS/app/model versions, test language, target app, peak memory, latency, result, corrections and physical interventions in `docs/testing/results.md`. Keep raw private audio/screenshots out of test evidence.

## 1. Repository and contract foundation

Files: `package.json`, `pnpm-workspace.yaml`, `pnpm-lock.yaml`, `tsconfig.json`, `.gitignore`, `.env.example`, `apps/web/package.json`, `apps/web/vite.config.ts`, `apps/macos/FlowState.xcodeproj/project.pbxproj`, `apps/macos/FlowState/Info.plist`, `apps/macos/FlowState/FlowState.entitlements`, `apps/macos/Config/Development.example.xcconfig`, `packages/contracts/actions.ts`, `tests/fixtures/actions.json`.

- [ ] Create pnpm workspace for web/backend/contracts; pin a verified pnpm version in package.json’s packageManager field, declare packages in pnpm-workspace.yaml, and commit the lockfile.
- [ ] Create native SwiftUI app target, test targets and shared scheme; use Swift Package Manager dependencies.
- [x] Ignore credentials, local configuration and generated output. Capture currently stays in memory; no recording persistence is implemented.
- [ ] Define concrete action/run/step/result schemas and shared Swift/TypeScript fixtures; reject unknown fields/actions.
- [ ] Add actual typecheck, lint and test commands; document native test invocation after the scheme exists.
- [x] Add placeholder-only configuration examples from ENVIRONMENT.md; validate missing required settings clearly (presence only; live validity remains unverified).

Verify: primary Mac; fixture parity and invalid-input tests pass, scripts resolve, no secrets tracked. Scaffold does not count as a working controller.

## 2. App shell and permission onboarding

Files: `apps/macos/FlowState/App/FlowStateApp.swift`, `App/AppState.swift`, `UI/HUDView.swift`, `UI/SettingsView.swift`, `Permissions/PermissionManager.swift`, `UI/OnboardingView.swift`, `Resources/Localizable.xcstrings`, `apps/macos/FlowStateTests/PermissionTests.swift`.

- [ ] Add menu-bar lifecycle, HUD states, settings and visible local/cloud indicators.
- [ ] Explain/request microphone, speech, Accessibility and screen capture only when needed.
- [ ] Handle denied/revoked permissions without repeated prompts or silent degradation.
- [ ] Add English and Traditional Chinese UI strings and accessible labels.
- [ ] Show a safe first-run action and voice-accessible help/cancel controls.

Verify: primary Mac, fresh test account; permit/deny/revoke each permission and exercise onboarding in both languages.

## 3. Bilingual audio and activation feasibility

Files: `apps/macos/FlowState/Audio/AudioCapture.swift`, `Audio/SpeechRecognizer.swift`, `Audio/ActivationController.swift`, `Audio/StopListener.swift`, `Audio/TranscriptProcessor.swift`, `apps/macos/FlowStateTests/AudioStateTests.swift`, `tests/fixtures/commands.en.json`, `tests/fixtures/commands.zh-Hant.json`, `tests/fixtures/commands.mixed.json`, `docs/testing/speech-evaluation.md`.

- [ ] Compare Apple Speech and a suitable local multilingual runtime on this Mac; document model size, peak memory, latency and quality.
- [ ] Select the speech path using both launch languages, not an English-only benchmark.
- [ ] Implement push-to-talk, session toggle and configurable locally detected wake phrase.
- [ ] Keep local stop detection independent of cloud requests and workflow execution.
- [ ] Handle silence, microphone changes, session restart, background audio and false wakeups.
- [ ] Separate command/dictation modes; prevent dictated command words from executing.
- [ ] Preserve meaning, names, punctuation and mixed-language app names; make Traditional Chinese output explicit.
- [ ] Test offline behavior and disclose any required managed transcription; never silently fall back to cloud.

Verify: primary Mac microphone plus synthetic/consented samples; English, Traditional Chinese and mixed speech; measure memory and stop latency with active workflows and network disconnected.

## 4. Native control and interruption

Files: `apps/macos/FlowState/Context/AppContext.swift`, `Context/AccessibilityReader.swift`, `Actions/ActionRegistry.swift`, `Actions/ActionExecutor.swift`, `Actions/ActionVerifier.swift`, `Actions/NavigationActions.swift`, `Actions/TextActions.swift`, `Safety/ExecutionGate.swift`, `Safety/UserTakeoverMonitor.swift`, `apps/macos/FlowStateTests/ExecutorTests.swift`, `apps/macos/FlowStateUITests/NavigationTests.swift`.

- [ ] Implement open/switch app, bounded scrolling, focus/select/press and text insertion.
- [ ] Use native or Accessibility mechanisms where reliable; verify observed effects.
- [ ] Serialize desktop actions and validate focus, target, expiry and execution generation.
- [ ] Cancel queued actions and reject late cloud replies immediately after local stop.
- [ ] Detect physical takeover without interpreting injected events as user takeover.
- [ ] Pause desktop input while allowing independent authorized cloud work to continue.
- [ ] Resume only on request, after reobserving screen and permissions.

Verify: primary Mac in TextEdit, Finder, Safari and Brave; force focus changes, cancellation and takeover mid-step. Verify no stale input occurs after pause/cancel.

## 5. Identity, Convex and web companion

Files: `convex/schema.ts`, `convex/auth.config.ts`, `convex/users.ts`, `convex/devices.ts`, `convex/runs.ts`, `convex/approvals.ts`, `convex/preferences.ts`, `apps/macos/FlowState/Backend/ConvexService.swift`, `Backend/AuthSession.swift`, `Storage/KeychainStore.swift`, `apps/web/src/App.tsx`, `apps/web/src/auth.tsx`, `apps/web/src/components/RunView.tsx`, `convex/tests/ownership.test.ts`.

- [ ] Validate an authentication provider on both Swift and web before committing to it.
- [ ] Configure separate development and production deployments; connect official clients.
- [ ] Authorize user/device ownership for reads, mutations, actions and subscriptions.
- [ ] Persist task states, verified steps, approvals and explicit preferences.
- [ ] Show redacted live progress on the web; keep guests separate from owner devices.
- [ ] Handle token expiry, logout, device revocation and reconnect without replaying actions.

Verify: primary Mac plus separate browser sessions against development Convex; cross-user/device access denied and reconnect does not duplicate execution.

## 6. Managed Jev, vision and planning

Files: `convex/ai/jev.ts`, `convex/ai/vision.ts`, `convex/ai/planner.ts`, `convex/ai/validation.ts`, `apps/macos/FlowState/Intelligence/IntentRouter.swift`, `Intelligence/CandidateBuilder.swift`, `Context/ScreenCapture.swift`, `Context/VisualTarget.swift`, `convex/tests/aiContracts.test.ts`, `docs/testing/routing-evaluation.md`.

- [ ] Read current official TypeSafe/OpenAI references and pin evaluated model versions.
- [ ] Route exact local commands locally; use Jev for bounded textual intent/candidate selection.
- [ ] Build minimal permitted screen context; interpret screenshots with a vision model, not Jev.
- [ ] Validate planned actions against the registry; model output cannot grant permissions.
- [ ] Evaluate Jev on English/Traditional Chinese separately; add clarification or validated fallback.
- [ ] Ground visual targets in current geometry; handle moved windows and multiple displays.
- [ ] Bound request sizes, retries, execution time and provider usage; report outages clearly.

Verify: mocked contract tests first, then configured development provider calls; primary Mac for visual actions. Test ambiguous commands and stale screenshots without real sensitive data.

## 7. Grants, files and privacy

Files: `apps/macos/FlowState/Safety/PermissionPolicy.swift`, `Safety/GrantStore.swift`, `UI/ControlSettingsView.swift`, `UI/ApprovalView.swift`, `Actions/FileActions.swift`, `Context/ApprovedFiles.swift`, `convex/grants.ts`, `convex/retention.ts`, `apps/macos/FlowStateTests/PolicyTests.swift`, `convex/tests/grants.test.ts`, `docs/privacy.md`.

- [ ] Separate per-app observation, input, file access, upload, send and spending grants.
- [ ] Display duration, expiry, revoke controls and grants used by the current task.
- [ ] Capture only authorized active-task windows; show capture status and sensitive-app exclusions.
- [ ] Restrict file candidates to current selection/approved folders; preview destination and attachment.
- [ ] Bind approvals to exact action arguments; invalidate changed/expired approvals.
- [ ] Delegate login to system autofill/password manager; keep secrets out of all model context.
- [ ] Minimize raw content and derived summaries; implement retention/deletion and redacted diagnostics.
- [ ] Treat screen, web and email contents as untrusted data; test attempted instruction injection.

Verify: primary Mac plus backend tests; denied grants prevent effects, read grants do not allow upload, and revocation stops subsequent steps.

## 8. Durable workflows, recovery and undo

Files: `apps/macos/FlowState/Workflows/WorkflowCoordinator.swift`, `Workflows/RecoveryController.swift`, `Actions/UndoJournal.swift`, `Actions/UndoExecutor.swift`, `convex/steps.ts`, `convex/operations.ts`, `apps/macos/FlowStateTests/RecoveryTests.swift`, `convex/tests/idempotency.test.ts`.

- [ ] Checkpoint verified steps and preserve uncertain outcomes distinctly from failures.
- [ ] Bound retries; reconcile external effects before repeating submissions.
- [ ] Persist operation IDs and use provider idempotency where available.
- [ ] Implement voice resume, alternate approach, cancel and action-specific undo.
- [ ] Store necessary prior state; check intervening edits and conflicting file destinations.
- [ ] Explain irreversible effects rather than claiming uploads or messages can be erased.
- [ ] Revalidate pending tasks after app restart, Mac sleep/wake and network loss.

Verify: primary Mac with fault injection; ambiguous send responses never trigger blind resends, and undo never overwrites later user edits.

## 9. Memory and personalization

Files: `apps/macos/FlowState/Storage/PreferenceStore.swift`, `UI/MemoryView.swift`, `Intelligence/CorrectionHandler.swift`, `apps/macos/FlowStateTests/PreferenceTests.swift`.

- [ ] Save explicit vocabulary, app aliases, style and folder preferences.
- [ ] Let users inspect, edit, forget and control synchronization by voice and settings.
- [ ] Make learned preferences opt-in; preserve explicit preference precedence.
- [ ] Handle deletion and synchronization consistently across Mac and web.

Verify: primary Mac and development Convex; bilingual corrections survive restart and deletion removes the synchronized record.

## 10. Public-web research and both email paths

Files: `convex/research.ts`, `convex/mail.ts`, `convex/http.ts`, `convex/deliveries.ts`, `apps/macos/FlowState/Actions/PersonalMailActions.swift`, `apps/web/src/components/ResearchView.tsx`, `apps/web/src/components/MailPreview.tsx`, `convex/tests/research.test.ts`, `convex/tests/mail.test.ts`.

- [ ] Add Firecrawl current-public-page extraction and multi-source research with citations.
- [ ] Keep private browser sessions/cookies outside public retrieval requests.
- [ ] Add AgentMail assistant inbox, threads, attachments and reviewed draft/send flow.
- [ ] Implement personal mailbox access through an approved provider connection or desktop adapter; choose after provider is known.
- [ ] Show sender, recipient, subject, body and attachments before authorized sending.
- [ ] Verify webhook authenticity, deduplicate events and distinguish accepted from delivered.
- [ ] Enforce guest isolation, allowed public requests, retention and usage limits.

Verify: development accounts and primary Mac; use an explicitly authorized test recipient for real sending. Test provider failures with fixtures before live calls.

## 11. Complete workflows and bilingual acceptance

Files: `tests/e2e/creative-workflow.md`, `tests/e2e/research-mail-workflow.md`, `tests/e2e/navigation-bilingual.md`, `docs/testing/results.md`.

- [ ] Run creative file selection → attachment → request → wait → retrieve → sharing draft.
- [ ] Run public research → sourced note → approved email using real configured services.
- [ ] Run navigation/dictation/correction in both languages and mixed speech.
- [ ] Exercise stop, physical takeover, resume, undo, denied permissions, app restart and network failure.
- [ ] Repeat each reference flow from a clean starting state; record failures and physical interventions, not only successful videos.
- [ ] Add trip planning and return-request flows after the reusable steps are verified; keep purchases out of routine tests.

Verify: primary Mac; distinguish mocked tests from live service/UI evidence. Use actual measured results to choose release thresholds.

## 12. Distribution and hackathon submission

Files: `docs/release.md`, `docs/setup.md`, `docs/security.md`, `.github/workflows/checks.yml`, `apps/web/src/pages/Demo.tsx`, `README.md`, `HACKATHON_REQUIREMENTS.md`, `hackathon.md`.

- [ ] Add CI for implemented checks using compatible runners; native interactive tests stay on real Macs.
- [ ] Verify clean-account onboarding and release credential availability.
- [ ] Configure signing/notarization and a supported update path; exercise installation/update/uninstall when authorized to produce a release.
- [ ] Reconcile old stack recommendations in HACKATHON_REQUIREMENTS.md and recheck official event rules.
- [ ] Deliver a usable permitted-domain web experience with isolated guests and bounded provider spend.
- [ ] Prepare public repository, honest build log, under-three-minute video and required submission materials.
- [ ] Obtain necessary publication/sending authorization, publish/submit, and save actual URLs and receipt.
- [ ] Label incomplete capabilities accurately; submission readiness does not equal production readiness.

Verify: primary Mac plus clean supported Mac when available; logged-out web/repository access and real submission evidence. Follow HACKATHON_REQUIREMENTS.md for event gates rather than assuming this checklist establishes eligibility.

## Start order and dependencies

Start with repository/contracts and native permission/audio feasibility; no paid provider credentials are needed for most of that work. Validate bilingual speech and local stop before committing to a speech runtime. Configure Convex/auth early, then add grants, native execution and model integrations in testable slices. Complete recovery before relying on long workflows. Keep the full roadmap even if the hackathon milestone demonstrates only a verified subset.
