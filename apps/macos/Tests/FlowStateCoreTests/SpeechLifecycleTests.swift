import Testing
@testable import FlowStateCore

@Test func releaseFinishesRecognitionWithoutDroppingFinalCommand() async {
    let session = SpeechSessionCoordinator()
    await session.pushToTalkDown()
    await session.pushToTalkUp()
    #expect(await session.consume(transcript: "scroll down", isFinal: true) == .scroll(-3))
    #expect(await session.phase == .idle)
    #expect(await session.consume(transcript: "scroll down", isFinal: true) == nil)
}
@Test func partialStopIsImmediateAndCannotBeSuppressedByFinalResult() async {
    let session = SpeechSessionCoordinator()
    await session.pushToTalkDown()
    #expect(await session.consume(transcript: "stop", isFinal: false) == .stop)
    #expect(await session.phase == .idle)
    #expect(await session.consume(transcript: "scroll down", isFinal: true) == nil)
}
@Test func explicitCancelDiscardsPendingFinalDictation() async {
    let session = SpeechSessionCoordinator(purpose: .dictation)
    await session.pushToTalkDown(purpose: .dictation)
    await session.pushToTalkUp(purpose: .dictation)
    await session.localStop()
    #expect(await session.consumeResult(transcript: "停止", isFinal: true) == nil)
}

@Test func streamingRevisionsReplacePartialTextAndKeepFinalSegments() {
    var transcript = StreamingTranscript()
    #expect(transcript.update("Scroll", isFinal:false) == "Scroll")
    #expect(transcript.update("Scroll down", isFinal:false) == "Scroll down")
    #expect(transcript.update("Scroll down.", isFinal:true) == "Scroll down.")
    #expect(transcript.update("停止", isFinal:false) == "Scroll down. 停止")
    #expect(transcript.update("停止。", isFinal:true) == "Scroll down. 停止。")
}

@Test @MainActor func finishInvalidatesSuspendedSpeechPreparation() {
    let capture = AnalyzerSpeechCapture()
    capture.starting = true // State while start awaits SpeechAnalyzer preparation.
    let generation = capture.generation
    capture.finish()
    #expect(capture.generation != generation)
    #expect(!capture.starting)
}

@Test("hold sessions carry their explicit purpose through final results")
func holdSessionCarriesPurpose() async {
    let dictation = SpeechSessionCoordinator(purpose: .dictation)
    await dictation.pushToTalkDown()
    await dictation.pushToTalkUp()
    let result = await dictation.consumeResult(transcript: "open Brave", isFinal: true)
    #expect(result?.purpose == .dictation)
    #expect(result?.transcript == "open Brave")

    let control = SpeechSessionCoordinator(purpose: .control)
    await control.pushToTalkDown()
    await control.pushToTalkUp()
    #expect(await control.consumeResult(transcript: "open Brave", isFinal: true)?.purpose == .control)
}

@Test("a repeat key-down cannot start another purpose while a hold is active")
func holdPurposeCannotOverlap() async {
    let session = SpeechSessionCoordinator(purpose: .control)
    let first = await session.pushToTalkDown()
    let second = await session.pushToTalkDown(purpose: .dictation)
    #expect(first == second)
    #expect(await session.purpose == .control)
}
