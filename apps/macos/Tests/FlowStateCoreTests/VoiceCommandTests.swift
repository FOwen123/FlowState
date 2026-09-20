import Testing
@testable import FlowStateCore

@Test func commandsSupportEnglishNavigationAndRecovery() {
    #expect(VoiceCommandRouter.resolve("scroll down", mode: .command) == .scroll(-3))
    #expect(VoiceCommandRouter.resolve("scroll up", mode: .command) == .scroll(3))
    #expect(VoiceCommandRouter.resolve("stop", mode: .command) == .stop)
    #expect(VoiceCommandRouter.resolve("resume", mode: .command) == .resume)
    #expect(VoiceCommandRouter.resolve("undo", mode: .command) == .undo)
    #expect(VoiceCommandRouter.resolve("open Brave", mode: .command) == .openApp("com.brave.Browser"))
    #expect(VoiceCommandRouter.resolve("switch to Safari", mode: .command) == .openApp("com.apple.Safari"))
    #expect(VoiceCommandRouter.resolve("research keyboard ergonomics", mode: .command) == .research("keyboard ergonomics"))
    #expect(VoiceCommandRouter.resolve("focus text field", mode: .command) == .focus(role: "AXTextField", label: nil))
    #expect(VoiceCommandRouter.resolve("select title", mode: .command) == .select(label: "title"))
    #expect(VoiceCommandRouter.resolve("press shift tab", mode: .command) == .press(key: "Tab", modifiers: "Shift"))
    #expect(VoiceCommandRouter.resolve("press escape", mode: .command) == .press(key: "Escape", modifiers: nil))
}

@Test func dictationDoesNotExecuteCommandWords() {
    #expect(VoiceCommandRouter.resolve("scroll down", mode: .dictation) == .dictate("scroll down"))
    #expect(VoiceCommandRouter.resolve("delete this", mode: .dictation) == .dictate("delete this"))
    #expect(VoiceCommandRouter.resolve("don't scroll down", mode: .command) == .unknown)
    #expect(VoiceCommandRouter.resolve("", mode: .command) == .unknown)
}

@Test func autoModeUsesExactCommandsAndExplicitLiteralPrefix() {
    #expect(VoiceCommandRouter.resolve("scroll down", mode: .auto) == .scroll(-3))
    #expect(VoiceCommandRouter.resolve("type open Brave", mode: .auto) == .dictate("open Brave"))
    #expect(VoiceCommandRouter.resolve("please delete the draft", mode: .auto) == .unknown)
    #expect(VoiceCommandRouter.resolve("open an unknown app", mode: .auto) == .unknown)
}

@Test func englishOnlyControlsAndTextAreaRole() {
    #expect(VoiceCommandRouter.resolve("停止", mode: .auto) == .unknown)
    #expect(VoiceCommandRouter.resolve("focus text area", mode: .auto) == .focus(role: "AXTextArea", label: nil))
}

@Test("every registered keyboard command is explicit and literal-safe", arguments: [
    ("press tab", "Tab", Optional<String>.none), ("press shift tab", "Tab", "Shift"),
    ("press escape", "Escape", nil), ("press enter", "Enter", nil),
    ("press arrow up", "ArrowUp", nil), ("press arrow down", "ArrowDown", nil),
    ("press arrow left", "ArrowLeft", nil), ("press arrow right", "ArrowRight", nil),
    ("press page up", "PageUp", nil), ("press page down", "PageDown", nil),
    ("press home", "Home", nil), ("press end", "End", nil),
    ("select all", "A", "Command"), ("copy", "C", "Command"), ("paste", "V", "Command")
])
func allKeyboardCommandShapes(_ sample: (String, String, String?)) {
    let (phrase, key, modifiers) = sample
    #expect(VoiceCommandRouter.resolve(phrase, mode: .auto) == .press(key: key, modifiers: modifiers))
    #expect(VoiceCommandRouter.resolve("type " + phrase, mode: .auto) == .dictate(phrase))
    #expect(VoiceCommandRouter.resolve("don't " + phrase, mode: .auto) == .unknown)
}
