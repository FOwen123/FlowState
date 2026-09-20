# Development privacy boundaries

The Mac captures audio only after activation and uses Apple's on-device SpeechAnalyzer models. The English model asset must be installed. Raw microphone audio has no managed upload path. In Auto mode, completed utterances and minimal permitted app metadata are sent to managed inference when cloud interpretation is enabled. Window images require a separate task-level cloud-context opt-in as well as screen observation permission. The wake-phrase option keeps local recognition active while enabled; microphone and real wake behavior still require manual acceptance.

ScreenCaptureKit captures an explicitly approved window into memory. Capture grants expire and can be revoked. Frames currently are not transmitted by the Mac UI. Whole-window capture is not field-level redaction: do not approve private windows for capture. A conservative password-manager/system-app exclusion list does not establish complete sensitive-content detection.

Managed command interpretation is opt-in. Command text and the selected app identifier go through Convex, TypeSafe and OpenAI; the user reviews the action list before desktop execution. Model proposals do not authorize input. The current executor accepts only opening an app, bounded scrolling and text insertion from cloud plans. Unsupported plans fail closed.

Research sends the requested topic and public-page URLs/content to configured research/model services. Firecrawl receives no browser cookies or personal browser session. AgentMail sends from the configured assistant inbox, not personal Gmail. Sending requires exact sender, recipient, subject and body review. Signed delivery webhooks store event identifiers/status metadata, not raw message bodies.

Local preferences live in macOS UserDefaults. They are not encrypted secrets storage; never save passwords there. Native/web preference synchronization is not implemented. Authentication uses the official Clerk/Convex bridge and SDK credential storage; actual signed-in session behavior remains an acceptance gate.

Convex stores account-scoped workflow content, approvals and preferences. The Privacy panel exposes deletion with explicit confirmation. Current-day quota counters and redacted uncertain delivery records may remain to prevent quota reset and duplicate sends. The retention purge function requires scheduling before relying on automatic expiration; a configured retention duration alone does not run it. Provider-side retention is governed separately by each provider account.

Daily limits count requests, not dollars. Set provider-side budget alerts/limits before exposing managed services publicly. This development implementation is not a completed privacy/security audit.
