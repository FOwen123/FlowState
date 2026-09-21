@preconcurrency import AppKit
import CoreGraphics
import Foundation

public enum DictationTargetValidationError: String, Error, Codable, Equatable, LocalizedError, Sendable {
    case missingTarget
    case notEditable
    case secureField
    case appChanged
    case focusedElementChanged
    case selectionChanged

    public var errorDescription: String? {
        switch self {
        case .missingTarget: "Select an editable text field before dictating."
        case .notEditable: "The focused control is not editable."
        case .secureField: "Secure text fields are not controlled by FlowState."
        case .appChanged: "The focused application changed before dictation finished."
        case .focusedElementChanged: "The focused text field changed before dictation finished."
        case .selectionChanged: "The text selection changed before dictation finished."
        }
    }
}

public enum DictationOutputError: Error, Equatable, LocalizedError, Sendable {
    case emptyTranscript
    case target(DictationTargetValidationError)
    case pasteUnavailable
    case pasteNotVerified
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .emptyTranscript: "No speech was detected."
        case let .target(error): error.localizedDescription
        case .pasteUnavailable: "The text could not be pasted into the original field."
        case .pasteNotVerified: "The text was not verified in the original field. Copy it from Dictation history."
        case .cancelled: "Dictation was cancelled before insertion."
        }
    }
}

public struct DictationTarget: Codable, Equatable, Sendable {
    public let observation: DesktopObservation
    public let clipboardChangeCount: Int
    /// A selected range is preferred; the retained focused-element identity is
    /// the stable substitute when Accessibility does not expose a range.
    public let selectionIdentity: String?

    public init(observation: DesktopObservation, clipboardChangeCount: Int = 0) {
        self.observation = observation
        self.clipboardChangeCount = clipboardChangeCount
        if let range = observation.selectedTextRange {
            selectionIdentity = "range:\(range.location):\(range.length)"
        } else if let focusedElementID = observation.focusedElementID {
            selectionIdentity = "element:\(focusedElementID)"
        } else {
            selectionIdentity = nil
        }
    }

    public var validationError: DictationTargetValidationError? {
        guard observation.focusedElementID != nil else { return .missingTarget }
        guard observation.isEditable else { return .notEditable }
        guard !observation.isSecure else { return .secureField }
        guard selectionIdentity != nil else { return .selectionChanged }
        return nil
    }

    /// The original application, Accessibility element and selected range are
    /// the insertion boundary. The value is deliberately excluded because it
    /// changes as soon as the paste succeeds.
    public func matches(_ current: DesktopObservation) -> Bool {
        let currentSelectionIdentity: String? = if let range = current.selectedTextRange {
            "range:\(range.location):\(range.length)"
        } else if let focusedElementID = current.focusedElementID {
            "element:\(focusedElementID)"
        } else {
            nil
        }
        return observation.bundleIdentifier == current.bundleIdentifier &&
            observation.focusedElementID == current.focusedElementID &&
            observation.focusedRole == current.focusedRole &&
            observation.isEditable == current.isEditable &&
            observation.isSecure == current.isSecure &&
            selectionIdentity != nil && selectionIdentity == currentSelectionIdentity
    }

    public func mismatch(for current: DesktopObservation) -> DictationTargetValidationError {
        guard observation.bundleIdentifier == current.bundleIdentifier else { return .appChanged }
        guard observation.focusedElementID == current.focusedElementID,
              observation.focusedRole == current.focusedRole else { return .focusedElementChanged }
        return .selectionChanged
    }
}

public protocol DictationTargetObserver: Sendable {
    func observe() async throws -> DesktopObservation
}

extension AXDesktopDriver: DictationTargetObserver {}

public enum DictationTextCleaner {
    private static let fillers = ["um", "uh", "erm", "hmm", "you know"]
    private static let spokenPunctuation: [(String, String)] = [
        ("new paragraph", "\n\n"), ("new line", "\n"),
        ("question mark", "?"), ("exclamation mark", "!"),
        ("full stop", "."), ("period", "."), ("comma", ","),
        ("semicolon", ";"), ("colon", ":")
    ]

    /// Conservative local cleanup. It only removes standalone fillers and
    /// converts unambiguous spoken punctuation; it never interprets commands.
    public static func clean(_ transcript: String, vocabulary: [String: String] = [:]) -> String {
        var text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return text }
        for filler in fillers {
            let pattern = "(?i)(?<![\\p{L}\\p{N}_])" + NSRegularExpression.escapedPattern(for: filler) + "(?![\\p{L}\\p{N}_])"
            if let expression = try? NSRegularExpression(pattern: pattern) {
                text = expression.stringByReplacingMatches(
                    in: text,
                    range: NSRange(location: 0, length: (text as NSString).length),
                    withTemplate: ""
                )
            }
        }
        for (spoken, punctuation) in spokenPunctuation {
            let pattern = "(?i)(?<![\\p{L}\\p{N}_])" + NSRegularExpression.escapedPattern(for: spoken) + "(?![\\p{L}\\p{N}_])"
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            text = expression.stringByReplacingMatches(
                in: text,
                range: NSRange(location: 0, length: (text as NSString).length),
                withTemplate: punctuation
            )
        }
        for (source, replacement) in vocabulary where !source.isEmpty {
            let pattern = "(?i)(?<![\\p{L}\\p{N}_])" + NSRegularExpression.escapedPattern(for: source) + "(?![\\p{L}\\p{N}_])"
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            text = expression.stringByReplacingMatches(
                in: text,
                range: NSRange(location: 0, length: (text as NSString).length),
                withTemplate: NSRegularExpression.escapedTemplate(for: replacement)
            )
        }
        text = text
            .replacingOccurrences(of: "[ \t]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: " *([,.;:?!])", with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "\\n[ \\t]+", with: "\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text
    }
}

public struct DictationClipboardTransaction: Sendable, Equatable {
    public let identifier: String
    public let changeCount: Int

    public init(identifier: String, changeCount: Int) {
        self.identifier = identifier
        self.changeCount = changeCount
    }

    public static func shouldRestore(
        currentChangeCount: Int,
        flowStateChangeCount: Int,
        markerPresent: Bool
    ) -> Bool {
        currentChangeCount == flowStateChangeCount && markerPresent
    }
}

public struct DictationOutputResult: Equatable, Sendable {
    public let text: String
    public let verified: Bool

    public init(text: String, verified: Bool) {
        self.text = text
        self.verified = verified
    }
}

public struct DictationCleanupSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var instructions: String

    public init(enabled: Bool = true, instructions: String = "") {
        self.enabled = enabled
        self.instructions = String(instructions.prefix(1_000))
    }
}

/// Optional managed cleanup is an untrusted text transform. It cannot choose
/// a target, authorize an action, or call the desktop executor.
public protocol ManagedDictationCleanupClient: Sendable {
    func clean(transcript: String, instructions: String, vocabulary: [String: String]) async throws -> String
}

/// Inserts final dictation with a private pasteboard item. The caller owns
/// target capture and can show its recovery UI when this throws.
@MainActor
public final class DictationOutputController {
    private let observer: any DictationTargetObserver
    private let pasteboard: NSPasteboard
    private let pollInterval: Duration
    private let pollAttempts: Int

    public init(
        observer: any DictationTargetObserver = AXDesktopDriver(),
        pasteboard: NSPasteboard = .general,
        pollInterval: Duration = .milliseconds(30),
        pollAttempts: Int = 20
    ) {
        self.observer = observer
        self.pasteboard = pasteboard
        self.pollInterval = pollInterval
        self.pollAttempts = max(1, pollAttempts)
    }

    public func insert(
        transcript: String,
        into target: DictationTarget,
        cleanup: Bool = true,
        vocabulary: [String: String] = [:],
        cleanupSettings: DictationCleanupSettings? = nil,
        managedCleanupClient: (any ManagedDictationCleanupClient)? = nil,
        cleanupTimeout: Duration = .seconds(1),
        isInsertionCurrent: @escaping @MainActor () -> Bool = { true }
    ) async throws -> DictationOutputResult {
        guard target.validationError == nil else { throw DictationOutputError.target(target.validationError!) }
        let configuration = cleanupSettings ?? DictationCleanupSettings(enabled: cleanup)
        let localText = configuration.enabled
            ? DictationTextCleaner.clean(transcript, vocabulary: vocabulary)
            : transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let text: String
        if configuration.enabled, let managedCleanupClient,
           let managedText = try? await Self.managedCleanup(
               client: managedCleanupClient,
               transcript: localText,
               instructions: configuration.instructions,
               vocabulary: vocabulary,
               timeout: cleanupTimeout
           ) {
            text = managedText
        } else {
            text = localText
        }
        guard !text.isEmpty else { throw DictationOutputError.emptyTranscript }
        guard !Task.isCancelled, isInsertionCurrent() else { throw DictationOutputError.cancelled }

        let current = try await observer.observe()
        guard !Task.isCancelled, isInsertionCurrent() else { throw DictationOutputError.cancelled }
        guard target.matches(current) else { throw DictationOutputError.target(target.mismatch(for: current)) }

        let snapshot = PasteboardSnapshot(pasteboard: pasteboard)
        let identifier = UUID().uuidString
        let markerType = NSPasteboard.PasteboardType("com.flowstate.dictation.\(identifier)")
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setString(identifier, forType: markerType)
        guard !Task.isCancelled, isInsertionCurrent() else { throw DictationOutputError.cancelled }
        var mutationChangeCount: Int?
        var flowStateChangeCount: Int?

        defer {
            if let mutationChangeCount {
                let markerPresent = pasteboard.pasteboardItems?.first?.string(forType: markerType) == identifier
                let ownsMutation = if let flowStateChangeCount {
                    DictationClipboardTransaction.shouldRestore(
                        currentChangeCount: pasteboard.changeCount,
                        flowStateChangeCount: flowStateChangeCount,
                        markerPresent: markerPresent
                    )
                } else {
                    // A failed write may leave only the clearContents mutation.
                    // Restore it unless the user changed the clipboard meanwhile.
                    pasteboard.changeCount == mutationChangeCount
                }
                if ownsMutation {
                    snapshot.restore(to: pasteboard)
                }
            }
        }

        mutationChangeCount = pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else { throw DictationOutputError.pasteUnavailable }
        flowStateChangeCount = pasteboard.changeCount

        let beforePaste = try await observer.observe()
        guard !Task.isCancelled, isInsertionCurrent() else { throw DictationOutputError.cancelled }
        guard target.matches(beforePaste) else { throw DictationOutputError.target(target.mismatch(for: beforePaste)) }
        guard let application = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == target.observation.bundleIdentifier }),
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier == target.observation.bundleIdentifier else {
            throw DictationOutputError.target(.appChanged)
        }
        // This is the final cancellation/generation boundary before posting
        // Cmd-V. X or a newer dictation can still restore the transaction,
        // but can never deliver FlowState text to the target field.
        guard !Task.isCancelled, isInsertionCurrent() else { throw DictationOutputError.cancelled }
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            throw DictationOutputError.pasteUnavailable
        }
        AXDesktopDriver.tagAutomationEvent(keyDown)
        AXDesktopDriver.tagAutomationEvent(keyUp)
        keyDown.flags = [.maskCommand]
        keyUp.flags = [.maskCommand]
        keyDown.postToPid(application.processIdentifier)
        keyUp.postToPid(application.processIdentifier)

        for _ in 0..<pollAttempts {
            try await Task.sleep(for: pollInterval)
            guard !Task.isCancelled, isInsertionCurrent() else { throw DictationOutputError.cancelled }
            let after = try await observer.observe()
            guard after.bundleIdentifier == target.observation.bundleIdentifier,
                  after.focusedElementID == target.observation.focusedElementID,
                  !after.isSecure else { throw DictationOutputError.target(.focusedElementChanged) }
            if let beforeValue = beforePaste.value,
               let afterValue = after.value,
               afterValue != beforeValue {
                return DictationOutputResult(text: text, verified: true)
            }
        }
        throw DictationOutputError.pasteNotVerified
    }

    private static func managedCleanup(
        client: any ManagedDictationCleanupClient,
        transcript: String,
        instructions: String,
        vocabulary: [String: String],
        timeout: Duration
    ) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                let value = try await client.clean(
                    transcript: transcript,
                    instructions: instructions,
                    vocabulary: vocabulary
                )
                return String(value.prefix(8_000)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw DictationOutputError.cancelled
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}

private struct PasteboardSnapshot: Sendable {
    private struct Representation: Sendable {
        let type: NSPasteboard.PasteboardType
        let data: Data
    }

    private let items: [[Representation]]

    @MainActor
    init(pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in
                guard let data = item.data(forType: type) else { return nil }
                return Representation(type: type, data: data)
            }
        }
    }

    @MainActor
    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let restored = items.map { representations -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for representation in representations { item.setData(representation.data, forType: representation.type) }
            return item
        }
        if !restored.isEmpty { pasteboard.writeObjects(restored) }
    }
}
