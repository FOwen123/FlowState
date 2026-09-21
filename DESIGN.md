# Flow State design system

Dark, minimal, and quietly responsive. Flow State helps people navigate everyday Mac apps, dictate, research, and complete tasks with less sustained typing and scrolling. Its interface should make the next action clear while leaving attention on the user's work.

This document defines the intended visual system for the native Mac controller and web reading workspace. It is a design specification, not evidence of implemented features. [PRODUCT.md](PRODUCT.md) is the source of truth for product behavior; [PLAN.md](PLAN.md) translates it into implementation work. Use **Flow State** in the interface and **FlowState** for repository and code identifiers.

## Brand mark

Use `assets/brand/exports/flowstate-logo.png`, the circular flowing-line mark, for the landing page, settings headers, and menu-bar identity. Paper uses the original image with an inverted light treatment on dark surfaces; preserve its aspect ratio. The HUD waveform is an activity indicator, not the logo. The design-system board includes the canonical asset reference.

## Shared landing page theme — September 21, 2026

The landing page uses “14 · Hero motion / Woodland blur” for its hero: full-width woodland imagery, centered product copy and a compact voice-strip preview. A subtle background pan stops under Reduce Motion. Keep the remaining page short and retain the brand typography. This supersedes the earlier monochrome and split-vignette hero directions. Use the shared dark canvas `--color-app-canvas`, a restrained glass voice strip, deep emerald wordmark symbol and accents, and a pill-shaped download action with deep emerald text on `--color-app-selected`. Keep body copy white or muted gray. Show the approved compact HUD B as a non-interactive interface preview in the hero. Preserve the release-availability disclosure. Shared app color tokens intentionally power both surfaces; the older pure-black web token block below is a legacy reference where these rules override it.

## Approved native app override — September 21, 2026

This section supersedes the older monochrome, capsule, and surface rules below **for the Mac app only**. The landing page shares the theme as specified above; the reading workspace has not been redesigned. Product behavior remains governed by PRODUCT.md.

- Deep emerald `#059669` is the app interaction accent: selected navigation text and icons, pressed control text, and the listening waveform. Default labels stay white; disabled controls stay muted. Sidebar selection uses an 8px rounded rectangle with a dark background and no outline; the persistent filled row distinguishes selection beyond text color. Pressed buttons retain their outline.
- Selected/pressed backgrounds are opaque `#071d17` to preserve emerald text contrast. Keep keyboard focus white. Do not place small deep-emerald text on lighter glass surfaces.
- Use restrained dark glass for floating controls and navigation; solid `#101113` canvas and `#191a1d` content panels. Content panel radius is 20px and window radius is 24px. Paper approximates the material; native Liquid Glass requires platform implementation.
- The menu is a compact 280px-wide native-style list: Start session (Stop session while active), Settings, and Quit, separated by subtle rules. Use 32px rows, 6px outer padding, and 12px panel corners. Omit the heading, status paragraph, and boxed primary button. Start session has a small 14px outline play triangle with an 8px label gap, without an icon background or extra button chrome. Default row text is white; hovered/pressed rows use the dark selected background and deep emerald text. Remove permission requests, app pickers, capture controls, and desktop-control diagnostics from this menu; their appropriate settings and contextual task flows retain those responsibilities. Never offer Start while a session is already active.
- The approved HUD is option B: a 360 × 56 transcript strip, pill corners, 12px padding, 16px gaps, deep-emerald waveform, white 15px transcript, and one stop-square control. Remove the labeled Finish/Stop pair. Keyboard commands remain primary. The square ends the session; a tick would submit speech and is not interchangeable. Provide an accessible Stop name, hover hint, and at least a 44 × 44 interaction target around the smaller visible control.
- Long transcripts, confirmations, and recovery states may expand; retain the existing requirements for explicit modes, processing disclosures, and exact action targets. A simplified listening HUD does not remove those requirements.
- Paper's native app typography uses Helvetica Neue as an available approximation of native system text: caption 12px, controls 14px, transcript 15px, heading 26px. The preferred brand families and web fallbacks below remain unchanged.

### Paper system

The FlowState Paper file contains **00 · Flow State / App design system**: palette, typography, spacing, default/pressed/focused/disabled controls, and the canonical HUD. These are editable reference components, not automatically linked component instances. Shared tokens are bound to the app screens; changing a token updates its bound uses. Historical exploration boards and the original app screenshot remain references.

```css
--color-app-canvas: #101113;
--color-app-surface: #191a1d;
--color-app-hud: #19221f;
--color-app-selected: #071d17;
--color-app-accent: #059669;
--color-app-control-border: #53615a;
--font-app: 'Helvetica Neue';
--text-app-caption: 12px;
--text-app-control: 14px;
--text-app-transcript: 15px;
--text-app-heading: 26px;
--radius-app-selection: 8px;
--radius-app-panel: 20px;
--radius-app-window: 24px;
```

Reuse the existing white text, muted text, white focus, and pill-radius tokens. Paper spacing tokens use `--spacing-4` through `--spacing-96` for the documented 4, 8, 12, 16, 24, 32, 48, 64, 96 scale. The landing page now explicitly binds the shared app color tokens; other web surfaces retain their existing bindings.

## Visual direction

Use the supplied Resend reference's pure-black canvas, white headings, Bone White body text, and Graphite Hairline borders. Primary actions are outlined and neutral. Keep the voice capsule compact, with readable state labels and restrained translucency where useful. Spacious layouts, precise typography, and clear state changes provide the freshness.

This replaces the earlier slate palette. Apply the new reference's color and outlined-control treatment while retaining Flow State's chosen fonts, short landing page, product imagery, and native layouts. The request to remove violet still applies: omit the reference's violet accents, colorful action fills, decorative cube, and developer-code styling.

Dark is the chosen appearance for both product surfaces. A light theme or theme picker is outside this brief. Native system permission and authentication dialogs retain their system appearance.

## Color and surfaces

| Role | Value | Use |
| --- | --- | --- |
| Canvas / Void Black | `#000000` | Page background and base layer |
| Surface | `#000000` | Reading workspace and panels, separated by hairline borders |
| Raised surface / Surface Lift | `#0b0e14` | Menus, selected rows, and hover feedback |
| Primary text / White | `#ffffff` | Headings, current action, and primary control labels |
| Secondary text / Bone White | `#f0f0f0` | Body copy, waveform, and supporting descriptions |
| Muted text / Ash Gray | `#a1a4a5` | Helper copy, metadata, and placeholders at full opacity |
| Links / Smoke Gray | `#abafb4` | Supporting links; use Bone White for prominent links |
| Divider / Graphite Hairline | `#292d30` | Decorative separators and panel outlines |
| Control border / Iron | `#6e727a` | Essential input and button boundaries |
| Charcoal | `#464a4d` | Nonessential decorative strokes, never small text |
| Primary action | `#000000` | Outlined action with White text, no colored fill |
| Primary hover / active | `#0b0e14` | Neutral feedback, reinforced by text or a visible outline |
| Focus | `#ffffff` | Visible keyboard focus ring |

Buttons use the reference's ghost treatment. The reference contains conflicting notes about blue filled actions; Flow State follows its repeated outlined-button rule. No violet, blue, or other chromatic brand accent is used. Native macOS window controls may retain their standard system colors.

Graphite Hairline separates panels but is too subtle for a control whose boundary must be visible. Use Iron for essential control outlines and White for focus. Keep Ash Gray text fully opaque. Charcoal is reserved for decoration, not helper copy. Neutral links need an underline or an explicit action label; selected controls need a check, label, or outline as well as their background change.

The capsule uses `rgba(0, 0, 0, 0.95)` with pure black as its opaque alternative. Reading notes, settings, inputs, and confirmation previews remain solid. Use borders for separation, without gradients, colored glow, or decorative drop shadows. Listening uses a Bone White waveform and a visible text label.

## Typography

Retain the three families from the original design reference. They are the preferred fonts on both web and native custom views, subject to the availability of appropriately licensed font files. This supersedes the earlier system-font-only design preference.

| Family | Role | Weights | Fallback when unavailable |
| --- | --- | --- | --- |
| Untitled Sans | Body, transcript, controls, inputs, notes, helper text | 400, 500, 600; 700 only for necessary emphasis | Inter, then system sans-serif |
| aeonikPro | Flow State wordmark, hero, major section and screen headings | 400, 500 | Space Grotesk, then system sans-serif |
| dotDigital | Occasional short display labels and preview annotations | 400 | JetBrains Mono, then system monospace |

Keep critical status text, confirmation targets, and controls in Untitled Sans. dotDigital is a restrained detail, not the default for every section heading or functional label. Its short display labels may use uppercase with `0.10em` tracking. aeonikPro headings use normal tracking and solid primary text, without gradient fills.

| Text role | Family | Weight | Web size | Line height |
| --- | --- | --- | --- | --- |
| Metadata | Untitled Sans | 400 | 14px | 1.43 |
| Body and controls | Untitled Sans | 400 or 500 | 16px | 1.50 |
| Reading note | Untitled Sans | 400 | 18px | 1.60 |
| Small heading | Untitled Sans | 600 | 24px | 1.25 |
| Screen heading | aeonikPro | 500 | 28px | 1.20 |
| Section heading | aeonikPro | 500 | 36px to 44px | 1.18 |
| Hero | aeonikPro | 500 | 36px to 64px | 1.06 to 1.17 |
| Display annotation | dotDigital | 400 | 15px | 1.20 |

On macOS, use points and scalable text styles rather than copying CSS units. Primary capsule text starts at 16pt. Honor larger text settings and allow wrapping without hiding the action target. Font substitutions must preserve readable layout; never shrink text to keep a decorative composition intact.

English and Traditional Chinese are launch languages, including mixed speech. Use Noto Sans TC or a system Traditional Chinese fallback where the chosen Latin fonts lack glyphs. Allow bilingual transcripts and labels to wrap without reducing legibility.

Font family names do not establish permission to redistribute font files. Confirm web and desktop embedding rights when adding the assets, use the files' actual registered family names, and keep fallbacks until those assets are available. Font binaries are not part of this document change.

## Spacing and shape

Use a 4-unit base with a small working scale: 4, 8, 12, 16, 24, 32, 48, 64, and 96. Use CSS pixels on the web and points in native layouts.

- Web content width: up to 1200px; reading text: 65 to 72 characters per line.
- Page gutters: 24px on desktop and 16px on narrow screens.
- Marketing section spacing: 96px on desktop and 64px on mobile.
- Workspace spacing: 24px between groups, 12px to 16px within a group.
- Panels: 24px padding on desktop, 16px on mobile, 16px corner radius.
- Inputs and compact status labels: 6px radius.
- Standalone primary actions: 6px radius, at least 44px high, 16px to 24px horizontal padding. Keep the native voice capsule and its compact controls rounded.
- Icon controls: at least 44 by 44 units for the interaction target, with a smaller visible glyph.

Use open rows and spacing for note lists and workflow progress. Panels group content with a shared task; do not wrap every label or paragraph in a separate card. Use surface color and outlines for elevation; omit decorative shadows.

## Native Mac controller

### Placement and session controls

Flow State lives in the menu bar. Its heads-up display is a transient bottom-center capsule, starting at 360pt wide and expanding only when content needs more space. Keep clear of the Dock and screen safe areas. Let longer transcripts and exact confirmation targets wrap into a rounded panel, rather than squeezing them into a pill.

The menu exposes Start session, Pause listening, Settings, and Quit. Support configurable push-to-talk, an explicit hands-free session, and an opt-in locally detected wake phrase. Show activation and listening status clearly. Wake activation must be validated before release.

With no session active, hide the capsule and turn screen capture off. During an enabled session, keep a visible microphone indicator between commands, with a way to pause or stop. Displaying status must preserve focus in the user's target application.

### Interaction states

| State | Display | Available action |
| --- | --- | --- |
| Idle | Capsule hidden; menu-bar session state remains accessible | Start session |
| Listening | Live waveform, partial transcript, explicit Command or Dictation mode | Stop |
| Resolving | Interpreted goal and Local or Cloud label | Stop |
| Acting | Current action and honest step progress, such as "Opening Safari" | Stop |
| Confirming | Exact action, target, and effect in an expanded solid panel | Named confirm action and Cancel |
| Paused | Explain that physical input paused desktop actions; preserve the task checkpoint | Resume task or Cancel |
| Complete | Brief verified outcome, such as "Note inserted" | Undo the last verified reversible action where available, or Dismiss |
| Blocked | Specific permission, unsupported operation, or failed verification | One relevant recovery action and Cancel |
| Cancelled | "Stopped" and any action already completed | Dismiss; no automatic restart |

Use a Bone White waveform only while listening. A neutral session indicator with a microphone icon and explicit listening label identifies active listening; omit glow. Resolving and acting use a compact progress indicator without pretending that processing is microphone activity.

Keep Stop visible throughout listening, resolving, and acting, and Cancel visible during confirmation. Support the local spoken stop/cancel path and global cancel shortcut. Cancellation must not wait for cloud processing; late results must not resume a stopped workflow.

Real mouse or keyboard input pauses desktop actions at the next safe point. Resume is explicit and rechecks focus, app state, and permission grants. Say “stop” or “停止” to cancel; distinguish cancellation from a resumable pause.

Show Local or Cloud in plain text. Before sending data off the Mac, identify the provider and data involved. Do not hide this information behind a tooltip. Native command and dictation modes must be explicit so dictated command words cannot accidentally execute actions.

### Confirmation and recovery

A confirmation shows the exact target and effect before the action proceeds. For reading-note delivery, show recipient, subject, and full body. Use "Send note" and "Cancel" rather than "Yes" and "No". Editing the target or content invalidates prior approval.

Voice-accessible controls do not replace the product's required user-presence checks for high-impact actions. Native sending uses the system authentication path described in PRODUCT.md. If unavailable, retain the draft and explain the limitation.

Blocked messages explain the next step, such as "Accessibility access is off" with "Open settings". Verification failures must remain visible as failures or unverified outcomes. Never turn an attempted action into a success animation without evidence.

### Settings and onboarding

Use a compact sidebar with Voice & activation, Tasks & history, Memory, and Permissions. Voice settings expose hands-free sessions, local wake activation, optional push-to-talk, and English + Traditional Chinese speech. Introduce permissions in context rather than requiring every grant during onboarding.

Permissions show the capability, app or resource, duration or expiry, and a revoke control. Separate observation, file reading, input, upload, sending, and spending. Reading a file does not authorize uploading it. Show the active task's grants and capture only its relevant approved window or crop, excluding sensitive content.

Memory lists explicit preferences with their source and Edit/Delete actions. Keep synchronization separately controllable and automatic learning off by default. Learned choices never override explicit instructions. History exposes retention and deletion; raw audio and screenshots are not retained by default.

Explain cloud providers, data sent, and retention before transmission. Managed inference must not be presented as entirely local; display the actual speech processing route rather than promising unverified offline support.

## Web reading workspace

The web experience lets someone choose a public article, follow real processing progress, and read a saved source-linked note. It does not control an unpaired Mac. The native controller and reading workspace share typography, colors, control shapes, and status language.

### Public entry

Keep the landing page short: a wordmark and restrained navigation, a strong headline (“Your Mac, in your words.”), one task preview, the creator's reason for building Flow State, three capability summaries, and a quiet footer. The preview shows bilingual speech, honest multi-step progress, cloud disclosure, and a stable Stop control.

Use an outlined “Download for Mac” action in the design preview with availability stated nearby. A live page must only link to an actual distributable release; otherwise show an unavailable or release-notification state. Do not invent system requirements, pricing, or licensing claims.

### Workspace layout

On wide screens, place the source picker and note list in a modest left column, with the current note in a generous reading column. Put workflow status close to the active request. On narrow screens, stack source selection, status, and note in that order. Avoid horizontal scrolling and keep primary controls reachable without hover.

The guest entry offers curated public articles and clearly states that the workflow uses cloud processing. Explain that requested article excerpts and generated notes are stored, and expose deletion controls. Guests see only their own session and cannot send email or view the owner's private notes, aliases, or inbox.

Owner delivery appears only in the authenticated owner workspace, with an exact preview and explicit approval. Show provider acceptance separately from confirmed delivery. Do not label an accepted request "Delivered" before confirmation.

| Workflow state | Suggested visible text |
| --- | --- |
| Queued | "Waiting to start" |
| Fetching | "Fetching article" |
| Summarizing | "Writing your reading note" |
| Ready | "Note saved" |
| Awaiting approval | "Review before sending" |
| Delivering | "Sending note" |
| Sent | "Accepted by email provider"; show "Delivered" only with delivery evidence |
| Failed | Specific failure with one appropriate recovery action |
| Cancelled | "Stopped" with any saved result still accessible |

Display real state transitions instead of fake percentages or staged typing animations. Keep source title and link attached to the note. A failed fetch offers source selection or retry; an uncertain send result requires status reconciliation before offering another send.

## Shared components

| Component | Treatment | Flow State use |
| --- | --- | --- |
| Primary button | Black or transparent fill, Iron outline, White text, 6px radius, medium weight | Start session, create a reading note, approved next action |
| Secondary button | Raised solid fill or visible outline, primary text | Stop, Cancel, open settings, view source |
| Text input | Solid surface, control border, visible label, readable placeholder | Owner article URL or saved app alias where supported |
| Status label | Neutral background, icon and plain-language text; active states add a visible check or outline | Local, Cloud, Command, Dictation, Blocked |
| Reading note | Solid surface, generous line spacing, source link | Generated note and editable delivery preview |
| Progress row | Small indicator, step name, status text | Fetching, summarizing, saving, sending |
| Confirmation panel | Opaque raised surface, full target and effect, two clear actions | Consequential operation preview |

Every interactive component needs a visible focus state, a pressed state, and a readable disabled state. A disabled action explains its prerequisite nearby. Hover is a supplement, never the only way to discover a control. Keep Stop visually stable even when the primary action changes.

Use simple outline icons with consistent stroke weight. Native system symbols may be used for familiar actions. Avoid decorative circular icon tiles for every feature, and label unfamiliar icons.

## Motion and accessibility

- Use 120ms to 180ms transitions for control feedback and up to 220ms for capsule expansion. Prefer a gentle ease-out without bouncing or looping ambient motion.
- Waveform motion reflects actual microphone input. Progress motion reflects processing; keep those signals distinct.
- Reduce Motion replaces waveform movement and expansion animation with a static listening symbol and immediate state changes.
- Reduce Transparency uses an opaque capsule. On the web, opaque is the default unless transparency support and user preferences permit the optional effect.
- Aim for at least 4.5:1 contrast for body text and 3:1 for meaningful control boundaries and focus indicators. Verify rendered states, including translucent backgrounds.
- Keep controls keyboard accessible, provide VoiceOver labels, and announce meaningful state transitions without repeating every partial transcript.
- Every native action needed during an enabled session has a voice path. Do not require sustained key holding, dragging, or hover.
- Preserve focus in the target Mac app when status appears. Speech prompts must not become new commands.
- Allow text enlargement, long names, full confirmation targets, and responsive reflow. Never truncate the information needed to approve an action.

## Product imagery and copy

Use close-ups of Flow State interfaces: bilingual commands, explicit Command or Dictation mode, task progress, physical takeover, scoped permissions, and editable memory. Include everyday apps and research or writing tasks rather than centering developer tools. Planned interactions remain visibly labeled as previews.

Until behavior is implemented, label compositions "Design preview" or "Simulated Mac interaction" beside the visual. Real recordings show actual app actions. Browser previews must never imply control of a visitor's Mac.

Write literal status and action text. Prefer "Opening Safari", "Note saved", and "Microphone access is off". Avoid vague claims such as "Controls everything" or unmeasured speed guarantees. Use no medical claims.

The Flow State wordmark uses aeonikPro at weight 500 in a solid White. Keep it proportional to the interface, rather than turning it into the page's main illustration. dotDigital may appear once as a short preview annotation; repeated decorative labels add clutter.

## Canonical web tokens

This single token block replaces the imported duplicate CSS and incomplete values. It defines design values only; loading font assets and wiring component behavior belong to implementation. Native views map the same semantic roles to SwiftUI colors, fonts, and dimensions.

```css
:root {
  color-scheme: dark;

  --color-canvas: #000000;
  --color-surface: #000000;
  --color-raised: #0b0e14;
  --color-text: #ffffff;
  --color-text-secondary: #f0f0f0;
  --color-text-muted: #a1a4a5;
  --color-link: #f0f0f0;
  --color-link-secondary: #abafb4;
  --color-action: #000000;
  --color-action-hover: #0b0e14;
  --color-on-action: #ffffff;
  --color-active: #0b0e14;
  --color-divider: #292d30;
  --color-control-border: #6e727a;
  --color-focus: #ffffff;
  --color-decorative: #464a4d;
  --color-capsule-glass: rgba(0, 0, 0, 0.95);

  --font-body: 'Untitled Sans', 'Inter', system-ui, sans-serif;
  --font-display: 'aeonikPro', 'Space Grotesk', system-ui, sans-serif;
  --font-detail: 'dotDigital', 'JetBrains Mono', ui-monospace, monospace;

  --text-small: 0.875rem;
  --text-body: 1rem;
  --text-reading: 1.125rem;
  --text-heading-small: 1.5rem;
  --text-heading: 1.75rem;
  --text-section: clamp(2.25rem, 4vw, 2.75rem);
  --text-hero: clamp(2.25rem, 5vw, 3rem);
  --text-detail: 0.9375rem;

  --space-1: 4px;
  --space-2: 8px;
  --space-3: 12px;
  --space-4: 16px;
  --space-6: 24px;
  --space-8: 32px;
  --space-12: 48px;
  --space-16: 64px;
  --space-24: 96px;

  --radius-label: 6px;
  --radius-input: 6px;
  --radius-button: 6px;
  --radius-panel: 16px;
  --radius-pill: 999px;
  --page-width: 1200px;
  --reading-width: 68ch;
  --control-min-height: 44px;
  --shadow-floating: none;
  --shadow-listening: none;
  --focus-ring: 0 0 0 3px var(--color-focus);
  --duration-feedback: 150ms;
  --duration-expand: 220ms;
  --ease-out: cubic-bezier(0.22, 1, 0.36, 1);
}
```

## Design acceptance

Before shipping an interface built from this document, verify that:

- The three preferred font families render when installed, and fallbacks preserve layout when absent.
- Dark surfaces remain readable at narrow widths, enlarged text, and bright desktop backgrounds behind the capsule.
- Listening, command/dictation mode, Local/Cloud processing, Stop, confirmation, and blocked states are understandable without color or animation.
- Keyboard, VoiceOver, Reduce Motion, and Reduce Transparency flows work; the capsule does not steal target-app focus.
- The guest reading workflow and owner-only delivery controls match their actual permissions and backend states.
- Preview labels, release availability, completion messages, and delivery claims match implemented evidence.

These are implementation acceptance checks. Updating this document does not establish that the application passes them.

### Feedback panel refinement — September 21, 2026

Ordinary listening stays a minimal waveform and cancel strip. Expanded feedback uses an opaque dark HUD surface for consistent text contrast over other apps. Keep only the cancel control and conditional action confirmation in the panel; Replay, spoken-response preferences, and Settings belong in the settings window reached from the menu bar. Avoid repeating the same spoken response as the status.

### Stable floating controls — September 21, 2026

This supersedes earlier native floating-control color, glass, waveform, and transcript-strip rules. Use the user-selected menu background `#19221f`, white waveform and labels, and the existing subdued border. Both menu and HUD use opaque surfaces; do not switch to bright glass or an emerald waveform while listening. Keep the HUD 280px wide at the bottom center of the primary display, 24px above its visible frame. The waveform/cancel row stays at the bottom; required feedback expands upward. Do not follow the pointer between displays or echo dictated text or previous spoken replies. Keep concise status, current task steps and required confirmations readable. The settings and web themes are unchanged by this floating-control override.

The listening waveform fills the available row with 25 tapered white bars and a 30px height, beside the existing 44px cancel hit target. Animate smoothly at up to 60fps only while listening; Reduce Motion and inactive states remain static. This remains an activity indicator, not a microphone level meter.

Feedback height changes use one native 350ms ease-in/ease-out window animation, anchored at the bottom. Disable automatic hosting-view window sizing to prevent a second resize. Repeated updates to the same destination do not restart motion; Reduce Motion uses immediate resizing.

During feedback expansion, lay out the hosted content once at its destination size inside a bottom-aligned clipping container. Animate only the outer window; do not resize SwiftUI content on each animation frame, which makes the controls dip before rising.

### Settings organization — September 21, 2026

Use short sidebar labels: General, Models, History, Memory, Permissions, Account. General starts with Mac Control; dictation is a separate secondary shortcut. Models contains speech download and language. Omit the Gmail settings page; existing desktop mail workflows do not need a dedicated sidebar section. Settings buttons use plain surfaces with explicit hit areas and visibly dimmed disabled states. Account copy should describe the action directly, without benefit lists or promotional text.
