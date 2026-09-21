# Flow State: Convex All Gas Hackathon build log

- **Project:** Flow State
- **Event:** Convex All Gas Hackathon 2026
- **What it does:** A voice-first macOS assistant that separates focused-field dictation from Mac Control. It can open and navigate supported apps, plan bounded multi-step tasks, research public pages, prepare reviewed notes, and send an approved note through an assistant inbox.
- **Why I built it:** Keyboard and mouse use was hurting my hand. I wanted to keep building software and completing everyday computer tasks with less hand use.
- **Live site:** https://flowstate.filbertowen-s.chatgpt.site
- **Site access:** Public. Anonymous access returned HTTP 200 with the Flow State page on September 22.
- **Site scope:** Static product landing page. It does not yet expose the interactive Convex research workflow, so the live-app requirement is not complete.
- **Public repository:** https://github.com/FOwen123/FlowState
- **Started:** September 19, 2026, based on the first repository commit. The owner must confirm that no earlier app was reused.
- **Last updated:** September 22, 2026

## Current implementation

### Native Mac assistant

- SwiftUI menu-bar app with separate shortcuts for Dictation and Mac Control.
- Dictation binds to the focused non-secure editable field and refuses to paste after focus changes.
- Mac Control uses Apple's on-device English `SpeechTranscriber`, an evaluated router, an OpenAI workflow planner when needed, and a validated native executor.
- Stop remains local and immediate. Desktop actions recheck focus and target state before execution.
- Supported and tested actions include opening named apps, scrolling, selection, key input, literal insertion, URL handoff, and reviewed Gmail compose handoff. Broad arbitrary-computer control is not claimed.
- Native speech responses use Apple's installed system voices. Raw audio and screenshots are not retained.

### Convex and sponsor workflow

- Convex owns users, devices, preferences, grants, workflow runs, action plans, approvals, research sources, usage counters, external-effect receipts, and delivery events.
- The React workspace uses authenticated Convex queries, mutations, actions, and live subscriptions.
- Firecrawl retrieves or scrapes public sources.
- TypeSafe Jev selects bounded candidates and routes supported requests. The current evaluated model is `jev-1.13.0`; unsafe or underperforming stages remain disabled.
- OpenAI generates cited research notes and bounded workflow plans. The configured development planner model was verified as `gpt-5.6-luna`.
- AgentMail sends only after exact sender, recipient, subject, and body review. Attempts are idempotent, and signed delivery events are verified and deduplicated.
- Provider calls use direct server-side adapters rather than official Convex components. Provider keys remain in the Convex environment.

### Authentication and deployment

- Clerk authentication is connected to the React and Swift Convex clients.
- The development Convex deployment has been synchronized and used for live integration checks. There is no production Convex deployment yet.
- Interactive end-user Clerk login has not completed acceptance testing.
- The ChatGPT Site has six published revisions and uses the approved Flow State logo and Woodland Blur artwork. Desktop and mobile layout, reduced motion, asset presence, and horizontal overflow were checked.
- The ChatGPT Site has a `public` access policy and is available without an invitation.

## Build log

### September 19: scope and qualification

- Created the repository and initial project description.
- Confirmed the product focus: reduce keyboard and mouse use with a managed Mac voice controller.
- Reviewed the All Gas requirements and selected Convex, OpenAI, Firecrawl, and AgentMail as the submission workflow.

### September 20: full-stack foundation

- Added the pnpm workspace, React workspace, Convex schema and authenticated workflow functions.
- Implemented Firecrawl, TypeSafe, OpenAI, and AgentMail adapters with validated external-data boundaries.
- Added research runs, approval records, durable delivery attempts, cancellation generations, ownership checks, quotas, retention, and signed AgentMail webhook handling.
- Added the Swift ScreenCaptureKit, Accessibility, speech, permission, cancellation, and cloud-bridge foundations.
- Live development checks successfully called Firecrawl and OpenAI, produced a sourced research note through Convex, accessed the AgentMail inbox, and sent one explicitly authorized test message. Signed `message.sent` and `message.delivered` events were verified.

### September 21: native control and product interface

- Implemented automatic app targeting and verified disposable TextEdit actions and synthetic Brave scrolling.
- Added the Paper-derived design system, Flow State logo, Woodland Blur hero, menu-bar interface, compact listening HUD, recovery feedback, and reduced-motion behavior.
- Split Dictation and Mac Control into independently configurable paths. Dictation cannot silently become a control command, and Mac Control cannot silently type an unsupported request.
- Added local spoken feedback, persistent cancellation, reviewed external-effect handling, and idempotent recovery after uncertain provider responses.
- Evaluated Jev router stages on development, calibration, and holdout cases. Stages that missed correctness or latency gates were left disabled.
- Final integration evidence at this point: 132 Core, 19 Cloud, and 76 App tests; 169 TypeScript tests; typechecking, formatting, and diff checks passed.

### September 22: workflow routing, settings, and public packaging

- Reorganized settings into General, Models, History, Memory, Permissions, and Account. Removed controls for unavailable sync behavior and kept saved preferences local.
- Reproduced a shortcut-routing bug where Control-Shift-Space reached Dictation. Assigned unique Carbon registration identifiers, added a two-handler regression test, and verified the running app now reports `Listening Mac Control`.
- Fixed compound-command routing so requests such as opening Brave and searching for a phrase reach the workflow planner instead of treating the whole phrase as an app name.
- Connected evaluated Jev routing to the workflow-planner fallback. Stop and Dictation remain deterministic local paths.
- Fixed external URL-effect recovery so a completed browser request does not block a later distinct request.
- Created and iterated the separate ChatGPT Site. It now presents the personal origin story, Mac Control workflow, visible progress and cancellation, using the approved Woodland Blur artwork and Flow State logo.
- Published Site version 6 at https://flowstate.filbertowen-s.chatgpt.site, changed its audience to public, and verified anonymous HTTP 200 access.
- Renamed the public GitHub repository to `FOwen123/FlowState` and grouped the implementation into reviewable commits on `main`.
- Final repository evidence: 190 TypeScript tests across 29 files passed, TypeScript checking passed, formatting passed, the Swift suites passed, and the GitHub Actions check for the pushed commit succeeded.

Detailed verification, including the limits of every live check, is recorded in [docs/testing/results.md](docs/testing/results.md). Setup requirements are recorded in [docs/setup.md](docs/setup.md).

## Verified live evidence

- Public GitHub repository and root build log are available.
- Packaged Mac app reached listening state, exposed separate Dictation and Mac Control routes, and responded to the corrected Control-Shift-Space shortcut.
- Disposable TextEdit actions and controlled Brave navigation/scrolling passed on the development Mac.
- Firecrawl extracted a public page.
- OpenAI returned generated text and a managed workflow plan.
- Convex produced a sourced research note and persisted workflow state.
- AgentMail accepted one authorized message, and signed sent/delivered events were observed.
- The ChatGPT Site is deployed at the required domain type and anonymous access is enabled.

## Known limits

- The native app is an Apple Development-signed debug build, not a notarized public Mac release.
- The ChatGPT Site is currently a public static landing page. It is not yet an interactive Convex app.
- Production Convex deployment and interactive Clerk authentication remain unverified.
- Gmail handoff opens a reviewed draft and never sends. Full personal-mail automation is not implemented.
- Visual fallback is limited to reviewed left clicks against a fresh, opt-in window observation. Drag, right-click, double-click, purchases, and irreversible actions are not advertised as supported.
- Jev routes only bounded text decisions. It does not perform speech recognition, vision, free-text planning, execution, or permission decisions.

## Submission evidence

| Requirement | Status | Evidence or next action |
|---|---|---|
| New app started after August 25 | Likely complete | First repository commit is September 19; owner confirmation is still required. |
| Public GitHub repository | Complete | https://github.com/FOwen123/FlowState |
| Root `hackathon.md` | Complete | This file. |
| Convex backend | Implemented in development | Queries, mutations, actions, auth boundaries, live subscriptions, and durable workflow state are present; production deployment remains. |
| OpenAI, Firecrawl, and AgentMail perform real work | Verified in development | Live calls and one authorized AgentMail delivery are recorded above. |
| Public `convex.site` or `chatgpt.site` app | Partial | The Site is public and anonymously accessible, but it is a landing page rather than the usable Convex workflow. |
| Luma registration | Not verified | Confirm from the owner's Luma account. |
| Demo video under three minutes | Not complete | Record and publish a real product walkthrough. |
| X or LinkedIn post with sponsor tags | Not complete | Publish and record the post URL. |
| VibeApps submission | Not complete | Submit the repository, public live-app URL, and video before the deadline. |

Do not present the deployed landing page as the usable product until the judge-facing workflow is available there.
