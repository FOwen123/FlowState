# Development privacy boundaries

The Mac captures audio only after activation and uses Apple's on-device SpeechAnalyzer models. The English model asset must be installed. Raw microphone audio has no managed upload path. In Auto mode, completed utterances and minimal permitted app metadata are sent to managed inference when cloud interpretation is enabled. Window images require a separate cloud-context preference as well as macOS Screen Recording permission. The preference is remembered across app restarts. The wake-phrase option keeps local recognition active while enabled; microphone and real wake behavior still require manual acceptance.

After Accessibility access is granted, desktop commands target the active app or an app named in the command automatically. No app picker or per-app approval is required. Internal grants still bind execution to the resolved target and expire. A new command invalidates older inference; physical input cancels pending work, and uncertain effects require explicit reconciliation.

ScreenCaptureKit selects the relevant window automatically. When cloud screen context is enabled, a fresh bounded frame may be uploaded for visual interpretation. Stop, changed targets and revoked screen context invalidate pending observations. Secure fields and excluded applications are blocked conservatively, but ordinary private content visible in a window is not redacted. This is not complete sensitive-content detection.

When managed interpretation is enabled, command text and minimal active-app metadata go to Convex and TypeSafe; uncertain cases may use OpenAI. Cloud proposals still require confirmation because evaluation does not support unattended operation. Exact local controls can act directly after target and Accessibility checks. The native contract supports app opening, bounded scrolling, focused-control focus/selection, allowlisted keys and text insertion; arbitrary visual clicking is not implemented.

Research sends the requested topic and public-page URLs/content to configured research/model services. Firecrawl receives no browser cookies or personal browser session. AgentMail sends from the configured assistant inbox, not personal Gmail. Sending requires exact sender, recipient, subject and body review. Signed delivery webhooks store event identifiers/status metadata, not raw message bodies.

Local preferences live in macOS UserDefaults. They are not encrypted secrets storage; never save passwords there. Native/web preference synchronization is not implemented. Authentication uses the official Clerk/Convex bridge and SDK credential storage; actual signed-in session behavior remains an acceptance gate.

Convex stores account-scoped workflow content, approvals and preferences. The Privacy panel exposes deletion with explicit confirmation. Current-day quota counters and redacted uncertain delivery records may remain to prevent quota reset and duplicate sends. The retention purge function requires scheduling before relying on automatic expiration; a configured retention duration alone does not run it. Provider-side retention is governed separately by each provider account.

Daily limits count requests, not dollars. Set provider-side budget alerts/limits before exposing managed services publicly. This development implementation is not a completed privacy/security audit.
