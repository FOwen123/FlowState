import AppKit
import Foundation
import FlowStateCore
import Testing
@testable import FlowStateApp

@Test("live automatic Brave controls on a synthetic local page", .enabled(if: ProcessInfo.processInfo.environment["FLOWSTATE_AUTOMATIC_SMOKE"] == "1"))
@MainActor func liveAutomaticBraveControls() async throws {
    let coordinator = SpeechSessionCoordinator()
    await coordinator.pushToTalkDown()
    let model = FlowStateAppModel(speechCoordinator: coordinator)
    model.consume(SpeechRecognitionResult(transcript: "Open Brave", language: .english, isFinal: true, utteranceID: UUID(), sessionEnded: false), token: 0)
    for _ in 0..<150 { if model.voiceStatus.hasPrefix("Completed:") { break }; try await Task.sleep(for: .milliseconds(20)) }
    #expect(NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.brave.Browser")
    #expect(model.voiceStatus.hasPrefix("Completed:"))
    let page = FileManager.default.temporaryDirectory.appendingPathComponent("flowstate-automatic-scroll-test.html")
    try ("<!doctype html><title>FlowState scrolling test</title><h1>FlowState synthetic scrolling test</h1>" + (1...250).map { "<p style='height:60px'>Synthetic row \($0)</p>" }.joined()).write(to: page, atomically: true, encoding: .utf8)
    let brave = try #require(NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.brave.Browser"))
    _ = try await NSWorkspace.shared.open([page], withApplicationAt: brave, configuration: NSWorkspace.OpenConfiguration())
    try await Task.sleep(for: .seconds(1))
    for command in ["Scroll down", "Scroll up"] {
        model.consume(SpeechRecognitionResult(transcript: command, language: .english, isFinal: true, utteranceID: UUID(), sessionEnded: false), token: 0)
        try await Task.sleep(for: .seconds(1))
        print("Automatic control result:", model.voiceStatus)
        #expect(model.voiceStatus == "Completed: Scroll")
    }
    model.stopVoiceSession()
}
