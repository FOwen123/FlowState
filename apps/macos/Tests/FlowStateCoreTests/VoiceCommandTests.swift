import Testing
@testable import FlowStateCore

@Test func commandsSupportBothLaunchLanguages() {
    #expect(VoiceCommandRouter.resolve("scroll down", mode: .command) == .scroll(-3))
    #expect(VoiceCommandRouter.resolve("往下捲動", mode: .command) == .scroll(-3))
    #expect(VoiceCommandRouter.resolve("向上滾動", mode: .command) == .scroll(3))
    #expect(VoiceCommandRouter.resolve("停止", mode: .command) == .stop)
    #expect(VoiceCommandRouter.resolve("open Brave", mode: .command) == .openApp("com.brave.Browser"))
    #expect(VoiceCommandRouter.resolve("開啟 Brave", mode: .command) == .openApp("com.brave.Browser"))
}

@Test func dictationDoesNotExecuteCommandWords() {
    #expect(VoiceCommandRouter.resolve("scroll down", mode: .dictation) == .dictate("scroll down"))
    #expect(VoiceCommandRouter.resolve("停止", mode: .dictation) == .dictate("停止"))
    #expect(VoiceCommandRouter.resolve("don't scroll down", mode: .command) == .unknown)
    #expect(VoiceCommandRouter.resolve("請不要往下捲動", mode: .command) == .unknown)
    #expect(VoiceCommandRouter.resolve("", mode: .command) == .unknown)
}
