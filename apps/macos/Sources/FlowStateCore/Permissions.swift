@preconcurrency import AVFoundation
@preconcurrency import Speech
@preconcurrency import ApplicationServices
import CoreGraphics
import Foundation

public enum MacPermission: String, CaseIterable, Codable, Sendable {
    case microphone
    case speechRecognition
    case accessibility
    case screenRecording

    public var displayName: String {
        switch self {
        case .microphone: "Microphone"
        case .speechRecognition: "Speech recognition"
        case .accessibility: "Accessibility"
        case .screenRecording: "Screen recording"
        }
    }
}

public enum MacPermissionStatus: String, Codable, Equatable, Sendable {
    case authorized
    case denied
    case restricted
    case notDetermined
    case unavailable

    public var isGranted: Bool { self == .authorized }
}

public struct MacPermissionSnapshot: Codable, Equatable, Sendable {
    public let microphone: MacPermissionStatus
    public let speechRecognition: MacPermissionStatus
    public let accessibility: MacPermissionStatus
    public let screenRecording: MacPermissionStatus

    public init(
        microphone: MacPermissionStatus,
        speechRecognition: MacPermissionStatus,
        accessibility: MacPermissionStatus,
        screenRecording: MacPermissionStatus
    ) {
        self.microphone = microphone
        self.speechRecognition = speechRecognition
        self.accessibility = accessibility
        self.screenRecording = screenRecording
    }

    public subscript(permission: MacPermission) -> MacPermissionStatus {
        switch permission {
        case .microphone: microphone
        case .speechRecognition: speechRecognition
        case .accessibility: accessibility
        case .screenRecording: screenRecording
        }
    }
}

public enum MacPermissionManager {
    public static func snapshot() -> MacPermissionSnapshot {
        MacPermissionSnapshot(
            microphone: microphoneStatus(),
            speechRecognition: speechStatus(),
            accessibility: AXIsProcessTrusted() ? .authorized : .denied,
            screenRecording: CGPreflightScreenCaptureAccess() ? .authorized : .denied
        )
    }

    public static func microphoneStatus() -> MacPermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .authorized
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .unavailable
        }
    }

    public static func speechStatus() -> MacPermissionStatus {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: .authorized
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .unavailable
        }
    }

    public static func requestMicrophone() async -> MacPermissionStatus {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        return granted ? .authorized : microphoneStatus()
    }

    public static func requestSpeechRecognition() async -> MacPermissionStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                let mapped: MacPermissionStatus
                switch status {
                case .authorized: mapped = .authorized
                case .denied: mapped = .denied
                case .restricted: mapped = .restricted
                case .notDetermined: mapped = .notDetermined
                @unknown default: mapped = .unavailable
                }
                continuation.resume(returning: mapped)
            }
        }
    }

    public static func requestScreenRecording() -> MacPermissionStatus {
        _ = CGRequestScreenCaptureAccess()
        return snapshot().screenRecording
    }

    public static func accessibilityStatus(prompt: Bool = false) -> MacPermissionStatus {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt]
        return AXIsProcessTrustedWithOptions(options as CFDictionary) ? .authorized : .denied
    }
}
