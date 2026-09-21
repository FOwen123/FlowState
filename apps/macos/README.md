# FlowState Mac development app

Requires macOS 26.2 or newer. Tested on Apple M5 Pro / macOS 26.6.2 with Xcode 27 and Swift 6.4; other Mac configurations are unverified.

The package includes a SwiftUI menu-bar/settings app, on-device SpeechAnalyzer recognition for English, field-bound dictation, conversational Mac control, automatic app targeting, local cancellation, native spoken responses, local personalization, and the official Clerk/Convex cloud bridge. Consequential managed actions require review. See `../../docs/testing/results.md` for tested boundaries; this is not a signed production release.

## Check and package locally

From the repository root:

```sh
pnpm test:native
node scripts/package-macos-debug.mjs
```

The packaging helper copies the executable already compiled by Swift tests into `apps/macos/.build/FlowState.app`, embeds usage descriptions and the login callback, and signs it ad hoc by default. For a stable local signing identity across rebuilds, set `FLOWSTATE_CODESIGN_IDENTITY` to an Apple Development identity listed by `security find-identity -v -p codesigning`. Changing from ad-hoc to development signing requires a fresh permission grant; consistently reuse the same identity afterward. It does not run a production build. It reads only the public Convex URL and Clerk publishable key from `apps/web/.env.local`. Backend provider keys never belong in the bundle.

Open that bundle manually to test the app. Flow State runs from its waveform menu-bar icon and intentionally does not appear in the Dock or Command–Tab. In Settings, request microphone access, install the English speech asset if needed, and configure the two distinct hold-only shortcuts. Dictation defaults to Option–Space when available; the migrated existing shortcut remains Mac Control. Holding starts capture and releasing finalizes it. Resolve any registration conflict in Voice settings before testing. Real shortcut behavior and microphone quality remain acceptance gates.

For desktop input, enable Flow State in macOS Accessibility settings. Mac Control resolves the active app or a uniquely named installed app, such as “Open Brave,” and speaks verified questions, failures, milestones, and completion. It never treats an unknown request as text entry; use Dictation for that. Unrelated physical input may continue while a task runs, but Flow State reobserves before every visible step and replans or asks when the target changed. The persistent X is the authoritative cancellation control. Use disposable documents for early testing.

Dictation binds to the non-secure editable field and selection present at key-down. If focus changes before insertion, Flow State retains the result in local Dictation history and displays recovery actions instead of pasting into the new target. Clipboard restoration is conditional so a value copied by the user during capture is preserved. Dictation and control history default to 30-day local retention and provide per-item and delete-all controls; raw audio and screenshots are not retained.

For cloud features, configure Clerk's hosted-auth redirect `com.flowstate.dev://callback`. Sign in through Cloud account. Start with a public research query; sending from the assistant inbox requires exact review. Gmail in Brave has a reviewed compose-link handoff that opens a draft without sending it; the full browser adapter is not yet implemented.

## Capture and testing boundaries

Synthetic tests never request screen/microphone permissions or inject live input. ScreenCaptureKit captures only task-approved windows into memory and rejects a conservative list of system/password-manager apps. Whole-window capture is not field-level redaction. Cloud screen context is a separate opt-in; when enabled, relevant window screenshots may be uploaded for interpretation. Screen Recording permission alone does not enable uploads.

Packaged permission recovery and the legacy capture UI have been exercised. See [verification results](../../docs/testing/results.md) for current packaged-app permission status and test-process evidence. Both hold shortcuts, changed-focus recovery, spoken responses, cancellation, native login, interrupted actions, and cross-app execution must be exercised interactively before release. A successful Swift test run establishes compilation and fixture behavior, not full product acceptance.

## Opt-in real desktop check

After explicitly granting Accessibility and preparing for a foreground app switch:

```sh
FLOWSTATE_NATIVE_SMOKE=1 swift test --package-path apps/macos --filter liveTextEditOpenInsertUndoAndScroll
```

This opens a disposable TextEdit document, verifies the focused contents match its fixture, tests real app activation, bilingual insertion, exact undo and a visible scrollbar change. It leaves the document open for inspection. It is skipped in normal test runs, makes no network requests, and never sends email or submits a ChatGPT request. Scrolling supports a writable Accessibility scrollbar or a single accessible web area with native scroll-to-visible targets. Brave was tested on a synthetic local page; unsupported app views report an error.

Global hotkey registration can be checked without injecting keyboard events. Quit the running Flow State app first, because it reserves the default shortcut:

```sh
FLOWSTATE_HOTKEY_SMOKE=1 swift test --package-path apps/macos --filter nativeHotkeyRegistrationDetectsConflictAndReleasesOnDeinit
```

This checks reservation, conflict reporting and cleanup. It does not establish microphone recognition or shortcut behavior while another app has focus.

## Packaged menu and capture acceptance

With the debug app already running, the settings check clicks its actual menu gear and verifies the window opens:

```sh
FLOWSTATE_UI_SMOKE=1 swift scripts/macos-menu-smoke.swift settings
```

After Microphone permission and the English speech asset are ready, run this in a quiet room to test the packaged capture surface:

```sh
FLOWSTATE_UI_SMOKE=1 swift scripts/macos-menu-smoke.swift voice
```

The voice check briefly captures microphone input, requires visible Listening status, and presses X/Stop. It does not log transcript content. The floating waveform is an activity animation, not an audio-level meter. Use [`tests/e2e/control-assistant-workflow.md`](../../tests/e2e/control-assistant-workflow.md) for the two-shortcut, dictation-boundary, spoken-response, and cross-app acceptance matrix.
