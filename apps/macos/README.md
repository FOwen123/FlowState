# FlowState Mac development app

Requires macOS 26.2 or newer. Tested on Apple M5 Pro / macOS 26.6.2 with Xcode 27 and Swift 6.4; other Mac configurations are unverified.

The package includes a SwiftUI menu-bar/settings app, on-device SpeechAnalyzer recognition for English and Traditional Chinese, separate per-app input/capture grants, local stop, physical-input pause, text undo, local personalization, and the official Clerk/Convex cloud bridge. Managed command proposals require review. See `../../docs/testing/results.md` for tested boundaries; this is not a signed production release.

## Check and package locally

From the repository root:

```sh
pnpm test:native
node scripts/package-macos-debug.mjs
```

The packaging helper copies the executable already compiled by Swift tests into `apps/macos/.build/FlowState.app`, embeds usage descriptions and the login callback, and signs it ad hoc by default. For a stable local signing identity across rebuilds, set `FLOWSTATE_CODESIGN_IDENTITY` to an Apple Development identity listed by `security find-identity -v -p codesigning`. Changing from ad-hoc to development signing requires a fresh permission grant; consistently reuse the same identity afterward. It does not run a production build. It reads only the public Convex URL and Clerk publishable key from `apps/web/.env.local`. Backend provider keys never belong in the bundle.

Open that bundle manually to test the app. Flow State runs from its waveform menu-bar icon and intentionally does not appear in the Dock or Command–Tab. Voice settings show listening status and the latest transcript, with manual Start/Finish controls. In Settings, request microphone access, install the selected language asset if needed, then configure activation and command/dictation mode. The default global shortcut is Control–Shift–Space; select another in Voice & activation if it conflicts with another app. Real shortcut behavior, wake behavior and microphone quality remain acceptance gates.

For desktop input, choose the target bundle identifier and allowed actions, then grant temporary control. Example Brave identifier: `com.brave.Browser`. Accessibility permission is required. Physical input pauses execution; use Resume to explicitly reobserve the app. Do not use private documents for early testing.

For cloud features, configure Clerk's hosted-auth redirect `com.flowstate.dev://callback`. Sign in through Cloud account. Start with a public research query; sending from the assistant inbox requires exact review. Gmail in Brave has a reviewed compose-link handoff that opens a draft without sending it; the full browser adapter is not yet implemented.

## Capture and testing boundaries

Synthetic tests never request screen/microphone permissions or inject live input. ScreenCaptureKit captures only task-approved windows into memory and rejects a conservative list of system/password-manager apps. Whole-window capture is not field-level redaction. The Mac UI does not upload captured images.

No microphone/Accessibility/ScreenCaptureKit acceptance has yet been recorded on the packaged app. Native login, focus changes, interrupted actions and recovery must be exercised interactively before release. A successful Swift test run establishes compilation and fixture behavior, not full product acceptance.

## Opt-in real desktop check

After explicitly granting Accessibility and preparing for a foreground app switch:

```sh
FLOWSTATE_NATIVE_SMOKE=1 swift test --package-path apps/macos --filter liveTextEditOpenInsertUndoAndScroll
```

This opens a disposable TextEdit document, verifies the focused contents match its fixture, tests real app activation, bilingual insertion, exact undo and a visible scrollbar change. It leaves the document open for inspection. It is skipped in normal test runs, makes no network requests, and never sends email or submits a ChatGPT request. Scrolling currently requires an unambiguous writable Accessibility scrollbar; unsupported app views report an error.

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

After Microphone permission and the app's selected language asset are ready, disable input/cloud action grants, then explicitly test capture:

```sh
FLOWSTATE_UI_SMOKE=1 swift scripts/macos-menu-smoke.swift voice
```

The voice check briefly captures microphone input, requires visible Listening status, and presses Stop. It does not log transcript content. The floating waveform is an activity animation, not an audio-level meter. Spoken accuracy and the physical shortcut still need manual testing.
