import Foundation

/// Small local receipt store for external effects whose outcome is uncertain.
/// It intentionally persists only opaque identifiers and redacted summaries.
final class ExternalEffectRecoveryStore {
    static let defaultKey = "flowstate.external-effect-recovery.v1"

    private let defaults: UserDefaults
    private let key: String
    private var entries: [ExternalEffectRecovery]

    init(defaults: UserDefaults = .standard, key: String = ExternalEffectRecoveryStore.defaultKey) {
        self.defaults = defaults
        self.key = key
        entries = (try? defaults.data(forKey: key).flatMap {
            try JSONDecoder().decode([ExternalEffectRecovery].self, from: $0)
        })?.filter { !$0.receiptID.isEmpty && !$0.operationFingerprint.isEmpty } ?? []
    }

    func list() -> [ExternalEffectRecovery] { entries }

    func upsert(_ entry: ExternalEffectRecovery) {
        entries.removeAll { $0.receiptID == entry.receiptID }
        entries.insert(entry, at: 0)
        save()
    }

    func remove(receiptID: String) {
        entries.removeAll { $0.receiptID == receiptID }
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: key)
    }
}
