# Hackathon log

- **Project:** Flow State
- **Event:** Convex All Gas Hackathon 2026
- **What it does:** Planned voice controller for macOS with a public reading and note workflow for people reducing mouse and keyboard use.
- **Live app:** not deployed
- **Repo:** https://github.com/FOwen123/ProWhisper
- **Frontend:** not deployed
- **Convex deployment:** not deployed
- **Components:** none
- **Convex features:** schema, authenticated research runs, approvals and delivery records implemented; no live deployment
- **Auth:** Clerk web integration implemented; live login unverified
- **AI models:** TypeSafe/Jev selection and OpenAI summary adapters implemented; model access unverified
- **Started:** 2026-09-19T06:22:14Z, earliest repository commit only; actual application start date unconfirmed
- **Last updated:** 2026-09-20 (local implementation evidence)

## Log

### 2026-09-19 - 6c5ea9e

Created the initial ProWhisper README. This commit does not contain application code.

### 2026-09-20 - working tree

Reviewed the existing FlowState product plan and design reference against the official All Gas event. Updated the product name and README, narrowed the hackathon implementation to local Mac commands and a real public reading workflow, and added source-linked eligibility and submission checks. Added specific planned roles for Firecrawl and AgentMail, moved Convex earlier, and deferred broad desktop automation and Jev routing. Added hands-free activation, on-device speech checks, authorization, cancellation, and accessible design constraints.

Evidence: PRODUCT.md, DESIGN.md, README.md, PLAN.md, HACKATHON_REQUIREMENTS.md. These are planning changes only. No Convex components, provider integrations, native actions, tests, deployment, video or social post have been implemented or verified. Repository visibility is unverified. No email or external submission was sent.

## Submission evidence

- Demo video: not recorded
- Social post: not published
- Registration: not verified
- Submission receipt: not submitted
- Required frontend URL: not deployed

Planned features belong in PLAN.md. Update the header to name actual models and registered components only after source or deployment evidence exists. Record future work chronologically and link test or deployment evidence without exposing credentials, private screen content or email addresses.

### 2026-09-20 — foundation implementation

Added a pnpm workspace, bilingual web research/approval UI, authenticated Convex workflow functions, Firecrawl/TypeSafe/OpenAI/AgentMail adapters, and a separate Swift ScreenCaptureKit permission/grant foundation. Tests use simulated providers and synthetic images. No live provider call, deployment, email, native input event, or hackathon submission was performed. See [test evidence](docs/testing/results.md) and [configuration steps](docs/setup.md). This supersedes the earlier planning-only status; it does not establish a finished voice controller.
