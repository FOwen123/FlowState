import Foundation
import FlowStateCore
import Testing
@testable import FlowStateApp

@Test("cancelling a local input grant cancels the plan without cancelling research")
@MainActor
func cancellingInputGrantUsesPlanCancellationOnly() {
    let model = FlowStateAppModel()
    var planCancelled = false
    var researchCancelled = false
    model.onCancelCloud = { planCancelled = true }
    model.onCancelResearch = { researchCancelled = true }

    model.cancelInputTask()

    #expect(planCancelled)
    #expect(!researchCancelled)
}

@Test("physical takeover retains the explicit grant for a reviewed resume")
@MainActor
func takeoverRetainsGrantForResume() async throws {
    let controller = DesktopAutomationController()
    let model = FlowStateAppModel(desktopController: controller)
    model.inputBundleIdentifier = "com.example.Reader"
    model.beginInputTask()
    for _ in 0..<100 {
        if model.currentInputGrant != nil { break }
        try await Task.sleep(for: .milliseconds(2))
    }
    let grant = try #require(model.currentInputGrant)
    model.handlePhysicalTakeover(for: 1)
    #expect(model.currentInputGrant?.generation == grant.generation)
    #expect(model.desktopState == .pausedForUser)
    model.cancelInputTask()
    #expect(model.currentInputGrant == nil)
    #expect(model.desktopState == .cancelled)
}
