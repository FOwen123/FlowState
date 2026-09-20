import AppKit
import Testing
@testable import FlowStateCore

@Test("the configured option-space shortcut requires option without command or control")
func optionSpaceShortcutMatching() {
    let optionSpace = NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [.option],
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: " ",
        charactersIgnoringModifiers: " ",
        isARepeat: false,
        keyCode: 49
    )!
    let commandSpace = NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [.command, .option],
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: " ",
        charactersIgnoringModifiers: " ",
        isARepeat: false,
        keyCode: 49
    )!
    #expect(GlobalVoiceShortcutMonitor.matches(optionSpace, shortcut: .optionSpace))
    #expect(GlobalVoiceShortcutMonitor.matchesOptionSpace(commandSpace) == false)
}

@Test("configured shortcuts match only their selected modifier combination")
func configuredShortcutMatching() {
    func event(_ flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: " ",
            charactersIgnoringModifiers: " ",
            isARepeat: false,
            keyCode: 49
        )!
    }

    #expect(GlobalVoiceShortcutMonitor.matches(event([.control, .option]), shortcut: .controlOptionSpace))
    #expect(!GlobalVoiceShortcutMonitor.matches(event([.option]), shortcut: .controlOptionSpace))
    #expect(GlobalVoiceShortcutMonitor.matches(event([.control, .shift]), shortcut: .controlShiftSpace))
    #expect(!GlobalVoiceShortcutMonitor.matches(event([.control, .shift, .option]), shortcut: .controlShiftSpace))
    #expect(!GlobalVoiceShortcutMonitor.matches(event([.control, .shift, .command]), shortcut: .controlShiftSpace))
    #expect(GlobalVoiceShortcutMonitor.matches(event([.option]), shortcut: .optionSpace))
}

@Test("legacy settings migrate to the safe default and missing shortcut defaults safely")
func legacyShortcutSettingsDecode() throws {
    let legacy = Data(#"{"language":"en-US","mode":"command","activation":"pushToTalk","wakePhrase":"Hey Flow State","pushToTalkKey":"⌥ Space"}"#.utf8)
    let decoded = try JSONDecoder().decode(SpeechSettings.self, from: legacy)
    #expect(decoded.shortcut == .controlShiftSpace)

    let missing = Data(#"{"language":"en-US","mode":"command","activation":"pushToTalk","wakePhrase":"Hey Flow State"}"#.utf8)
    let defaulted = try JSONDecoder().decode(SpeechSettings.self, from: missing)
    #expect(defaulted.shortcut == .controlShiftSpace)
    let chosen = SpeechSettings(shortcut: .optionSpace)
    let restored = try JSONDecoder().decode(SpeechSettings.self, from: JSONEncoder().encode(chosen))
    #expect(restored.shortcut == .optionSpace)
}

@Test("automation input is tagged separately from physical takeover")
func automationEventTagging() {
    let source = CGEventSource(stateID: .combinedSessionState)!
    let event = CGEvent(keyboardEventSource: source, virtualKey: 49, keyDown: true)!
    event.setIntegerValueField(
        .eventSourceUserData,
        value: Int64(bitPattern: InputTakeoverMonitor.automationEventTag)
    )
    let nsEvent = NSEvent(cgEvent: event)!
    #expect(InputTakeoverMonitor.isAutomationEvent(nsEvent))
}

@Test("native key events carry the automation tag")
func nativeKeyEventsCarryAutomationTag() {
    let source = CGEventSource(stateID: .combinedSessionState)!
    let event = CGEvent(keyboardEventSource: source, virtualKey: 48, keyDown: true)!
    AXDesktopDriver.tagAutomationEvent(event)
    let nsEvent = NSEvent(cgEvent: event)!
    #expect(InputTakeoverMonitor.isAutomationEvent(nsEvent))
}

@Test("Flow State local UI events cannot pause automation in another app")
func flowStateLocalEventsAreIgnored() {
    let event = NSEvent.mouseEvent(
        with: .leftMouseDown,
        location: .zero,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: 1,
        context: nil,
        eventNumber: 1,
        clickCount: 1,
        pressure: 1
    )!
    #expect(InputTakeoverMonitor.isFlowStateOwnedLocalEvent(event))
}

@Test("a newer input epoch invalidates callbacks from the previous grant")
func staleInputEpochCannotPass() {
    var gate = InputEpochGate()
    let first = gate.advance()
    let second = gate.advance()

    #expect(gate.isCurrent(second))
    #expect(!gate.isCurrent(first))
}

@Test("releasing Option before Space still ends push to talk and allows the next press")
func releaseWithoutOption() {
    var state = ShortcutPressState()
    func event(_ type: NSEvent.EventType, flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(with:type, location:.zero, modifierFlags:flags, timestamp:0, windowNumber:0, context:nil, characters:" ", charactersIgnoringModifiers:" ", isARepeat:false, keyCode:49)!
    }
    #expect(state.consume(event(.keyDown,flags:.option)) == true)
    #expect(state.consume(event(.keyDown,flags:.option)) == nil)
    #expect(state.consume(event(.keyUp,flags:[])) == false)
    #expect(state.consume(event(.keyDown,flags:.option)) == true)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["FLOWSTATE_HOTKEY_SMOKE"] == "1"))
@MainActor
func nativeHotkeyRegistrationDetectsConflictAndReleasesOnDeinit() throws {
    var first: GlobalVoiceShortcutMonitor? = GlobalVoiceShortcutMonitor()
    let second = GlobalVoiceShortcutMonitor()
    defer { second.stop() }
    try #require(first?.start(onKeyDown: {}, onKeyUp: {}) == true)
    #expect(!second.start(onKeyDown: {}, onKeyUp: {}))
    #expect(second.registrationError != nil)
    first = nil
    #expect(second.start(onKeyDown: {}, onKeyUp: {}))
    #expect(second.registrationError == nil)
}
