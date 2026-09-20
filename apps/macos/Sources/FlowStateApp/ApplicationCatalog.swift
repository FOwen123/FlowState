import AppKit
import Foundation

struct InstalledApplication: Identifiable, Equatable, Sendable {
    let bundleIdentifier: String
    let name: String
    var id: String { bundleIdentifier }
}

enum ApplicationCatalog {
    static func entries(at urls: [URL]) -> [InstalledApplication] {
        var seen = Set<String>()
        return urls.compactMap { url in
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier,
                  id != "com.flowstate.dev", seen.insert(id).inserted else { return nil }
            let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? url.deletingPathExtension().lastPathComponent
            return InstalledApplication(bundleIdentifier: id, name: name)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    @MainActor static func installed() -> [InstalledApplication] {
        let directories = ["/Applications", "/System/Applications", "/System/Applications/Utilities", NSHomeDirectory() + "/Applications"]
        let urls = directories.flatMap { directory in
            (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: directory), includingPropertiesForKeys: nil)) ?? []
        }.filter { $0.pathExtension == "app" }
        let running = NSWorkspace.shared.runningApplications.compactMap(\.bundleURL)
        return entries(at: urls + running + [URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")])
    }
}
