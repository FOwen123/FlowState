import Testing
@testable import FlowStateApp

@MainActor
private final class RecordingSpeechEngine: SpokenSpeechEngine {
    var requests: [SpokenSpeechRequest] = []
    var stopCount = 0

    func speak(_ request: SpokenSpeechRequest) {
        requests.append(request)
    }

    func stop() {
        stopCount += 1
    }
}

@Test("spoken response policy covers questions, meaningful milestones, and completion")
@MainActor func spokenResponsePolicy() {
    let engine = RecordingSpeechEngine()
    let controller = SpokenResponseController(engine: engine, voiceIdentifier: "com.example.voice", localeIdentifier: "en-US")

    controller.speakQuestion("Which app should I open?")
    controller.speakMilestone("Scrolled one page", meaningful: false)
    controller.speakMilestone("Opened the selected app", meaningful: true)
    controller.speakCompletion("Brave is open")

    #expect(engine.requests.map(\.text) == ["Please clarify your request.", "I am continuing the task.", "The selected app is open."])
    #expect(engine.requests.allSatisfy { $0.voiceIdentifier == "com.example.voice" && $0.localeIdentifier == "en-US" })
}

@Test("mute, replay, and stop preserve the last response without speaking while muted")
@MainActor func spokenResponseMuteReplayAndStop() {
    let engine = RecordingSpeechEngine()
    let controller = SpokenResponseController(engine: engine)

    controller.speakCompletion("Task complete")
    controller.isMuted = true
    controller.speakFailure("Task failed")
    #expect(engine.requests.map(\.text) == ["The task is complete."])
    #expect(controller.lastResponse == "The task could not be completed.")

    controller.isMuted = false
    controller.replayLastResponse()
    controller.stop()
    #expect(engine.requests.map(\.text) == ["The task is complete.", "The task is complete."])
    #expect(engine.stopCount == 1)
}

@Test("spoken responses redact passwords and one-time codes")
@MainActor func spokenResponseRedactsSensitiveValues() {
    let engine = RecordingSpeechEngine()
    let controller = SpokenResponseController(engine: engine)

    controller.speakFailure("Password=secret-value; one-time code is 123456")

    #expect(engine.requests.count == 1)
    #expect(!engine.requests[0].text.contains("secret-value"))
    #expect(!engine.requests[0].text.contains("123456"))
    #expect(engine.requests[0].text == "The task could not be completed.")
}

@Test("provider wording is never spoken verbatim")
@MainActor func spokenResponseUsesBoundedTemplates() {
    let engine = RecordingSpeechEngine()
    let controller = SpokenResponseController(engine: engine)

    controller.speakQuestion("The account password=secret and private message are needed; which app?")

    #expect(engine.requests.count == 1)
    #expect(engine.requests[0].text == "Please clarify your request.")
    #expect(!engine.requests[0].text.contains("secret"))
}
