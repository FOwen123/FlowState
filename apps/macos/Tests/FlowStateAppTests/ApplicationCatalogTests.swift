import Foundation
import Testing
@testable import FlowStateApp

@Test func appCandidatesIncludeClosedAppsAndDeduplicateBundleIdentity() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let info: [String: String] = ["CFBundleIdentifier": "org.example.closed", "CFBundleName": "Closed Editor"]
    var urls: [URL] = []
    for name in ["First", "Duplicate"] {
        let url = root.appendingPathComponent(name + ".app")
        try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: url.appendingPathComponent("Contents/Info.plist"))
        urls.append(url)
    }
    let apps = ApplicationCatalog.entries(at: urls)
    #expect(apps.count == 1)
    #expect(apps.first?.bundleIdentifier == "org.example.closed")
    #expect(apps.first?.name == "Closed Editor")
}
