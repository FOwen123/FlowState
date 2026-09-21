@preconcurrency import AVFoundation
@preconcurrency import Speech
import Foundation

/// Final segments are stable; volatile hypotheses replace one another.
struct StreamingTranscript {
    private var finalized: [String] = []
    private var partial = ""
    var text: String { (finalized + [partial]).filter { !$0.isEmpty }.joined(separator: " ") }
    mutating func update(_ text: String, isFinal: Bool) -> String {
        if isFinal { finalized.append(text); partial = "" } else { partial = text }
        return self.text
    }
    mutating func reset() {
        finalized.removeAll(keepingCapacity: true)
        partial = ""
    }
}

/// Finalized audio cannot become a new command even if its result arrives late,
/// after the microphone has detected the next utterance.
struct SpeechResultRangeGate {
    private var finalizedEnd: TimeInterval = -.infinity
    mutating func accepts(end: TimeInterval, isFinal: Bool) -> Bool {
        guard end.isFinite, end > finalizedEnd else { return false }
        if isFinal { finalizedEnd = end }
        return true
    }
}

/// English speech runs on-device. There is no audio upload path.
@MainActor
public final class AnalyzerSpeechCapture {
    private var engine: AVAudioEngine?
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var endpointPollTask: Task<Void, Never>?
    private var streamingTranscript = StreamingTranscript()
    private var resultRangeGate = SpeechResultRangeGate()
    private var endpointDetector: UtteranceEndpointDetector
    private(set) var generation: UInt64 = 0
    var starting = false
    private var failure: (@MainActor () -> Void)?
    private let endpointPollInterval: UInt64 = 100_000_000
    private let speechActivityThreshold: Float = 0.01

    public init(endpointSilenceDuration: TimeInterval = 0.75) {
        endpointDetector = UtteranceEndpointDetector(silenceDuration: endpointSilenceDuration)
    }

    public static func installLanguage(_ language: SpeechLanguage) async throws {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: language.locale) else { throw SpeechCaptureError.unavailable }
        let module = SpeechTranscriber(locale:locale,preset:.progressiveTranscription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting:[module]) { try await request.downloadAndInstall() }
    }

    public func start(language: SpeechLanguage,
                      purpose: SpeechSessionPurpose = .control,
                      onResult: @escaping @MainActor (SpeechRecognitionResult) -> Void,
                      onFailure: @escaping @MainActor () -> Void) async throws {
        guard analyzer == nil, !starting else { throw SpeechCaptureError.alreadyRunning }
        guard AVCaptureDevice.authorizationStatus(for:.audio) == .authorized else { throw SpeechCaptureError.microphonePermissionDenied }
        generation &+= 1
        let token = generation
        starting = true
        defer { if token == generation { starting = false } }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo:SpeechLanguage.english.locale) else { throw SpeechCaptureError.unavailable }
        let transcriber = SpeechTranscriber(locale:locale,preset:.progressiveTranscription)
        guard await AssetInventory.status(forModules:[transcriber]) == .installed else { throw SpeechCaptureError.modelNotInstalled }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:[transcriber]) else { throw SpeechCaptureError.unavailable }
        let session = SpeechAnalyzer(modules:[transcriber])
        try await session.prepareToAnalyze(in:format)
        guard generation == token else { await session.cancelAndFinishNow(); throw CancellationError() }
        let audioEngine = AVAudioEngine()
        let natural = audioEngine.inputNode.inputFormat(forBus:0)
        guard natural.sampleRate > 0, natural.channelCount > 0,
              let converter = PCMInputConverter(from:natural,to:format) else { throw SpeechCaptureError.noInputDevice }
        let stream = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy:.bufferingOldest(128))
        self.failure = onFailure
        streamingTranscript.reset()
        endpointDetector.reset()
        resultRangeGate = SpeechResultRangeGate()
        self.analyzer = session
        self.input = stream.continuation
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self, self.generation == token else { return }
                    guard self.resultRangeGate.accepts(end: result.range.end.seconds, isFinal: result.isFinal) else { continue }
                    let text = self.streamingTranscript.update(String(result.text.characters),isFinal:result.isFinal)
                    guard self.endpointDetector.updateTranscript(text,isFinal:result.isFinal,at:Date()) else {
                        // A late final/revision can belong to audio already
                        // committed by the automatic endpoint. Do not surface
                        // it as a duplicate command.
                        self.streamingTranscript.reset()
                        continue
                    }
                    onResult(SpeechRecognitionResult(transcript:text,language:.english,isFinal:false,sessionEnded:false,purpose:purpose))
                }
                guard let self, self.generation == token else { return }
                let finalTime = Date()
                if let endpoint = self.endpointDetector.finish(at:finalTime) {
                    self.emit(endpoint,language:.english,purpose:purpose,onResult:onResult)
                } else {
                    // An automatic endpoint may already have emitted the last
                    // transcript. Still notify consumers that the analyzer
                    // session itself is over so they can return to idle.
                    onResult(SpeechRecognitionResult(
                        transcript:self.streamingTranscript.text,
                        language:.english,
                        isFinal:true,
                        utteranceID:UUID(),
                        sessionEnded:true,
                        purpose: purpose
                    ))
                }
                self.cleanup()
            } catch {
                guard let self, self.generation == token else { return }
                self.stop(); onFailure()
            }
        }
        let activityThreshold = speechActivityThreshold
        audioEngine.inputNode.installTap(onBus:0,bufferSize:1024,format:natural) { @Sendable [weak self] buffer,_ in
            let active = Self.isSpeechActive(buffer,threshold:activityThreshold)
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.endpointDetector.updateSpeechActivity(active,at:Date())
                    self.pollEndpoint(at:Date(),language:.english,purpose:purpose,onResult:onResult)
            }
            do {
                let converted = try converter.convert(buffer)
                guard converted.frameLength > 0 else { return }
                if case .dropped = stream.continuation.yield(AnalyzerInput(buffer:converted)) {
                    Task { @MainActor in guard let self, self.generation == token else { return }; self.stop(); onFailure() }
                }
            } catch {
                Task { @MainActor in guard let self, self.generation == token else { return }; self.stop(); onFailure() }
            }
        }
        do {
            try await session.start(inputSequence:stream.stream)
            guard generation == token else { throw CancellationError() }
            engine = audioEngine
            audioEngine.prepare()
            try audioEngine.start()
            startEndpointPoller(token:token,language:.english,purpose:purpose,onResult:onResult)
        } catch {
            audioEngine.inputNode.removeTap(onBus:0)
            if generation == token { stop() }
            throw error
        }
    }

    public func finish() {
        if starting { stop(); return }
        engine?.stop()
        engine?.inputNode.removeTap(onBus:0)
        engine = nil
        input?.finish()
        guard let analyzer else { return }
        let token = generation
        Task { [weak self] in
            do { try await analyzer.finalizeAndFinishThroughEndOfInput() }
            catch { if let self, self.generation == token { let failure = self.failure; self.stop(); failure?() } }
        }
    }
    public func stop() {
        generation &+= 1
        starting = false
        resultsTask?.cancel()
        let previous = analyzer
        cleanup()
        if let previous { Task { await previous.cancelAndFinishNow() } }
    }
    private func cleanup() {
        endpointPollTask?.cancel()
        endpointPollTask = nil
        engine?.stop()
        engine?.inputNode.removeTap(onBus:0)
        engine = nil
        input?.finish(); input = nil
        analyzer = nil
        failure = nil
        resultsTask = nil
    }

    private func startEndpointPoller(
        token: UInt64,
        language: SpeechLanguage,
        purpose: SpeechSessionPurpose,
        onResult: @escaping @MainActor (SpeechRecognitionResult) -> Void
    ) {
        endpointPollTask?.cancel()
        endpointPollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds:self?.endpointPollInterval ?? 100_000_000)
                guard let self, self.generation == token else { return }
                self.pollEndpoint(at:Date(),language:language,purpose:purpose,onResult:onResult)
            }
        }
    }

    private func pollEndpoint(
        at now: Date,
        language: SpeechLanguage,
        purpose: SpeechSessionPurpose,
        onResult: @escaping @MainActor (SpeechRecognitionResult) -> Void
    ) {
        guard let endpoint = endpointDetector.poll(at:now) else { return }
        emit(endpoint,language:language,purpose:purpose,onResult:onResult)
    }

    private func emit(
        _ endpoint: UtteranceEndpoint,
        language: SpeechLanguage,
        purpose: SpeechSessionPurpose,
        onResult: @escaping @MainActor (SpeechRecognitionResult) -> Void
    ) {
        streamingTranscript.reset()
        onResult(SpeechRecognitionResult(
            transcript:endpoint.transcript,
            language:language,
            isFinal:true,
            utteranceID:endpoint.utteranceID,
            sessionEnded:endpoint.sessionEnded,
            purpose: purpose
        ))
    }

    nonisolated private static func isSpeechActive(_ buffer: AVAudioPCMBuffer, threshold: Float) -> Bool {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return false }
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        var sum: Float = 0
        for channel in 0..<channelCount {
            let samples = channels[channel]
            for frame in 0..<frameCount {
                let sample = samples[frame]
                sum += sample * sample
            }
        }
        let rms = sqrt(sum / Float(max(1,frameCount * channelCount)))
        return rms >= threshold
    }
}

/// The audio tap owns conversion. Converted buffers have independent storage.
private final class PCMInputConverter: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let format: AVAudioFormat
    private let lock = NSLock()
    init?(from:AVAudioFormat,to:AVAudioFormat) {
        guard let converter = AVAudioConverter(from:from,to:to) else { return nil }
        self.converter = converter; format = to
    }
    func convert(_ input:AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        lock.lock(); defer { lock.unlock() }
        let count = AVAudioFrameCount(ceil(Double(input.frameLength) * format.sampleRate / input.format.sampleRate)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:count) else { throw SpeechCaptureError.noInputDevice }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to:output,error:&error) { _,status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true; status.pointee = .haveData; return input
        }
        guard status != .error, error == nil else { throw SpeechCaptureError.noInputDevice }
        return output
    }
}
