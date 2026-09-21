import Foundation
import FlowStateCore

struct ControlHistoryEntry: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let taskID: UUID
    let request: String
    let approvedPlan: String?
    let confirmations: [String]
    let stepOutcomes: [String]
    let failureReason: String?
    let createdAt: Date

    init(
        id: UUID = UUID(),
        taskID: UUID,
        request: String,
        approvedPlan: String? = nil,
        confirmations: [String] = [],
        stepOutcomes: [String] = [],
        failureReason: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.taskID = taskID
        self.request = request
        self.approvedPlan = approvedPlan
        self.confirmations = confirmations
        self.stepOutcomes = stepOutcomes
        self.failureReason = failureReason
        self.createdAt = createdAt
    }
}

/// Local redacted control history. Audio, screenshots, secure values, and
/// arbitrary field contents are intentionally not represented by this type.
actor ControlHistoryStore {
    static let defaultRetention: TimeInterval = 30 * 24 * 60 * 60
    private let defaults: UserDefaults
    private let key: String
    private let retentionKey: String
    private var retention: TimeInterval
    private var entries: [ControlHistoryEntry]

    init(
        defaults: UserDefaults = .standard,
        key: String = "flowstate.control-history.v1",
        retention: TimeInterval? = nil,
        retentionKey: String = "FlowState.controlRetentionDays"
    ) {
        self.defaults = defaults
        self.key = key
        self.retentionKey = retentionKey
        let persistedDays = defaults.object(forKey: retentionKey) as? NSNumber
        self.retention = max(0, retention ?? persistedDays.map { $0.doubleValue * 24 * 60 * 60 } ?? Self.defaultRetention)
        entries = (try? defaults.data(forKey: key).flatMap {
            try JSONDecoder().decode([ControlHistoryEntry].self, from: $0)
        }) ?? []
    }

    func setRetention(_ retention: TimeInterval) {
        self.retention = max(0, retention)
        defaults.set(self.retention / (24 * 60 * 60), forKey: retentionKey)
        purgeExpired(now: Date())
        save()
    }

    @discardableResult
    func append(
        taskID: UUID,
        request: String,
        approvedPlan: String? = nil,
        confirmations: [String] = [],
        stepOutcomes: [String] = [],
        failureReason: String? = nil,
        at now: Date = Date()
    ) -> ControlHistoryEntry? {
        let request = Self.redact(request)
        guard !request.isEmpty else { return nil }
        purgeExpired(now: now)
        let entry = ControlHistoryEntry(
            taskID: taskID,
            request: request,
            approvedPlan: approvedPlan.map(Self.redact),
            confirmations: confirmations.map(Self.redact).filter { !$0.isEmpty },
            stepOutcomes: stepOutcomes.map(Self.redact).filter { !$0.isEmpty },
            failureReason: failureReason.map(Self.redact),
            createdAt: now
        )
        if let index = entries.firstIndex(where: { $0.taskID == taskID }) {
            let existing = entries[index]
            let merged = ControlHistoryEntry(
                id: existing.id,
                taskID: taskID,
                request: existing.request,
                approvedPlan: entry.approvedPlan ?? existing.approvedPlan,
                confirmations: existing.confirmations + entry.confirmations,
                stepOutcomes: existing.stepOutcomes + entry.stepOutcomes,
                failureReason: entry.failureReason ?? existing.failureReason,
                createdAt: existing.createdAt
            )
            entries[index] = merged
            save()
            return merged
        }
        entries.insert(entry, at: 0)
        save()
        return entry
    }

    func list(now: Date = Date()) -> [ControlHistoryEntry] {
        purgeExpired(now: now)
        save()
        return entries
    }

    func delete(id: UUID) {
        entries.removeAll { $0.id == id }
        save()
    }

    func deleteAll() {
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

    private static func redact(_ value: String) -> String {
        ControlConversationSession.structuredSummary(value)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
