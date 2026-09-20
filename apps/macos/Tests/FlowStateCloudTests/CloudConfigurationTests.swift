import Foundation
import Testing
@testable import FlowStateCloud

@Test func rejectsNonHTTPSOrCredentialBearingCloudURLs() throws {
    #expect(throws: CloudConfigurationError.self) { try CloudConfiguration(deploymentURL: "http://localhost:3000", publishableKey: "pk_test_" + Data("example.clerk.accounts.dev$".utf8).base64EncodedString()) }
    #expect(throws: CloudConfigurationError.self) { try CloudConfiguration(deploymentURL: "https://user:pass@example.convex.cloud", publishableKey: "pk_test_" + Data("example.clerk.accounts.dev$".utf8).base64EncodedString()) }
    #expect(throws: CloudConfigurationError.self) { try CloudConfiguration(deploymentURL: "https://example.convex.cloud", publishableKey: "sk_test_secret") }
    let configuration = try CloudConfiguration(deploymentURL: "https://example.convex.cloud", publishableKey: "pk_test_" + Data("example.clerk.accounts.dev$".utf8).base64EncodedString())
    #expect(configuration.deploymentURL == "https://example.convex.cloud")
}
@Test func deviceIDIsStableAndContainsNoCredentials() {
    let suite="flowstate-tests-\(UUID().uuidString)"
    let defaults=UserDefaults(suiteName:suite)!
    defer { defaults.removePersistentDomain(forName:suite) }
    #expect(CloudConfiguration.deviceID(in: defaults) == CloudConfiguration.deviceID(in: defaults))
}

@Test func decodesTheBackendRunEnvelopeWithoutAnExtraRunWrapper() throws {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { root.deleteLastPathComponent() }
    let data = try Data(contentsOf: root.appendingPathComponent("tests/fixtures/research-run.json"))
    let run = try JSONDecoder().decode(CloudRun.self, from: data)
    #expect(run.note?.id == run.id)
    #expect(run.note?.status == "ready")
    #expect(run.error == nil)
}

@Test func rejectsMalformedClerkKeysBeforeSDKConfiguration() {
    for key in ["pk_test_", "pk_test_example", "pk_test_" + Data("https://evil.test$".utf8).base64EncodedString(), "pk_test_" + Data("example.test".utf8).base64EncodedString()] {
        #expect(throws: CloudConfigurationError.self) { try CloudConfiguration(deploymentURL: "https://example.convex.cloud", publishableKey: key) }
    }
}
