# FlowState macOS native foundation

This package contains the first native safety slice: an explicit menu-bar task grant, ScreenCaptureKit window capture, generation-based revoke/cancellation, and a finite five-minute default grant. Capture results stay in memory; the package does not write screenshots to disk or inject keyboard/mouse events.

## Run checks

From this directory on a Mac with Xcode installed:

```sh
swift test
swift run FlowStateApp
```

The test suite uses a synthetic in-memory image provider. It never requests Screen Recording permission, captures a real window, or sends input. To try the shell manually, run the executable, grant Screen Recording in macOS System Settings, enter an approved application bundle ID such as `com.apple.TextEdit`, begin a task, and press **Capture approved window**. The app does not capture while idle.

The ScreenCaptureKit provider is based on Apple's `SCShareableContent`, `SCContentFilter(desktopIndependentWindow:)`, and `SCScreenshotManager.captureImage` APIs. It refuses a small conservative set of system, login, password-manager, and Keychain bundle IDs. Approved windows are captured in full; field-level redaction is not implemented. A later app layer must add user-facing app discovery, cropping, and the cloud disclosure/retention controls described in `PRODUCT.md` before transmitting any frame.

`Config.example.json` is a proposed public configuration shape; the app does not load it yet. The exact English/Traditional Chinese command parser is unit-tested but is not connected to a microphone or input execution.
