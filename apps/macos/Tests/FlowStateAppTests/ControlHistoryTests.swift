import Foundation
import Testing
@testable import FlowStateApp

@Test("control history retains redacted task outcomes for thirty days")
func controlHistoryRetentionAndRedaction() async throws {
    let defaults = try #require(UserDefaults(suiteName: "flowstate.control.\(UUID().uuidString)"))
    let store = ControlHistoryStore(defaults: defaults, retention: 60)
    let taskID = UUID()
    _ = await store.append(
        taskID: taskID,
        request: "Open Brave with password=secret-value",
        approvedPlan: "Open Brave",
        confirmations: ["Approved"],
        stepOutcomes: ["Brave opened"],
        failureReason: nil,
        at: Date(timeIntervalSince1970: 100)
    )
    let entries = await store.list(now: Date(timeIntervalSince1970: 110))

    #expect(entries.count == 1)
    #expect(!entries[0].request.contains("secret-value"))
    #expect(entries[0].taskID == taskID)
    #expect(entries[0].stepOutcomes == ["open application completed"])
}

@Test("control history removes expired entries and supports per-item and delete-all removal")
func controlHistoryDeletion() async throws {
    let defaults = try #require(UserDefaults(suiteName: "flowstate.control.\(UUID().uuidString)"))
    let store = ControlHistoryStore(defaults: defaults, retention: 60)
    let old = try #require(await store.append(taskID: UUID(), request: "Old", at: Date(timeIntervalSince1970: 100)))
    _ = await store.append(taskID: UUID(), request: "New", at: Date(timeIntervalSince1970: 150))

    let retained = await store.list(now: Date(timeIntervalSince1970: 210))
    #expect(retained.map(\.request) == ["control update"])
    await store.delete(id: old.id)
    #expect(await store.list().isEmpty)

    _ = await store.append(taskID: UUID(), request: "Another")
    await store.deleteAll()
    #expect(await store.list().isEmpty)
}

@Test("control history upserts one cumulative record per task")
func controlHistoryUpsertsPerTask() async throws {
    let defaults = try #require(UserDefaults(suiteName: "flowstate.control.merge.\(UUID().uuidString)"))
    let store = ControlHistoryStore(defaults: defaults)
    let taskID = UUID()
    _ = await store.append(taskID: taskID, request: "Open Brave", confirmations: ["approved"], stepOutcomes: ["opened"])
    _ = await store.append(taskID: taskID, request: "Open Brave", stepOutcomes: ["verified"])

    let entries = await store.list()
    #expect(entries.count == 1)
    #expect(entries[0].confirmations == ["approved"])
    #expect(entries[0].stepOutcomes == ["open application completed", "completed"])
}

@Test("control history never persists recipients, message bodies, or private URL queries")
func controlHistoryRedactsStructuredPrivateContent() async throws {
    let suite = "flowstate.control.private.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    let store = ControlHistoryStore(defaults: defaults)
    let taskID = UUID()
    _ = await store.append(
        taskID: taskID,
        request: "Draft to owner@example.com with body: \"quarterly results are private\"",
        approvedPlan: "Open https://private.example/account?token=abc123",
        stepOutcomes: ["Prepared message body: quarterly results are private"],
        at: Date(timeIntervalSince1970: 100)
    )

    let entries = await store.list(now: Date(timeIntervalSince1970: 101))
    let encoded = try JSONEncoder().encode(entries)
    let persisted = String(decoding: encoded, as: UTF8.self)
    #expect(!persisted.contains("owner@example.com"))
    #expect(!persisted.contains("quarterly results are private"))
    #expect(!persisted.contains("https://private.example/account?token=abc123"))
}

@Test("control history removes unlabeled private prose from persisted summaries")
func controlHistoryRedactsUnlabeledPrivateContent() async throws {
    let defaults = try #require(UserDefaults(suiteName: "flowstate.control.unlabeled.\(UUID().uuidString)"))
    let store = ControlHistoryStore(defaults: defaults)
    _ = await store.append(
        taskID: UUID(),
        request: "Tell owner@example.com that violet-cedar-phrase-741 is private",
        approvedPlan: "Open https://private.example/account?query=violet-cedar-query-852",
        stepOutcomes: ["Prepared violet-cedar-body-963"],
        at: Date(timeIntervalSince1970: 100)
    )

    let persisted = String(decoding: try JSONEncoder().encode(await store.list(now: Date(timeIntervalSince1970: 101))), as: UTF8.self)
    #expect(!persisted.contains("violet-cedar-phrase-741"))
    #expect(!persisted.contains("violet-cedar-query-852"))
    #expect(!persisted.contains("violet-cedar-body-963"))
}
