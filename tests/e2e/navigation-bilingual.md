# Native bilingual acceptance

Target: local M5 Pro MacBook Pro, 24 GB, macOS 26.6.2. Never treat synthetic unit tests as evidence for these interactive checks.

Use a blank TextEdit document, Finder test folder, and a public example page in Safari/Brave. Grant permissions from the app only when needed. Record date, commit, active application, language, permissions, latency and physical interventions in docs/testing/results.md.

1. Deny microphone/speech permission. Verify an actionable error, no recording and no repeated prompts.
2. Permit microphone/speech. Select English command mode, start an explicit session, say “scroll down,” “open Safari,” and “stop.” Repeat in Traditional Chinese: “向下捲動”, “開啟 Safari”, “停止”. Record raw transcription and whether the action matched.
3. Select dictation. Dictate “Please delete the old draft” and “請刪除舊草稿”. Verify the words are inserted, not interpreted as destructive commands.
4. Test a saved app alias and a correction with English names inside Chinese speech. Relaunch; verify explicit preferences persist. Forget a preference; verify it is no longer applied.
5. During a multi-step operation, move the physical mouse and type a harmless character. Verify input pauses and resume requires an explicit request. A late cloud result must not act after stop, even following resume.
6. Edit inserted text manually, then request undo. Verify it refuses to overwrite the intervening edit. A verified unchanged insertion may be restored to its recorded prior value.
7. Revoke Accessibility, screen observation and task grants separately; verify the corresponding action stops. Switching focus between observation and action must prevent input to the new app.
8. Test the configured activation shortcut, toggle session and wake phrase. Test false wakeups with unrelated speech; disable wake mode and verify the microphone stops.
9. Disconnect the network, sleep/wake the Mac and switch the microphone. Record explicit failure/recovery; never label on-device recognition supported without checking each language on this Mac.

Pending interactive execution. No accuracy, memory, acoustic stop-latency or offline-quality claims yet.
