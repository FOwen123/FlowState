import Foundation

public enum CloudConfigurationError: Error, Equatable {
    case invalidDeploymentURL
    case invalidPublishableKey
}
public struct CloudConfiguration: Equatable, Sendable {
    public let deploymentURL: String
    public let publishableKey: String
    public init(deploymentURL: String, publishableKey: String) throws {
        guard let url = URL(string: deploymentURL), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/" else { throw CloudConfigurationError.invalidDeploymentURL }
        guard publishableKey.hasPrefix("pk_test_") || publishableKey.hasPrefix("pk_live_") else {
            throw CloudConfigurationError.invalidPublishableKey
        }
        let encoded = String(publishableKey.dropFirst(8))
        let padded = encoded + String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: padded), let decoded = String(data: data, encoding: .utf8),
              decoded.hasSuffix("$"),
              String(decoded.dropLast()).range(of: #"^[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?\.[A-Za-z]{2,}$"#, options: .regularExpression) != nil else {
            throw CloudConfigurationError.invalidPublishableKey
        }
        self.deploymentURL = deploymentURL
        self.publishableKey = publishableKey
    }
    public static func deviceID(in defaults: UserDefaults = .standard) -> String {
        if let stored = defaults.string(forKey: "FlowState.cloudDeviceID") { return stored }
        let value = UUID().uuidString
        defaults.set(value, forKey: "FlowState.cloudDeviceID")
        return value
    }
}
