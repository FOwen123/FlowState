import Foundation
import Testing
@testable import FlowStateCore

@Test("dictation target validation requires an editable non-secure focused element")
func dictationTargetValidation() {
    let valid = DictationTarget(observation: DesktopObservation(
        bundleIdentifier: "com.example.Editor",
        focusedElementID: "field-1",
        focusedRole: "AXTextArea",
        isEditable: true,
        isSecure: false,
        selectedTextRange: DesktopTextRange(location: 0, length: 0)
    ), clipboardChangeCount: 4)
    #expect(valid.validationError == nil)
    #expect(valid.matches(valid.observation))

    let secure = DictationTarget(observation: DesktopObservation(
        bundleIdentifier: "com.example.Editor", focusedElementID: "field-1",
        focusedRole: "AXSecureTextField", isEditable: true, isSecure: true
    ), clipboardChangeCount: 4)
    #expect(secure.validationError == .secureField)
}

@Test("dictation target rejects app, focus, or selection drift")
func dictationTargetRejectsDrift() {
    let target = DictationTarget(observation: DesktopObservation(
        bundleIdentifier: "com.example.Editor", focusedElementID: "field-1",
        focusedRole: "AXTextField", isEditable: true,
        selectedTextRange: DesktopTextRange(location: 2, length: 3)
    ), clipboardChangeCount: 1)
    #expect(!target.matches(DesktopObservation(
        bundleIdentifier: "com.example.Editor", focusedElementID: "field-2",
        focusedRole: "AXTextField", isEditable: true,
        selectedTextRange: DesktopTextRange(location: 2, length: 3)
    )))
    #expect(!target.matches(DesktopObservation(
        bundleIdentifier: "com.example.Editor", focusedElementID: "field-1",
        focusedRole: "AXTextField", isEditable: true,
        selectedTextRange: DesktopTextRange(location: 3, length: 3)
    )))
}

@Test("dictation requires a known selection identity or focused-element substitute")
func dictationRequiresSelectionIdentity() {
    let unknown = DictationTarget(observation: DesktopObservation(
        bundleIdentifier: "com.example.Editor",
        focusedElementID: nil,
        focusedRole: "AXTextField",
        isEditable: true,
        selectedTextRange: nil
    ))
    #expect(unknown.validationError == .missingTarget)

    let stableElement = DictationTarget(observation: DesktopObservation(
        bundleIdentifier: "com.example.Editor",
        focusedElementID: "field-1",
        focusedRole: "AXTextField",
        isEditable: true,
        selectedTextRange: nil
    ))
    #expect(stableElement.validationError == nil)
    #expect(stableElement.matches(stableElement.observation))
    #expect(!stableElement.matches(DesktopObservation(
        bundleIdentifier: "com.example.Editor",
        focusedElementID: "field-1",
        focusedRole: "AXTextField",
        isEditable: true,
        selectedTextRange: DesktopTextRange(location: 0, length: 1)
    )))
}

@Test("conservative cleanup preserves command-like words as literal text")
func dictationCleanupIsLiteralSafe() {
    let result = DictationTextCleaner.clean("um open Brave comma please send this")
    #expect(result == "open Brave, please send this")
}

@Test("clipboard restoration only occurs while the Flow State marker remains current")
func clipboardRestorationRequiresMarker() {
    #expect(DictationClipboardTransaction.shouldRestore(
        currentChangeCount: 8, flowStateChangeCount: 8, markerPresent: true
    ))
    #expect(!DictationClipboardTransaction.shouldRestore(
        currentChangeCount: 9, flowStateChangeCount: 8, markerPresent: true
    ))
    #expect(!DictationClipboardTransaction.shouldRestore(
        currentChangeCount: 8, flowStateChangeCount: 8, markerPresent: false
    ))
}

@Test("clipboard ownership does not require the key-down count to remain unchanged")
func clipboardOwnershipStartsAtInsertion() {
    // The user may copy while speech is being transcribed. The insertion
    // transaction starts from that latest clipboard, not the key-down count.
    #expect(DictationClipboardTransaction.shouldRestore(
        currentChangeCount: 42, flowStateChangeCount: 42, markerPresent: true
    ))
}
