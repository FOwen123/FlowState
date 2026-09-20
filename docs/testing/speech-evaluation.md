# Speech evaluation — September 20, 2026

Computer: Apple M5 Pro, 15 CPU cores, 24 GB unified memory; macOS 26.6.2; Xcode 27 / Swift 6.4. These are development measurements, not release thresholds.

Legacy SFSpeechRecognizer reported on-device English available but zh-TW unavailable on this host. The app now uses macOS 26 SpeechAnalyzer/SpeechTranscriber. The English asset was installed; the Traditional Chinese asset was installed through Apple's AssetInventory API during this session. The package minimum is macOS 26.2 because of the selected native dependency runtime.

Synthetic audio was generated with the system Samantha and Meijia voices and transcribed using `scripts/speech-probe.swift`. No private microphone recordings were used.

| Locale | Spoken fixture | Returned text | Analyzer elapsed | CLI process peak RSS |
|---|---|---|---|---|
| en-US | Scroll down. Open Brave. Stop. | Scroll down. Open Brave, stop. | 0.182 s | 197,607,424 bytes |
| zh-TW | 往下捲動。打開瀏覽器。停止。 | 往下捲動打開瀏覽器停止。 | 0.173 s | 197,476,352 bytes |

These short file probes establish model availability and successful local file transcription. They do not establish microphone accuracy, mixed-language quality, wake/stop latency, or total model RAM: Apple's speech service runs outside the measured CLI process. Model download size was not measured. Punctuation differs from the synthetic input, so accuracy is not claimed.

Unit tests cover command/dictation separation, release/final-result handling, partial local stop, cancellation during preparation, and streaming transcript replacement. Live microphone changes, silence, noise, long recordings, repeated activation, offline execution and physical takeover still need manual tests. A competing local multilingual model has not yet been benchmarked.

Apple explicitly distinguishes SpeechAnalyzer from the legacy server-recognition permission flow. Only microphone access is required for this app’s capture path; the legacy speech-permission row is hidden. [Apple permission documentation](https://developer.apple.com/documentation/speech/asking-permission-to-use-speech-recognition).
