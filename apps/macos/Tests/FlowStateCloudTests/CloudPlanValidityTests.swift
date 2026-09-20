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
