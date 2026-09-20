# Convex All Gas requirements review

Reviewed September 20, 2026. This file tracks event fit; [hackathon.md](hackathon.md) is the evidence-based build log. Nothing here claims a completed integration or submission.

## Official sources

- [Event and eligibility rules](https://www.convex.dev/hackathons/all-gas)
- [Luma registration and event details](https://luma.com/convex-allgas-hackathon)
- [Exact submission form](https://vibeapps.dev/judging/convex-all-gas-hackathon-openai/submit)
- [Official build-log skill](https://github.com/get-convex/convex-hackathon-skill)

## Dates and qualification

Submit before September 22, 2026 at noon Pacific, which is September 22 at 19:00 UTC and **September 23 at 03:00 Asia/Taipei**. Aim to finish by September 22 at 20:00 Taipei. Winners are scheduled for September 25.

Only new applications started on or after August 25 at noon Pacific qualify. The earliest local commit is `6c5ea9e`, September 19, containing only the initial README. This supports repository timing but does not prove when all development began. Confirm the actual start date. Renaming an older application does not make it new. Disclose any reused Handy code, preserve its license, and ask the organizer if a fork's eligibility is unclear. This plan uses a new Swift client; Handy is research, not copied implementation.

Participants must be adults, meet residency and sponsor-employment restrictions, and register on Luma. Teams may have at most four members; one registration per team is sufficient. Personal eligibility and registration are not verified here.

## Requirements and current gaps

| Gate | Flow State plan | Evidence or gap |
|---|---|---|
| Convex backend | Store aliases, reading notes and workflow progress; execute provider calls | No backend code yet |
| Public frontend on convex.site or chatgpt.site | Interactive React reading workspace via Convex static hosting | No deployment; a native download or video alone is insufficient |
| Public GitHub repository | Existing origin is FOwen123/ProWhisper | Public visibility and optional remote rename are unverified |
| Convex agent integration | Configure the official Convex plugin and build-log skill | Installation not verified; do before implementation |
| Build log | Root hackathon.md with actual progress and URLs | Created; live URL and video remain missing |
| Sponsor integrations | OpenAI summarizes, Firecrawl retrieves, AgentMail delivers approved notes | All planned; TypeSafe does not substitute for these |
| Demo video | Under three minutes, real operation | Not recorded |
| Social sharing | X or LinkedIn post with event sponsor tags | Not posted; retain URL as evidence |
| Submission | Exact VibeApps form above | Not submitted; inspect form fields before final packaging |

The rules require Convex and partner integrations; the judging language explicitly values real work from OpenAI, Firecrawl, and AgentMail. Plan to demonstrate all three. Do not assume that using only one is disqualifying without clarification, or that logos in a README satisfy integration depth.

Auth is not universally required by the event. It is required by this product before exposing private records or native-device sessions. A landing page with canned progress is not the intended submission: judges must be able to use the public reading workflow. A browser cannot operate an arbitrary Mac without a local companion.

## Stack assessment

| Proposed choice | Decision |
|---|---|
| Swift/SwiftUI, AXUIElement, NSWorkspace, CGEvent | Keep. Native integration fits Mac control. Scope support to Safari and TextEdit initially. |
| Apple Speech | Conditional. Prove on-device English recognition and continuous local stop handling before promising offline control. |
| TypeSafe Jev | Defer from the critical path. Use deterministic commands and aliases first. |
| OpenAI Realtime plus vision | Defer. A text-generation action is enough for the first real sponsor workflow. |
| Convex | Move from roadmap phase 4 to day one. Own useful data and workflow transitions. |
| Swift Convex client | Use the official client rather than a custom polling bridge. |
| React, TypeScript, Vite, Tailwind, pnpm | Keep for the web app. Host it on the required domain. |
| Authentication | Validate Clerk's web and Swift Convex integration early. Avoid inventing device-token security. |
| Firecrawl and AgentMail | Add the official Convex components after checking their setup and webhook contracts. |
| SwiftData and Keychain | Choose these rather than leaving SQLite versus SwiftData undecided. |
| Signing, notarization, Sparkle, BYOK, self-hosting | Keep in the release roadmap. Do not block the public web submission on automatic updates or billing modes. |
| JSON Schema code generation, many app adapters | Defer. Use a small action union and shared fixtures first. |

## Public demo boundaries

Guests get isolated sessions, curated public URLs, bounded requests, and a live note workspace. Their demo never subscribes to an owner's Mac command queue. Guest email is disabled; demonstrate real AgentMail delivery in the owner session to a verified recipient. Show delivery failures honestly. Rate-limit provider actions and cap input length and spend before making the URL public.

Public pages and email are untrusted data. They cannot authorize tool calls, change risk policy, select recipients, or expand the action registry. Keep provider keys in Convex deployment secrets and owner tokens in Keychain. Retain only the public excerpts and notes required for the workflow; support deletion and expire guest data.

## Budget and unresolved evidence

Do not rely on prize credits to run the app. The event advertises participant Firecrawl credits after registration, but OpenAI usage needs its own budget. Convex AI Gateway requires a paid team; direct server-side provider calls avoid making that gateway a dependency. Verify AgentMail and Convex account limits during setup. Set an explicit daily provider spend cap before enabling public use.

Still needed: registration confirmation, actual project start date, public repository verification, provider access, Apple speech feasibility, an auth spike, working deployment, video, social URL, and submission receipt. No external account, publication, email, or submission was created during this documentation review.

## Technical references

- [Convex Swift client and auth integrations](https://docs.convex.dev/client/swift/overview)
- [Convex Firecrawl component](https://www.convex.dev/components/firecrawl/firecrawl-convex)
- [Convex AgentMail component](https://www.convex.dev/components/agentmail/convex)
- [Apple on-device recognition capability](https://developer.apple.com/documentation/speech/sfspeechrecognizer/supportsondevicerecognition)
- [Apple on-device recognition request](https://developer.apple.com/documentation/speech/sfspeechrecognitionrequest/requiresondevicerecognition)
