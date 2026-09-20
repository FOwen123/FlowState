# Flow State

Flow State is a Mac voice controller that reduces sustained typing, clicking, and scrolling. Its primary success measure is how often a person can complete everyday tasks without using their hands. It is not defined as a replacement for Wispr Flow, and makes no medical recovery claims.

## Status and document authority

Updated September 20, 2026 for English-only automatic intent recognition. Flow State is the display name; `FlowState` is the code identifier. Implementation has started; [verification results](docs/testing/results.md) distinguish tested behavior from pending integrations and release requirements.

This document is the current product source of truth. [PLAN.md](PLAN.md) translates this direction into a file-level implementation checklist and verified test-machine baseline. [ENVIRONMENT.md](ENVIRONMENT.md) lists account, credential and configuration inputs. [HACKATHON_REQUIREMENTS.md](HACKATHON_REQUIREMENTS.md) records event requirements; [hackathon.md](hackathon.md) records completed work and evidence, never planned work as completed. [AGENTS.md](AGENTS.md) defines implementation rules.

Ship the product and a truthful hackathon submission first. The hackathon is a delivery milestone, not the boundary of the product. Pricing, licensing, open-source release arrangements, bring-your-own keys, and self-hosting are deferred decisions. Public-repository requirements for submission must still be satisfied; they do not settle the long-term licensing model.

## Audience and release priorities

The founder experiences discomfort from mouse scrolling and typing. FlowState serves people who want to reduce those interactions across everyday Mac applications.

1. Hands-free navigation: open and switch apps, scroll, switch tabs or conversations, select controls, attach files, and stop or correct actions.
2. English only for the current release: interface, dictation, commands, corrections and confirmations. Remove Traditional Chinese support from the active product; additional languages are deferred. Preserve Unicode user content and existing data.
3. Longer workflows across applications: creative work, public-web research, file organization, and email.

Examples include Brave and Substack reading, Spotify, messaging, and creative AI applications. Codex, Cursor, and Ghostty are useful personal workflows, but developer tooling does not define the product or showcase.

## Voice and visible interaction

Use a native menu-bar app with a compact, transient heads-up display (HUD) and a separate settings window. Show what was heard, interpreted intent, current step, local/cloud processing, and accessible controls to stop, confirm, retry, or undo.

- Offer configurable push-to-talk and a locally detected wake phrase. A hands-free session must not require holding a key. Validate microphone, battery, false activation, and interruption behavior before shipping wake activation.
- Default to Auto intent recognition, with optional Dictation only and Commands only overrides. Finalize complete utterances automatically within an active session; Finish remains an override. Dictating a sentence containing “delete” must not execute a delete command.
- Support voice correction and clarification in English. Preserve meaning during dictation cleanup; do not invent or silently remove substantive content.
- States: idle, listening, resolving, acting, awaiting confirmation, paused, completed, failed, cancelled. Screen capture is off while idle.
- A local stop path remains available while cloud calls or actions are running. Cancellation invalidates queued actions and late replies. Report already completed external effects accurately.
- Physical mouse or keyboard input pauses desktop execution immediately at the next safe interruption point. Distinguish real user input from injected events. Independent cloud work may continue under its existing grants.
- Resume only after the user requests it and FlowState rechecks focus, screen state, permissions, and pending actions. Never steal focus when a background result arrives.

## Reference workflows

| Workflow | Sequence | Checkpoints |
|---|---|---|
| Creative task | Select an approved photo/file → attach to an AI app → dictate a creative request → wait → retrieve and organize result → prepare sharing message | Verify file and destination; confirm paid generation and sending/publication under policy |
| Reading and research | Extract current public article → research related public sources → produce a sourced note → save or prepare email | Keep private authenticated content separate from public-web retrieval |
| Trip planning | Research destinations and transport → compare sources → assemble itinerary → draft email → incorporate replies | Approve sending, booking, and payment |
| Return an order | Find order email → locate policy and receipt → prepare return request → save label | Confirm merchant, item, attachment, and external submission |
| Everyday navigation | Open Brave → read and scroll → switch conversation → dictate reply → play a chosen song | Verify focus and target before input; apply send policy |

Long workflows run step by step with visible progress. A result from one app is not assumed to exist in another until verified. Do not force every integration into every workflow.

## Architecture and technology stack

| Layer | Direction | Responsibility |
|---|---|---|
| Mac application | Swift, SwiftUI, Swift Package Manager | Menu bar, HUD, onboarding, settings, local execution |
| Speech | Current local Apple speech path; evaluate alternatives only where measured English failures justify them | English transcription, utterance completion, local activation and stop |
| Mac context | NSWorkspace, macOS Accessibility, ScreenCaptureKit, Vision OCR where useful | Relevant app state, permitted screenshots, text and control candidates |
| Semantic decisions | Jev through TypeSafe's documented API/SDK | Bounded intent and candidate selection using textual state and explicit preferences |
| Vision and planning | Managed OpenAI models initially, invoked server-side | Interpret screenshots, generate language, construct typed multi-step plans |
| Execution | Native APIs, Accessibility actions, approved Shortcuts/Apple Events, bounded keyboard/mouse events | Execute the most reliable permitted mechanism and verify effects |
| Local storage | SwiftData and Keychain | Preferences/cache, action recovery data; device credentials in Keychain |
| Backend | Convex with TypeScript, official Swift and React clients | Account/device ownership, task state, approvals, preference sync, service orchestration |
| Public web research | Firecrawl | Current public-page extraction and multi-source research |
| Email | AgentMail plus separately authorized personal-mail access | Assistant-owned inbox; personal mailbox through provider connection or permitted desktop control |
| Web companion | React, TypeScript, Vite, Tailwind | Onboarding information, redacted live workflow views, usable hackathon experience |
| JavaScript tooling | pnpm | Commit pnpm-lock.yaml; use pnpm for backend and web dependencies |
| Distribution | Developer ID signing, hardened runtime, notarized download; update mechanism to validate | Installable Mac product without developer tools |

Authentication provider, exact speech/vision models, minimum macOS version, and update tooling require feasibility validation. Do not present candidates as installed dependencies. Swift package management remains separate from pnpm.

### Decision and action pipeline

```text
Local activation → transcription → utterance completion → Auto intent routing
                                    ↓
Minimal permitted text context + explicit preferences; screenshot only when needed
                                    ↓
Exact local match / Jev bounded choice / vision + language-model plan
                                    ↓
Validated registered action → deterministic permission check
                                    ↓
Confirmation when required → local or authorized service execution
                                    ↓
Observe and verify → checkpoint → next step / clarification / recovery
```

Cancellation and physical takeover bypass cloud reasoning and directly gate the local executor. Serialize desktop actions per Mac. Independent cloud tasks can proceed without owning the desktop.

Screenshots are central visual context, not a requirement to click coordinates for every operation. Prefer reliable native/service APIs and Accessibility controls when available. For visual clicks, refresh stale observations and validate the app, window, display scaling, and target immediately before input.

### Jev has a concrete role

Implement the evaluation-first sequence in [English-only intent recognition](docs/intent-recognition-plan.md). The current code still needs migration; this direction is not a completion claim.

Use Jev to choose between known intents, resolve references such as “that file,” and rank a bounded set of app/control/file candidates. Exact local commands and saved aliases can bypass it. Jev does not transcribe speech, interpret screenshots, generate rewritten sentences, or grant permission.

The documented models accept text. Convert visual context into bounded textual candidates using vision/OCR before calling Jev. Customize requests with explicit preferences and rules rather than assuming per-user training. Use documented response shapes, pin evaluated model versions, and calibrate decisions on FlowState's own examples. Evaluate English utterances, including ambiguity, quoted commands, corrections and speech-recognition errors. Choose intent/action/target thresholds from calibration data and verify on untouched holdout data. Escalate to a text or vision-capable LLM when the missing context can resolve uncertainty; otherwise clarify. Never treat confidence as a permission grant. See the [TypeSafe model documentation](https://docs.typesafe.ai/models.md).

### Convex and external services

Queries read authorized state; mutations validate and persist state transitions; actions call external providers and persist outcomes through mutations. Every operation checks authenticated ownership and device scope. A live subscription or reconnect is not authority to replay a desktop action.

Initial records should cover users/devices, explicit preferences, grants, workflow runs, steps, approvals, and external delivery attempts. Add other tables only for implemented workflows. Provider credentials stay in managed server secrets. Use scoped, revocable authorization for personal mail; AgentMail is not automatically access to a user's existing inbox.

Firecrawl receives approved public URLs and research queries. It does not inherit browser cookies or permission to read private tabs. Keep sources with generated notes. Web and email contents are untrusted input, never instructions to change permissions or disclose private data.

## Permissions and privacy

Settings must answer “What can FlowState do, where, for how long, and what leaves my Mac?” Separate observation, file access, input control, uploading, sending, and spending. Show per-app/action grants, session or persistent duration, expiry, and revocation. The active task shows the grants it is using.

| Capability | Default behavior |
|---|---|
| Screen observation | Per-app permission; capture only during authorized active tasks, crop to relevant window, visible indicator, sensitive-app exclusions |
| File selection | Current selection or approved folders; show candidates and confirm attachment and destination |
| Local navigation | Execute granted reversible actions and verify |
| Text/file modification | Record reversal information when possible; preview ambiguous or consequential edits |
| Sending/uploading/publishing/deleting | Confirm exact target and effect by default; expose clearly scoped controls rather than a blanket full-control switch |
| Purchases and permission changes | Explicit action-specific approval; honor service and macOS user-presence requirements |
| Passwords and authentication | Hand off to system autofill, passkeys, or password manager; keep secrets outside model context |

A permission to read a file is not permission to upload it. Grants cannot override macOS protections. Model confidence cannot bypass policy. Screen/email content cannot authorize actions. Approval is tied to exact arguments and expires or becomes invalid if the action changes.

Managed inference means approved context is processed in our backend and by relevant providers. Encryption in transit/at rest does not hide plaintext during inference. Explain providers, data categories, and retention before transmission. Do not promise provider zero retention without verified contractual/configuration support.

Raw audio and screenshots are not retained by default. Generated screen descriptions and transcripts can also be sensitive: minimize them, redact logs, and provide configurable history retention and deletion. Store only necessary redacted task state in Convex. Keep detailed local context local unless the authorized workflow requires transmission. Credentials, secure fields, recovery codes, and one-time codes never enter prompts or telemetry.

## Memory and personalization

Remember explicit preferences by default: vocabulary, app aliases, writing style, approved folders, and reusable workflows. Automatically learned preferences are opt-in and cannot override explicit choices silently. Provide a Memory page to inspect, edit, delete, and control synchronization. Offer voice equivalents for these controls where practical.

English is the only offered interface, recognition and assistant-output language. Migrate previous language settings to English without deleting drafts, history or preferences. Preserve literal user text, Unicode names and filenames; out-of-scope language requests should clarify rather than execute an uncertain action.

## Recovery and undo

Every registered action declares parameter validation, preconditions, required grants, executor, verifier, and reversal support. Requests carry run/step IDs, expiry, device identity, and a cancellation generation. Reject unknown or stale requests.

- Save verified progress at meaningful steps. Distinguish pending, running, succeeded, failed, cancelled, and uncertain outcomes.
- Retry reversible operations a bounded number of times. Reobserve before retrying.
- Use provider idempotency where available and a durable operation record. If a send/payment/submission may already have happened, reconcile its outcome before any repeat; ask the user when uncertainty remains.
- Offer voice-accessible resume, alternative approach, cancel, and undo. Resume revalidates the environment and authorization.
- “Undo that” targets the last verified reversible action. Record the relevant prior state and check it still applies before reversal; do not blindly inject Command-Z into whichever app is focused.
- File moves may be reversed if the original destination remains safe. Text edits may be reversed if the target and edited content still match. Report conflicts instead of overwriting intervening user work.
- Sending, uploading, purchases, and publication may be irreversible. A compensating action is separate, may need approval, and is never described as erasing an external disclosure.

## Delivery and acceptance

Implement coherent end-to-end slices under the English-only scope while preserving permission controls. The complete product roadmap remains broader than what can be demonstrated at submission.

1. **English automatic control foundation:** evaluate Jev routing and fallback thresholds, validate English speech, automatic utterance completion and local stop; deliver navigation, dictation, corrections, onboarding, and HUD in representative native and browser apps.
2. **Context and personalization:** add approved screenshots, verified visual targets, explicit memory, Jev routing, per-action grants, and takeover/resume.
3. **Durable workflows:** add managed planning, Convex progress, file attachment, bounded recovery and undo, public research, and both email paths.
4. **Release readiness:** exercise clean installation, authentication, revoked permissions, provider failures, deletion, signed distribution, and reproducible setup.

For each slice, record task completion, required physical interventions, corrections, unintended actions, end-to-end latency, and stop latency. Test English intent categories, speech errors, literal dictation and ambiguity separately. Measure recognition-to-stop independently from spoken-word-to-stop; never claim instant acoustic recognition. Establish performance targets from measured baselines rather than undocumented model guarantees.

Release acceptance includes:

- A non-developer can install, understand permissions, and perform the core navigation/dictation flow in English.
- Voice stop and physical takeover prevent further desktop steps; stale cloud responses and reconnects cannot restart them.
- A creative file-attachment workflow and a research/email workflow complete with visible verification and recovery.
- Undo works for supported actions and accurately explains unsupported reversal.
- Account/device isolation, expired approvals, focus changes, duplicate requests, untrusted page instructions, and permission revocation are tested.
- Offline and provider-outage behavior is explicit. Aim to preserve local stop and deterministic commands; do not claim offline transcription until the chosen runtime is tested offline in English.
- Diagnostic and evaluation fixtures contain synthetic or consented data, never private screenshots or credentials.

## Hackathon milestone

Show an everyday productivity workflow that reduces physical interaction, with English acceptance evidence. The creative workflow demonstrates the broader Mac controller; public research and reviewed email demonstrate useful Firecrawl, OpenAI, AgentMail, and Convex integration. A constrained usable web experience lets judges try cloud functionality without access to the developer's Mac.

Keep guest data isolated, sending restricted, provider usage bounded, and real execution distinguishable from previews. Recheck event rules and submission gates in HACKATHON_REQUIREMENTS.md. Record only working capabilities and actual deployment evidence in hackathon.md. An incomplete submission must be described as a prototype, not as a production-ready product.

## Direct technical references

Read current official documentation when implementing each integration; this document defines product intent rather than caching SDK signatures.

- [Swift](https://www.swift.org/documentation/) and [Apple developer documentation](https://developer.apple.com/documentation/)
- [Convex documentation index](https://docs.convex.dev/llms.txt)
- [TypeSafe introduction](https://docs.typesafe.ai/introduction.md), [models](https://docs.typesafe.ai/models.md), and [documentation index](https://docs.typesafe.ai/llms.txt)
- [Firecrawl documentation](https://docs.firecrawl.dev/introduction)
- [AgentMail documentation](https://docs.agentmail.to/welcome)
