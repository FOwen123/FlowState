import Foundation

public enum ControlConversationTurnRole: String, Codable, Sendable {
    case user
    case assistant
}

public struct ControlConversationTurn: Codable, Equatable, Sendable {
    public let role: ControlConversationTurnRole
    public let text: String

    public init(role: ControlConversationTurnRole, text: String) {
        self.role = role
        self.text = text
    }
}

public struct ControlConversationToken: Equatable, Sendable {
    public let taskID: UUID
    public let generation: UInt64

    public init(taskID: UUID, generation: UInt64) {
        self.taskID = taskID
        self.generation = generation
    }
}

/// Main-actor state for one bounded Mac Control conversation. A hold creates a
/// new reply generation while preserving the task ID until explicit reset.
@MainActor
public final class ControlConversationSession {
    public let maxTurns: Int
    public let inactivityTimeout: TimeInterval
    public private(set) var taskID: UUID?
    public private(set) var generation: UInt64 = 0
    public private(set) var turns: [ControlConversationTurn] = []
    public private(set) var originalRequest: String?
    public private(set) var pendingClarification: String?
    public private(set) var latestVerifiedResult: String?
    public private(set) var approvalGeneration: UInt64?
    public private(set) var lastActivityAt: Date?
    public private(set) var targetBundleIdentifier: String?
    public private(set) var grantExpiresAt: Date?

    public init(maxTurns: Int = 12, inactivityTimeout: TimeInterval = 15 * 60) {
        self.maxTurns = max(1, maxTurns)
        self.inactivityTimeout = max(1, inactivityTimeout)
    }

    @discardableResult
    public func beginTask(request: String? = nil) -> ControlConversationToken {
        if taskID == nil { taskID = UUID() }
        generation &+= 1
        if let request = cleaned(request) { originalRequest = request }
        touch()
        return currentToken
    }

    @discardableResult
    public func beginHold() -> ControlConversationToken {
        if !canBeginHold() { clear() }
        if taskID == nil { return beginTask() }
        generation &+= 1
        touch()
        return currentToken
    }

    /// Starts a hold only when the prior task is still active for the same
    /// target and grant. Expired or divergent state is cleared before the
    /// caller receives a new token.
    @discardableResult
    public func beginHoldIfCurrent(
        now: Date = Date(),
        targetBundleIdentifier: String? = nil,
        grantExpiresAt: Date? = nil
    ) -> ControlConversationToken? {
        guard canBeginHold(
            now: now,
            targetBundleIdentifier: targetBundleIdentifier,
            grantExpiresAt: grantExpiresAt
        ) else {
            clear()
            return nil
        }
        if taskID == nil { taskID = UUID() }
        if self.targetBundleIdentifier == nil, let targetBundleIdentifier {
            self.targetBundleIdentifier = targetBundleIdentifier
        }
        if self.grantExpiresAt == nil { self.grantExpiresAt = grantExpiresAt }
        generation &+= 1
        touch(now: now)
        return currentToken
    }

    public func bindExecution(targetBundleIdentifier: String, grantExpiresAt: Date, now: Date = Date()) {
        self.targetBundleIdentifier = targetBundleIdentifier
        self.grantExpiresAt = grantExpiresAt
        touch(now: now)
    }

    public func canBeginHold(
        now: Date = Date(),
        targetBundleIdentifier: String? = nil,
        grantExpiresAt: Date? = nil
    ) -> Bool {
        guard taskID != nil else { return true }
        if let lastActivityAt, now.timeIntervalSince(lastActivityAt) > inactivityTimeout { return false }
        if let grantExpiresAt = self.grantExpiresAt, grantExpiresAt <= now { return false }
        if let grantExpiresAt, grantExpiresAt <= now { return false }
        if let storedTarget = self.targetBundleIdentifier {
            guard let targetBundleIdentifier, storedTarget == targetBundleIdentifier else { return false }
        }
        if let storedExpiry = self.grantExpiresAt {
            guard let grantExpiresAt, storedExpiry == grantExpiresAt else { return false }
        }
        return true
    }

    public func touch(now: Date = Date()) {
        lastActivityAt = now
    }

    public func appendTurn(role: ControlConversationTurnRole, text: String) {
        guard let text = cleaned(text) else { return }
        turns.append(ControlConversationTurn(role: role, text: text))
        if turns.count > maxTurns { turns.removeFirst(turns.count - maxTurns) }
        touch()
    }

    /// Records the first user request without changing the reply generation.
    /// Follow-up holds keep the same request and task ID.
    public func recordOriginalRequest(_ text: String) {
        guard originalRequest == nil else { return }
        originalRequest = cleaned(text)
        touch()
    }

    public func setPendingClarification(_ text: String?) {
        pendingClarification = text.flatMap(cleaned)
        touch()
    }

    public func recordVerifiedResult(_ text: String?) {
        latestVerifiedResult = text.flatMap(cleaned)
        touch()
    }

    @discardableResult
    public func requireApproval() -> UInt64 {
        approvalGeneration = generation
        touch()
        return generation
    }

    public func accepts(_ token: ControlConversationToken) -> Bool {
        taskID == token.taskID && generation == token.generation
    }

    public func clear() {
        taskID = nil
        generation &+= 1
        turns.removeAll()
        originalRequest = nil
        pendingClarification = nil
        latestVerifiedResult = nil
        approvalGeneration = nil
        lastActivityAt = nil
        targetBundleIdentifier = nil
        grantExpiresAt = nil
    }

    @discardableResult
    public func newTask(request: String? = nil) -> ControlConversationToken {
        clear()
        return beginTask(request: request)
    }

    public func expire() { clear() }
    public func signOut() { clear() }

    public var recentInteraction: String? {
        var lines: [String] = []
        if let originalRequest { lines.append("task: \(Self.structuredSummary(originalRequest))") }
        lines.append(contentsOf: turns.map { "\($0.role.rawValue): \(Self.structuredSummary($0.text))" })
        if pendingClarification != nil { lines.append("pending: clarification") }
        if let latestVerifiedResult { lines.append("result: \(Self.structuredSummary(latestVerifiedResult))") }
        let value = lines.joined(separator: "\n")
        guard !value.isEmpty else { return nil }
        return String(value.prefix(1_600))
    }

    /// Converts conversational text into a small action/result vocabulary for
    /// cloud context and durable history. The original utterance remains
    /// available only in this in-memory session while a task is active.
    nonisolated public static func structuredSummary(_ value: String) -> String {
        let normalized = value
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return "control update" }
        if normalized.contains("clarif") || normalized.contains("which ") || normalized.contains("choose ") {
            return "clarification"
        }
        if normalized.contains("fail") || normalized.contains("error") || normalized.contains("stopped") {
            return "failed"
        }
        if normalized.contains("approv") || normalized.contains("confirm") {
            return "approved"
        }
        if normalized.contains("cancel") {
            return "cancelled"
        }
        if normalized.contains("open ") || normalized.contains("opened") || normalized.contains("launch") || normalized.contains("switch") {
            return normalized.contains("opened") ? "open application completed" : "open application"
        }
        if normalized.contains("scroll") { return normalized.contains("verified") ? "scroll completed" : "scroll" }
        if normalized.contains("focus") { return normalized.contains("verified") ? "focus completed" : "focus" }
        if normalized.contains("select") { return normalized.contains("verified") ? "select completed" : "select" }
        if normalized.contains("press") || normalized.contains("key") { return normalized.contains("verified") ? "press completed" : "press" }
        if normalized.contains("draft") || normalized.contains("message") || normalized.contains("email") || normalized.contains("tell ") {
            return normalized.contains("prepared") || normalized.contains("verified") ? "message completed" : "message"
        }
        if normalized.contains("complete") || normalized.contains("success") || normalized.contains("verified") {
            return "completed"
        }
        return "control update"
    }

    nonisolated public static func redactSensitive(_ value: String) -> String {
        var result = value
        let privateContentPatterns: [(String, String)] = [
            (#"\"[^\"\r\n]*\""#, "[quoted content redacted]"),
            (#"‘[^’\r\n]*’"#, "[quoted content redacted]"),
            (#"“[^”\r\n]*”"#, "[quoted content redacted]"),
            (#"'[^'\r\n]*'"#, "[quoted content redacted]"),
            (#"(?i)https?://[^\s<>\])]+"#, "[private URL redacted]"),
            (#"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#, "[recipient redacted]"),
            (#"(?i)(?:body|message|content)\s*[:=]\s*[^\r\n]+"#, "message: [message redacted]"),
            (#"(?i)account(?:\s+balance|\s+content)?\s*[:=]\s*[^\r\n]+"#, "account: [account content redacted]"),
        ]
        for (pattern, replacement) in privateContentPatterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            result = expression.stringByReplacingMatches(
                in: result,
                range: NSRange(location: 0, length: (result as NSString).length),
                withTemplate: replacement
            )
        }
        let patterns = [
            "(?i)(one[- ]time code|otp)(?:\\s+(?:is)\\s*|\\s*[:=]\\s*)[0-9]{4,8}",
            "(?i)(password|passcode|token|secret|api key)(?:\\s+(?:is)\\s*|\\s*[:=]\\s*)[^\\s,.;]+"
        ]
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            result = expression.stringByReplacingMatches(
                in: result,
                range: NSRange(location: 0, length: (result as NSString).length),
                withTemplate: "[redacted]"
            )
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var currentToken: ControlConversationToken {
        ControlConversationToken(taskID: taskID!, generation: generation)
    }

    private func cleaned(_ value: String?) -> String? {
        guard let value else { return nil }
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }
}
