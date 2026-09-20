# Flow State

A voice controller for macOS, built to reduce repeated typing, clicking, and scrolling. Formerly ProWhisper.

Flow State opens apps, scrolls, types and handles supported controls by voice. A Convex-backed web workspace supports public-article research and reviewed assistant-email workflows.

**Status:** working development prototype with a local macOS debug app and a configured Convex development deployment. It is not a notarized release. See [verification results](docs/testing/results.md) for tested behavior and remaining acceptance work.

- [Product vision and architecture](PRODUCT.md)
- [Hackathon implementation plan](PLAN.md)
- [Verified event requirements and gaps](HACKATHON_REQUIREMENTS.md)
- [Native setup and testing](apps/macos/README.md)
- [Environment configuration](ENVIRONMENT.md)
- [Build log](hackathon.md)
- [Design constraints and visual reference](DESIGN.md)

The stack is Swift/SwiftUI on macOS, React/TypeScript on the web, and Convex for shared data and cloud workflows. OpenAI, Firecrawl and AgentMail support the reading workflow. Local Mac commands remain independent of cloud availability.

The Git remote still uses `FOwen123/ProWhisper`; the local folder is `FlowState`. A GitHub rename has not been performed. Apache-2.0 is the proposed license, not yet an issued license file; add the license and third-party notices before release.
