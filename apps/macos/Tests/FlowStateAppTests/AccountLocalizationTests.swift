import Foundation
import Testing

@Test("account catalogues stay in sync and use product language")
func accountCataloguesStayInSync() throws {
    let english = try loadAccountCatalogue(language: "en")
    let traditionalChinese = try loadAccountCatalogue(language: "zh-Hant")

    #expect(Set(english.keys) == Set(traditionalChinese.keys))
    #expect(english["account.signed_out.title"] == "Sign in to Flow State")
    #expect(traditionalChinese["account.signed_out.title"] == "登入 Flow State")

    let forbiddenTerms = [
        "AgentMail", "Clerk", "Convex", "Firecrawl", "OpenAI", "TypeSafe",
        "API key", "publishable key", "deployment URL"
    ]
    for (key, value) in english {
        #expect(formatSpecifiers(value) == formatSpecifiers(traditionalChinese[key] ?? ""))
        for term in forbiddenTerms {
            #expect(!value.localizedCaseInsensitiveContains(term))
        }
        #expect(!value.contains(" / "))
    }
    for value in traditionalChinese.values {
        #expect(!value.contains(" / "))
        for term in forbiddenTerms {
            #expect(!value.localizedCaseInsensitiveContains(term))
        }
    }
}

private func loadAccountCatalogue(language: String) throws -> [String: String] {
    let fileURL = URL(fileURLWithPath: #filePath)
    let resourcesURL = fileURL
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/FlowStateApp/Resources")
        .appendingPathComponent("\(language).lproj/Account.strings")
    let data = try Data(contentsOf: resourcesURL)
    var format = PropertyListSerialization.PropertyListFormat.openStep
    let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: &format)
    return try #require(plist as? [String: String])
}

private func formatSpecifiers(_ value: String) -> [String] {
    var result: [String] = []
    for index in value.indices where value[index] == "%" {
        let next = value.index(after: index)
        guard next < value.endIndex else { continue }
        if ["@", "d", "f"].contains(String(value[next])) {
            result.append(String(value[index...next]))
        }
    }
    return result
}
