import Testing
import FlowStateCore
@testable import FlowStateCloud

@Test("execution grants use validated plan capabilities")
func executionGrantsUseValidatedPlanCapabilities() {
    let press = NativePlanAction(
        kind: .press,
        targetBundleIdentifier: "com.example.Editor",
        parameters: .press(key: "A", modifiers: "Command"),
        capability: "app.input",
        requiresApproval: true
    )
    let open = NativePlanAction(
        kind: .openApplication,
        targetBundleIdentifier: "com.example.Editor",
        parameters: .openApplication,
        capability: "app.open",
        requiresApproval: true
    )

    #expect(cloudExecutionCapabilities(for: [press, open]) == ["app.input", "app.open"])
}
