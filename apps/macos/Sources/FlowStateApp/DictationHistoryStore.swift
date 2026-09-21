import Foundation
import FlowStateCore

public struct DictationHistoryEntry: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let text: String
    public let failureReason: String?
    public let createdAt: Date

    public init(id: UUID = UUID(), text: String, failureReason: String? = nil, createdAt: Date = Date()) {
        self.id = id
        self.text = text
        self.failureReason = failureReason
        self.createdAt = createdAt
    }
}

public struct DictationRecoveryCard: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let text: String
    public let reason: String
    public let target: DictationTarget
    public let expiresAt: Date

    public init(id: UUID = UUID(), text: String, reason: String, target: DictationTarget, expiresAt: Date) {
        self.id = id
        self.text = text
        self.reason = reason
        self.target = target
        self.expiresAt = expiresAt
    }
}

/// Local-only final-text history. Raw audio and screenshots never enter this
/// store; expired entries are removed on every read and write.
public actor DictationHistoryStore {
    public static let defaultRetention: TimeInterval = 30 * 24 * 60 * 60
    private let defaults: UserDefaults
    private let key: String
    private let retentionKey: String
    private var retention: TimeInterval
    private var entries: [DictationHistoryEntry]

    public init(
        defaults: UserDefaults = .standard,
        key: String = "flowstate.dictation-history.v1",
        retention: TimeInterval? = nil,
        retentionKey: String = "FlowState.dictationRetentionDays"
    ) {
        self.defaults = defaults
        self.key = key
        self.retentionKey = retentionKey
        let persistedDays = defaults.object(forKey: retentionKey) as? NSNumber
        self.retention = max(0, retention ?? persistedDays.map { $0.doubleValue * 24 * 60 * 60 } ?? Self.defaultRetention)
        entries = (try? defaults.data(forKey: key).flatMap { try JSONDecoder().decode([DictationHistoryEntry].self, from: $0) }) ?? []
    }

    public func setRetention(_ retention: TimeInterval) {
        self.retention = max(0, retention)
        defaults.set(self.retention / (24 * 60 * 60), forKey: retentionKey)
        purgeExpired(now: Date())
        save()
    }

    @discardableResult
    public func append(text: String, failureReason: String? = nil, at now: Date = Date()) -> DictationHistoryEntry? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        purgeExpired(now: now)
        let entry = DictationHistoryEntry(text: value, failureReason: failureReason, createdAt: now)
        entries.insert(entry, at: 0)
        save()
        return entry
    }

    public func list(now: Date = Date()) -> [DictationHistoryEntry] {
        purgeExpired(now: now)
        save()
        return entries
    }

    public func delete(id: UUID) {
        entries.removeAll { $0.id == id }
        save()
    }

    public func deleteAll() {
        entries.removeAll()
        save()
    }

    private func purgeExpired(now: Date) {
        let cutoff = now.addingTimeInterval(-retention)
        entries.removeAll { $0.createdAt < cutoff }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: key)
    }
}
