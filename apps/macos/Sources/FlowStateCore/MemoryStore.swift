import Foundation

public enum MemoryCategory: String, Codable, CaseIterable, Sendable {
    case vocabulary
    case appAlias
    case writingStyle
    case folder

    public var displayName: String {
        switch self {
        case .vocabulary: "Vocabulary"
        case .appAlias: "App alias"
        case .writingStyle: "Writing style"
        case .folder: "Folder"
        }
    }
}

public enum MemorySource: String, Codable, Sendable {
    case explicit
    case learned
}

public struct MemoryPreference: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var trigger: String
    public var value: String
    public var category: MemoryCategory
    public var source: MemorySource
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        trigger: String,
        value: String,
        category: MemoryCategory,
        source: MemorySource = .explicit,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.trigger = trigger
        self.value = value
        self.category = category
        self.source = source
        self.updatedAt = updatedAt
    }
}

public struct MemorySnapshot: Codable, Equatable, Sendable {
    public let preferences: [MemoryPreference]
    public let syncEnabled: Bool
    public let learningEnabled: Bool

    public init(
        preferences: [MemoryPreference],
        syncEnabled: Bool,
        learningEnabled: Bool
    ) {
        self.preferences = preferences
        self.syncEnabled = syncEnabled
        self.learningEnabled = learningEnabled
    }
}

/// Explicit preferences are local by default. Learned entries are opt-in and
/// never override an explicit entry with the same trigger.
public actor ExplicitMemoryStore {
    private struct Persisted: Codable {
        var preferences: [MemoryPreference] = []
        var syncEnabled = false
        var learningEnabled = false
    }

    private let defaults: UserDefaults
    private let key = "flowstate.explicit-memory.v1"
    private var persisted: Persisted

    public init(suiteName: String? = nil) {
        defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode(Persisted.self, from: data) {
            persisted = decoded
        } else {
            persisted = Persisted()
        }
    }

    @discardableResult
    public func upsert(
        id: UUID? = nil,
        trigger: String,
        value: String,
        category: MemoryCategory,
        source: MemorySource = .explicit
    ) throws -> MemoryPreference {
        guard source != .learned || persisted.learningEnabled else {
            throw MemoryStoreError.learningDisabled
        }
        let cleanTrigger = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTrigger.isEmpty, !cleanValue.isEmpty else {
            throw MemoryStoreError.emptyValue
        }
        let preference = MemoryPreference(
            id: id ?? UUID(),
            trigger: cleanTrigger,
            value: cleanValue,
            category: category,
            source: source
        )
        persisted.preferences.removeAll { $0.id == preference.id }
        persisted.preferences.append(preference)
        try save()
        return preference
    }

    public func delete(id: UUID) throws {
        persisted.preferences.removeAll { $0.id == id }
        try save()
    }

    public func preference(id: UUID) -> MemoryPreference? {
        persisted.preferences.first { $0.id == id }
    }

    public func snapshot() -> MemorySnapshot {
        MemorySnapshot(
            preferences: persisted.preferences.sorted { $0.updatedAt > $1.updatedAt },
            syncEnabled: persisted.syncEnabled,
            learningEnabled: persisted.learningEnabled
        )
    }

    public func setSyncEnabled(_ enabled: Bool) throws {
        persisted.syncEnabled = enabled
        try save()
    }

    public func setLearningEnabled(_ enabled: Bool) throws {
        persisted.learningEnabled = enabled
        try save()
    }

    public func effectiveValue(for trigger: String) -> String? {
        let normalized = normalize(trigger)
        return persisted.preferences
            .filter {
                normalize($0.trigger) == normalized &&
                    ($0.source == .explicit || persisted.learningEnabled)
            }
            .sorted { lhs, rhs in
                if lhs.source != rhs.source { return lhs.source == .explicit }
                return lhs.updatedAt > rhs.updatedAt
            }
            .first?.value
    }

    private func save() throws {
        guard let data = try? JSONEncoder().encode(persisted) else {
            throw MemoryStoreError.persistenceFailed
        }
        defaults.set(data, forKey: key)
    }

    private func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

public enum MemoryStoreError: Error, Equatable, LocalizedError, Sendable {
    case emptyValue
    case learningDisabled
    case persistenceFailed

    public var errorDescription: String? {
        switch self {
        case .emptyValue: "Memory entries need a phrase and a value."
        case .learningDisabled: "Learned preferences are disabled in settings."
        case .persistenceFailed: "The preference could not be saved on this Mac."
        }
    }
}
