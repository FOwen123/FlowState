import Foundation
import Testing
@testable import FlowStateCloud

@Test func staleOrExpiredCloudPlansCannotContinueAfterAnAwait() throws {
    let now = Date(timeIntervalSince1970: 100)
    try requireCurrentCloudPlan(signedIn: true, currentGeneration: 2, requestGeneration: 2, expiresAt: 101_000, now: now)
    #expect(throws: (any Error).self) { try requireCurrentCloudPlan(signedIn: false, currentGeneration: 2, requestGeneration: 2, expiresAt: 101_000, now: now) }
    #expect(throws: (any Error).self) { try requireCurrentCloudPlan(signedIn: true, currentGeneration: 3, requestGeneration: 2, expiresAt: 101_000, now: now) }
    #expect(throws: (any Error).self) { try requireCurrentCloudPlan(signedIn: true, currentGeneration: 2, requestGeneration: 2, expiresAt: 100_000, now: now) }
}

@Test func planningKeepsTheWholeRequestAndDoesNotForceTheForegroundApp() {
    let command = "Open Brave and search Hello World"
    let context = plannerCommandContext(command: command, activeApplication: "com.example.Editor",
        recentInteraction: "result: opened Brave")
    #expect(context.contains(command))
    #expect(context.contains("context only"))
    #expect(!context.contains("Start by opening the selected target"))
    #expect(context.contains("result: opened Brave"))
}

@Test func clarificationResolutionCanReachMetadataWithoutBecomingExecutable() throws {
    let data = Data(#"{"planId":"plan","status":"awaiting_approval","fingerprint":"fp","actions":[],"capabilities":[]}"#.utf8)
    let result = try JSONDecoder().decode(CloudPlanResolution.self, from: data)
    #expect(result.fingerprint == "fp")
    #expect(result.executablePlan == nil)
}

@Test func objectMutationReceiptsDoNotUseConvexVoidStringDecoder() throws {
    let receipt = Data(#"{"deviceId":"test-device"}"#.utf8)
    #expect(throws: (any Error).self) { try JSONDecoder().decode(String?.self, from: receipt) }
    _ = try JSONDecoder().decode(CloudMutationReceipt.self, from: receipt)
}
