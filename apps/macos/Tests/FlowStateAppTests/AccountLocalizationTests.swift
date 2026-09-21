import Foundation
import Testing

@Test("account catalogues stay in sync and use product language")
func accountCataloguesStayInSync() throws {
    let english = try loadAccountCatalogue(language: "en")

    #expect(english["account.sign_in"] == "Sign in")
    #expect(english["account.subtitle"] == nil)
    #expect(english["account.benefit.research.title"] == nil)

    let forbiddenTerms = [
        "AgentMail", "Clerk", "Convex", "Firecrawl", "OpenAI", "TypeSafe",
        "API key", "publishable key", "deployment URL"
    ]
    for value in english.values {
        for term in forbiddenTerms {
            #expect(!value.localizedCaseInsensitiveContains(term))
        }
        #expect(!value.contains(" / "))
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
