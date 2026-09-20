import Foundation
import Testing
@testable import FlowStateCore

@Test func explicitVocabularyReplacesWholeEnglishWordsWithoutCascading() async throws {
    let memory = ExplicitMemoryStore(suiteName:"flowstate-personalization-\(UUID().uuidString)")
    _ = try await memory.upsert(trigger:"flow",value:"FlowState",category:.vocabulary)
    _ = try await memory.upsert(trigger:"FlowState",value:"Other",category:.vocabulary)
    #expect(await memory.personalize("flow flower FLOW",mode:.dictation) == "FlowState flower FlowState")
    _ = try await memory.upsert(trigger:"繁中",value:"繁體中文",category:.vocabulary)
    #expect(await memory.personalize("請用繁中回答",mode:.dictation) == "請用繁體中文回答")
}
@Test func appAliasesOnlyAffectExplicitOpenCommands() async throws {
    let memory = ExplicitMemoryStore(suiteName:"flowstate-alias-\(UUID().uuidString)")
    _ = try await memory.upsert(trigger:"my browser",value:"Brave",category:.appAlias)
    #expect(await memory.personalize("open my browser",mode:.command) == "open Brave")
    #expect(await memory.personalize("do not open my browser",mode:.command) == "do not open my browser")
    #expect(await memory.personalize("open my browser",mode:.dictation) == "open my browser")
}
