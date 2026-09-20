import Speech
import AVFoundation
import Foundation
guard CommandLine.arguments.count == 3 else {
    print("Usage: swift scripts/speech-probe.swift <locale> <audio-file>")
    exit(2)
}
let language = CommandLine.arguments[1]
guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo:Locale(identifier:language)) else {
    print("Speech locale is unavailable")
    exit(1)
}
let transcriber = SpeechTranscriber(locale:locale,preset:.transcription)
let analyzer = SpeechAnalyzer(modules:[transcriber])
let audio = try AVAudioFile(forReading:URL(fileURLWithPath:CommandLine.arguments[2]))
let start = Date()
let results = Task { () throws -> String in
    var text = ""
    for try await result in transcriber.results { text += String(result.text.characters) }
    return text
}
try await analyzer.start(inputAudioFile:audio,finishAfterFile:true)
let text = try await results.value
print("\(language): \(text)")
print("elapsed_seconds=\(Date().timeIntervalSince(start))")
