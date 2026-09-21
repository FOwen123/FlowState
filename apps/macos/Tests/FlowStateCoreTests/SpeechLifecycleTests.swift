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
    let session = SpeechSessionCoordinator(settings: SpeechSettings(mode: .dictation))
    await session.pushToTalkDown()
    await session.pushToTalkUp()
    await session.localStop()
    #expect(await session.consume(transcript: "停止", isFinal: true) == nil)
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

@Test func wakePhraseAcceptsRecognizerPunctuationButNotOtherSpeech() async {
    let session = SpeechSessionCoordinator(settings: SpeechSettings(activation: .wakePhrase))
    #expect(await session.detectWakePhrase("Do not say Hey Flow State") == false)
    #expect(await session.detectWakePhrase("Hey Flow State.") == true)
    await session.localStop()
    await session.update(settings: SpeechSettings(activation: .wakePhrase, wakePhrase: "嘿，Flow State"))
    #expect(await session.detectWakePhrase("嘿，Flow State。") == true)
}

@Test("the second toggle press finishes once and preserves the final command")
func toggleShortcutFinishesFinalCommand() async {
    let session = SpeechSessionCoordinator(settings: SpeechSettings(activation: .toggle))
    await session.toggle()
    #expect(await session.phase == .listening)
    await session.toggle()
    #expect(await session.phase == .stopping)
    #expect(await session.consume(transcript: "scroll down", isFinal: true) == .scroll(-3))
    #expect(await session.phase == .idle)
    #expect(await session.consume(transcript: "scroll down", isFinal: true) == nil)
}

@Test("capture finishing enters stopping for every activation mode", arguments: ActivationMode.allCases)
func captureFinishUsesCurrentSession(mode: ActivationMode) async {
    let session = SpeechSessionCoordinator(settings: SpeechSettings(activation: mode))
    switch mode {
    case .pushToTalk: await session.pushToTalkDown()
    case .toggle: await session.toggle()
    case .wakePhrase: _ = await session.detectWakePhrase("Hey Flow State")
    }
    await session.finish()
    #expect(await session.phase == .stopping)
    await session.finish()
    #expect(await session.phase == .stopping)
    #expect(await session.consume(transcript: "scroll down", isFinal: true) == .scroll(-3))
    #expect(await session.phase == .idle)
}

@Test("a third toggle press cannot restart speech while the final result is pending")
func toggleWaitsForFinalResult() async {
    let session = SpeechSessionCoordinator(settings: SpeechSettings(activation: .toggle))
    let generation = await session.toggle()
    await session.finish()
    #expect(await session.toggle() == generation)
    #expect(await session.phase == .stopping)
    #expect(await session.consume(transcript: "scroll down", isFinal: true) == .scroll(-3))
    #expect(await session.toggle() > generation)
    #expect(await session.phase == .listening)
}
