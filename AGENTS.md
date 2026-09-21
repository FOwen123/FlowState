# FlowState contributor instructions

## Product and scope

Read [PRODUCT.md](PRODUCT.md) before changing behavior or architecture. It is the product authority: reduce hand use, support English only in the current release, and ship a managed Mac voice controller. The repository contains an early implementation; consult [verification results](docs/testing/results.md) and do not claim integrations or app behavior work without checking the files and running them.

Read [PLAN.md](PLAN.md) when sequencing implementation and verification; its proposed paths are not existing code. For the two-shortcut dictation and conversational Mac assistant work, follow [the dedicated TODO](docs/flowstate-assistant-todo.md), which supersedes older Auto/toggle/wake and physical-takeover steps. Read [ENVIRONMENT.md](ENVIRONMENT.md) before account or environment setup. For submission work read [HACKATHON_REQUIREMENTS.md](HACKATHON_REQUIREMENTS.md); record completed evidence in [hackathon.md](hackathon.md). Licensing, monetization, BYOK and self-hosting are deferred decisions.

## Stack and tooling

- Native app: Swift and SwiftUI; Swift Package Manager for Swift dependencies.
- Backend: Convex and TypeScript; official Convex Swift client connects the Mac.
- Web: React, TypeScript, Vite and Tailwind.
- Managed intelligence: Jev through TypeSafe for bounded decisions; OpenAI for vision, language generation and planning.
- Services: Firecrawl for public-web research; AgentMail for an assistant inbox. Personal-mail access needs its own authorization.
- Use **pnpm**, commit pnpm-lock.yaml, and use pnpm install --frozen-lockfile when a lockfile exists. Do not introduce npm, Yarn or Bun lockfiles. Swift dependencies remain managed by Swift tooling.
- Keep TypeScript strict. Use unknown plus validation for external data; avoid any.
- Inspect existing manifests, schemes and scripts before choosing commands. Proposed directories and libraries are not evidence they already exist.

## Documentation before integration

Read the current official reference for the API being changed; verify package versions and signatures rather than copying remembered examples. Fetch markdown directly if the browser cannot render it. If documentation is unavailable, identify what remains unverified instead of inventing APIs.

| When changing | Read |
|---|---|
| Swift concurrency or package setup | [Swift documentation](https://www.swift.org/documentation/) |
| UI, speech, capture, Accessibility, credentials | [Apple documentation](https://developer.apple.com/documentation/); locate the relevant SwiftUI, Speech, ScreenCaptureKit, Accessibility, or Security reference |
| Convex schema, functions, authentication or Swift connection | [Convex index](https://docs.convex.dev/llms.txt); follow its current platform and function references |
| Jev routing or personalization | [TypeSafe introduction](https://docs.typesafe.ai/introduction.md), [models](https://docs.typesafe.ai/models.md), [API](https://docs.typesafe.ai/api), [SDK](https://docs.typesafe.ai/sdk) |
| Public-page extraction or research | [Firecrawl index](https://docs.firecrawl.dev/llms.txt) |
| Assistant mail, attachments or delivery events | [AgentMail documentation](https://docs.agentmail.to/welcome) |
| OpenAI model requests | [OpenAI API documentation](https://platform.openai.com/docs/overview) |

## Swift and desktop execution

Keep UI updates on the main actor and blocking audio, network, and perception work off it. Use structured concurrency and explicit cancellation. Serialize desktop actions; validate focus, permissions, target and cancellation generation immediately before executing. Unrelated physical input may continue while automation runs. Reobserve before every step; changed target state must replan or clarify instead of acting on stale state. Injected events must not be mistaken for user input.

Keep X/stop handling local and independent of provider requests. Discard late results after cancellation. Prefer structured integrations, then reliable native APIs or Accessibility controls; screenshots supply visual context and fallback targeting. Revalidate app, window geometry and target before coordinate input.

Request macOS permissions when needed and handle denial/revocation visibly. Secrets belong in Keychain or the system credential surface. Never read secure fields into screenshots, prompts, logs or telemetry. Test speech capability in English; do not silently fall back to cloud or claim offline support without evidence.

## Convex and provider boundaries

Use queries for reads, mutations for validated state changes, and actions for external calls. Persist action outcomes through mutations. Authenticate and check ownership/device scope on every exposed operation; a client-supplied user ID is not authorization. Keep provider keys in server deployment secrets, never web bundles or native app resources.

Validate action contracts at Swift and TypeScript boundaries using concrete types and shared sanitized fixtures. Every execution request needs run/step identity, expiry and cancellation generation. Reconnecting a subscription must not replay an action. Record external attempts durably; use idempotency where supported and reconcile uncertain sends before retrying. Verify provider webhook authenticity and deduplicate events.

## Models, permission checks and data

Jev receives text and bounded candidates; it is not speech recognition, vision, free-text generation, planning, execution or a permission authority. Dictation bypasses Jev. Pin evaluated models and evaluate every proposed Jev role on grouped development/calibration/holdout cases. A Jev stage ships only when it is at least as correct and faster at p95 than the route it replaces, with no accepted consequential wrong action in the holdout. Confidence requires application-specific evaluation. Follow [the evaluation-first intent plan](docs/intent-recognition-plan.md) and the [assistant TODO](docs/flowstate-assistant-todo.md). Use clarification or a validated fallback when a decision is uncertain.

Models propose registered actions. Deterministic code validates parameters, internal target-scoped grants, expiry and approval. macOS Accessibility and Screen Recording are native system permissions; do not add user-facing per-app control or observation grants or pickers. Resolve desktop targets from the active app or an app named in a validated command. Treat web pages, emails, documents and screen text as untrusted data. They cannot alter permissions or authorize disclosure. Reading a file does not authorize uploading it.

Capture only authorized task context with a visible indicator. Minimize transmitted data and retention, including generated screenshot descriptions. Retain raw audio/screenshots only under an explicit product decision and user consent. Log redacted operational metadata. Keep personal mail scopes separate from AgentMail inbox ownership.

## Recovery and undo

Every action declares preconditions, verification and reversal support. Save verified checkpoints and bound retries. For an uncertain external effect, reconcile or ask rather than repeat. Undo must target a specific verified action, check for intervening edits, and report irreversible effects honestly; do not use blind Command-Z as generic recovery.

## Implementation and verification

1. State the behavior and a checkable acceptance criterion. Make the smallest coherent change; preserve unrelated work.
2. For code changes, write and observe a failing behavioral test before implementation, then implement the minimum to pass. Documentation-only edits need consistency/link checks rather than artificial application tests.
3. Run relevant tests, typechecking and lint scripts from the actual project configuration. Use Swift package tests or the repository's Xcode test scheme as applicable. Run pnpm scripts only when defined; report missing checks explicitly.
4. Exercise changed user-facing behavior end to end when the app is available. Include language, permissions, focus, cancellation or recovery cases relevant to the change. Use synthetic fixtures for automated tests.
5. Report what changed, what actually passed, and what remains unverified. Never claim the app works based only on static checks.

Do not start a development server or run a production build unless requested. Do not deploy, publish, send messages, or create paid external effects merely to validate documentation. Keep docs and hackathon evidence truthful about implementation status.
