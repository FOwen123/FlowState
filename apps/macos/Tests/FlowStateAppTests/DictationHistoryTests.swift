import Foundation
import Testing
@testable import FlowStateApp

@Test("failed dictation remains available after transient UI expiry")
func failedDictationHistoryPersists() async throws {
    let defaults = try #require(UserDefaults(suiteName: "flowstate.dictation.\(UUID().uuidString)"))
    let store = DictationHistoryStore(defaults: defaults, retention: 60)
    _ = await store.append(text: "open Brave", failureReason: "Focused field changed", at: Date(timeIntervalSince1970: 100))
    let entries = await store.list(now: Date(timeIntervalSince1970: 110))
    #expect(entries.count == 1)
    #expect(entries[0].failureReason == "Focused field changed")
}

@Test("dictation history removes only expired local entries")
func dictationHistoryRetention() async throws {
    let defaults = try #require(UserDefaults(suiteName: "flowstate.dictation.\(UUID().uuidString)"))
    let store = DictationHistoryStore(defaults: defaults, retention: 60)
    _ = await store.append(text: "old", at: Date(timeIntervalSince1970: 100))
    _ = await store.append(text: "new", at: Date(timeIntervalSince1970: 150))
    let entries = await store.list(now: Date(timeIntervalSince1970: 210))
    #expect(entries.map(\.text) == ["new"])
}

@Test("dictation retention survives store recreation")
func dictationRetentionPersists() async throws {
    let suite = "flowstate.dictation.retention.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    let first = DictationHistoryStore(defaults: defaults)
    await first.setRetention(2 * 24 * 60 * 60)
    _ = await first.append(text: "old", at: Date(timeIntervalSince1970: 100))

    let reopened = DictationHistoryStore(defaults: defaults)
    _ = await reopened.append(text: "new", at: Date(timeIntervalSince1970: 200_000))
    #expect((await reopened.list(now: Date(timeIntervalSince1970: 200_001))).map(\.text) == ["new"])
}
