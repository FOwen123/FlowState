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

@Test("physical input leaves the explicit grant active for revalidation")
@MainActor
func physicalInputLeavesGrantActive() async throws {
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
    #expect(model.desktopState == .ready)
    #expect(model.desktopStatus.contains("rechecking"))
    model.cancelInputTask()
    #expect(model.currentInputGrant == nil)
    #expect(model.desktopState == .cancelled)
}

@Test("new control task invalidates active local work before creating the next task")
@MainActor
func newControlTaskCancelsActiveExecution() async throws {
    let controller = DesktopAutomationController()
    let model = FlowStateAppModel(desktopController: controller)
    model.inputBundleIdentifier = "com.example.Reader"
    let oldTask = model.beginInputTask()
    for _ in 0..<100 {
        if model.currentInputGrant != nil { break }
        try await Task.sleep(for: .milliseconds(2))
    }
    #expect(model.currentInputGrant != nil)

    var cloudCancelled = false
    model.onCancelCloud = { cloudCancelled = true }
    model.startNewControlTask()

    #expect(cloudCancelled)
    #expect(model.currentInputGrant == nil)
    #expect(model.desktopState == .cancelled)
    oldTask?.cancel()
    for _ in 0..<100 {
        if await controller.state == .cancelled { break }
        try await Task.sleep(for: .milliseconds(2))
    }
    #expect(await controller.state == .cancelled)
}
