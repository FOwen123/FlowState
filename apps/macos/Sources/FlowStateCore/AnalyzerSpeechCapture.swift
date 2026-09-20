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
}

/// macOS 26 speech models run on-device, including zh-TW. No audio upload path.
@MainActor
public final class AnalyzerSpeechCapture {
    private var engine: AVAudioEngine?
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private(set) var generation: UInt64 = 0
    var starting = false
    private var failure: (@MainActor () -> Void)?
    public init() {}

    public static func installLanguage(_ language: SpeechLanguage) async throws {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: language.locale) else { throw SpeechCaptureError.unavailable }
        let module = SpeechTranscriber(locale:locale,preset:.progressiveTranscription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting:[module]) { try await request.downloadAndInstall() }
    }

    public func start(language: SpeechLanguage,
                      onResult: @escaping @MainActor (SpeechRecognitionResult) -> Void,
                      onFailure: @escaping @MainActor () -> Void) async throws {
        guard analyzer == nil, !starting else { throw SpeechCaptureError.alreadyRunning }
        guard AVCaptureDevice.authorizationStatus(for:.audio) == .authorized else { throw SpeechCaptureError.microphonePermissionDenied }
        generation &+= 1
        let token = generation
        starting = true
        defer { if token == generation { starting = false } }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo:language.locale) else { throw SpeechCaptureError.unavailable }
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
        self.analyzer = session
        self.input = stream.continuation
        resultsTask = Task { [weak self] in
            var transcript = StreamingTranscript()
            do {
                for try await result in transcriber.results {
                    guard let self, self.generation == token else { return }
                    let text = transcript.update(String(result.text.characters),isFinal:result.isFinal)
                    onResult(SpeechRecognitionResult(transcript:text,language:language,isFinal:false))
                }
                guard let self, self.generation == token else { return }
                self.cleanup()
                onResult(SpeechRecognitionResult(transcript:transcript.text,language:language,isFinal:true))
            } catch {
                guard let self, self.generation == token else { return }
                self.stop(); onFailure()
            }
        }
        audioEngine.inputNode.installTap(onBus:0,bufferSize:1024,format:natural) { @Sendable [weak self] buffer,_ in
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
        engine?.stop()
        engine?.inputNode.removeTap(onBus:0)
        engine = nil
        input?.finish(); input = nil
        analyzer = nil
        failure = nil
        resultsTask = nil
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
