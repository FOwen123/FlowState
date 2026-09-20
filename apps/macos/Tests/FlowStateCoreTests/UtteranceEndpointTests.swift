import Foundation
import Testing
@testable import FlowStateCore

@Test("endpoint detector emits once after stable transcript and fake silence")
func endpointDetectorUsesStableTranscriptAndFakeClock() {
    var detector = UtteranceEndpointDetector(silenceDuration: 0.75)
    let start = Date(timeIntervalSince1970: 10)

    detector.updateTranscript("Open Brave", isFinal: true, at: start)
    detector.updateSpeechActivity(true, at: start.addingTimeInterval(0.1))
    #expect(detector.poll(at: start.addingTimeInterval(0.7)) == nil)
    detector.updateSpeechActivity(false, at: start.addingTimeInterval(0.8))
    #expect(detector.poll(at: start.addingTimeInterval(1.4)) == nil)
    let endpoint = detector.poll(at: start.addingTimeInterval(1.56))
    #expect(endpoint?.transcript == "Open Brave")
    #expect(endpoint?.sessionEnded == false)
    #expect(detector.poll(at: start.addingTimeInterval(3)) == nil)
}

@Test("endpoint detector keeps revisions in one utterance and separates the next")
func endpointDetectorDeduplicatesRevisions() {
    var detector = UtteranceEndpointDetector(silenceDuration: 0.6)
    let start = Date(timeIntervalSince1970: 20)
    detector.updateTranscript("Open", at: start)
    detector.updateTranscript("Open Brave", isFinal: true, at: start.addingTimeInterval(0.2))
    detector.updateSpeechActivity(false, at: start.addingTimeInterval(0.3))

    let first = detector.poll(at: start.addingTimeInterval(0.91))
    #expect(first?.utteranceID != nil)
    #expect(first?.transcript == "Open Brave")
    #expect(detector.finish(at: start.addingTimeInterval(1)) == nil)

    detector.updateSpeechActivity(true, at: start.addingTimeInterval(1.05))
    detector.updateTranscript("Scroll down", at: start.addingTimeInterval(1.1))
    let second = detector.finish(at: start.addingTimeInterval(1.2))
    #expect(second?.utteranceID != first?.utteranceID)
    #expect(second?.transcript == "Scroll down")
    #expect(second?.sessionEnded == true)
}

@Test("endpoint detector finish is idempotent and reset invalidates pending text")
func endpointDetectorFinishAndResetAreSafe() {
    var detector = UtteranceEndpointDetector()
    let now = Date(timeIntervalSince1970: 30)
    detector.updateTranscript("type delete", at: now)
    let first = detector.finish(at: now)
    #expect(first?.transcript == "type delete")
    #expect(detector.finish(at: now.addingTimeInterval(1)) == nil)

    detector.updateTranscript("stale", at: now.addingTimeInterval(2))
    detector.reset()
    #expect(detector.finish(at: now.addingTimeInterval(3)) == nil)
}

@Test("endpoint detector suppresses late ASR revisions until new speech starts")
func endpointDetectorSuppressesPostEndpointRevisions() {
    var detector = UtteranceEndpointDetector(silenceDuration: 0.5)
    let start = Date(timeIntervalSince1970: 40)

    detector.updateSpeechActivity(true, at: start)
    detector.updateTranscript("Open Brave", isFinal: true, at: start.addingTimeInterval(0.1))
    detector.updateSpeechActivity(false, at: start.addingTimeInterval(0.2))
    let first = detector.poll(at: start.addingTimeInterval(0.8))
    #expect(first?.transcript == "Open Brave")

    // SpeechAnalyzer can deliver a final punctuation/revision for the same
    // audio after the automatic endpoint. It must not become a second command.
    detector.updateTranscript("Open Brave.", isFinal: true, at: start.addingTimeInterval(0.9))
    detector.updateSpeechActivity(false, at: start.addingTimeInterval(0.9))
    #expect(detector.poll(at: start.addingTimeInterval(1.6)) == nil)

    detector.updateSpeechActivity(true, at: start.addingTimeInterval(1.7))
    detector.updateTranscript("Scroll down", at: start.addingTimeInterval(1.8))
    detector.updateSpeechActivity(false, at: start.addingTimeInterval(1.9))
    #expect(detector.finish(at: start.addingTimeInterval(2.0))?.transcript == "Scroll down")
}

@Test("stable but unfinished recognition cannot trigger an automatic action")
func unfinishedRecognitionNeverAutoExecutes() {
    var detector = UtteranceEndpointDetector(silenceDuration: 0.5)
    let start = Date(timeIntervalSince1970: 100)
    detector.updateSpeechActivity(true, at: start)
    detector.updateTranscript("Open Brave", isFinal: false, at: start)
    detector.updateSpeechActivity(false, at: start.addingTimeInterval(0.1))
    #expect(detector.poll(at: start.addingTimeInterval(1)) == nil)
    detector.updateTranscript("Open Brave is what I want you to type", isFinal: true, at: start.addingTimeInterval(1.1))
    #expect(detector.poll(at: start.addingTimeInterval(1.7))?.transcript == "Open Brave is what I want you to type")
}

@Test("late results for committed audio cannot repeat after new speech starts")
func committedAudioRangesCannotReplay() {
    var gate = SpeechResultRangeGate()
    let samples: [(Double, Bool, Bool)] = [(1, false, true), (1, true, true), (1, true, false),
        (0.9, false, false), (2, false, true), (1, true, false), (2, true, true), (.nan, true, false)]
    for (end, final, expected) in samples {
        let accepted = gate.accepts(end: end, isFinal: final)
        #expect(accepted == expected)
    }
}
