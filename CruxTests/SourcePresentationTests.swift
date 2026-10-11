import CruxCore
import Foundation
import Testing

@testable import Crux

@MainActor
struct SourcePresentationTests {
    @Test func reusedDeletedSourceNamesKeepDistinctSecondaryProvenance() {
        let old = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let new = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let ids: Set<UUID> = [old, new]
        let removed = SourcePresentation.distinctOriginName("Team", id: old, collidingIDs: ids, deleted: true)
        let active = SourcePresentation.distinctOriginName("Team", id: new, collidingIDs: ids, deleted: false)
        #expect(removed != active)
        #expect(removed.contains("11111111"))
        #expect(active.contains("22222222"))
        #expect(SourcePresentation.title("Python", sourceName: removed, enabledSourceCount: 1) == "Python")
    }

    @Test func collidingShortIDsFallBackToFullSourceIdentity() {
        let a = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let b = UUID(uuidString: "22222222-2222-2222-2222-222211111111")!
        let ids: Set<UUID> = [a, b]
        #expect(SourcePresentation.distinctOriginName("Team", id: a, collidingIDs: ids, deleted: false).contains(a.uuidString.lowercased()))
        #expect(SourcePresentation.distinctOriginName("Team", id: b, collidingIDs: ids, deleted: false).contains(b.uuidString.lowercased()))
    }
    private let firstID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let secondID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    @Test func titlesDisambiguateOnlyWhenMultipleSourcesAreEnabled() {
        #expect(SourcePresentation.title("Python", sourceName: "Team", enabledSourceCount: 2) == "Python（Team）")
        #expect(SourcePresentation.title("Python", sourceName: "Team", enabledSourceCount: 1) == "Python")
        #expect(SourcePresentation.title("Python", sourceName: "Team", enabledSourceCount: 0) == "Python")
    }

    @Test func availableGroupsKeepEmptySourcesAndSeparateIdenticalUpstreamEntries() throws {
        let first = source(firstID, "First")
        let second = source(secondID, "Second")
        let empty = source(UUID(), "Private")
        var disabled = source(UUID(), "Disabled")
        disabled.isEnabled = false
        let items = [SourcedCatalogEntry(source: second, entry: entry()), SourcedCatalogEntry(source: first, entry: entry())]
        let groups = SourcePresentation.availableGroups(sources: [first, second, empty, disabled], entries: items)
        #expect(groups.map(\.id) == [firstID, secondID, empty.id])
        try #require(groups.map { $0.items.count } == [1, 1, 0])
        #expect(groups[0].items[0].id != groups[1].items[0].id)
    }

    @Test func installedGroupsRetainDisabledDeletedAndLocalOrigins() throws {
        var disabled = source(firstID, "Renamed")
        disabled.isEnabled = false
        let records = [try installed(id: "one", sourceID: firstID, sourceName: "Old"),
                       try installed(id: "two", sourceID: secondID, sourceName: "Deleted"),
                       try installed(id: "local", sourceID: nil, sourceName: nil)]
        let groups = SourcePresentation.installedGroups(records, sources: [disabled]) { record in
            record.sourceConfigurationID == self.firstID ? "Renamed" : record.sourceName ?? "Local"
        }
        #expect(Set(groups.map(\.id)) == [firstID, secondID, DocsetSourceConfiguration.localID])
        #expect(groups.first { $0.id == firstID }?.name == "Renamed")
        #expect(groups.flatMap(\.items).count == 3)
        #expect(SourcePresentation.showsInstalledSections(enabledSourceCount: 1, groupCount: 3))
        #expect(!SourcePresentation.showsInstalledSections(enabledSourceCount: 1, groupCount: 1))
    }

    @Test func sourceIdentityDoesNotChangeWhenRenamed() {
        #expect(SourcePresentation.accessibilityID("source-toggle", sourceID: firstID) ==
                "source-toggle-11111111-1111-1111-1111-111111111111")
    }

    @Test func customZealKeepsCatalogAndDownloadRootSeparate() throws {
        var draft = SourceDraft()
        draft.name = " Team "
        draft.catalogURL = "https://example.invalid/catalog.json"
        draft.downloadRootURL = "https://downloads.invalid/docsets/"
        draft.isEnabled = false
        let config = try draft.configuration()
        #expect(config.name == "Team")
        #expect(!config.isEnabled)
        #expect(config.kind == .zeal(catalogURL: URL(string: draft.catalogURL)!, downloadRootURL: URL(string: draft.downloadRootURL)!))
        #expect(config.transportPolicy == .strictHTTPS)
    }

    @Test func XMLSubscriptionNeedsOnlyItsOwnFeedURL() throws {
        var draft = SourceDraft()
        draft.name = "One docset"
        draft.kind = .feed
        draft.catalogURL = "https://example.invalid/docset.xml"
        let config = try draft.configuration()
        #expect(config.kind == .feed(url: URL(string: draft.catalogURL)!))
    }

    @Test func insecureHTTPRequiresConsentForBothEndpoints() throws {
        var draft = SourceDraft()
        draft.name = "Local"
        draft.catalogURL = "http://localhost:8080/catalog.json"
        draft.downloadRootURL = "http://192.168.1.20/docsets/"
        #expect(throws: SourceTransportError.httpsRequired) { try draft.configuration() }
        draft.allowsLocalHTTP = true
        #expect(try draft.configuration().transportPolicy == .localHTTP)
        draft.downloadRootURL = "http://example.invalid/docsets/"
        #expect(throws: SourceTransportError.localHTTPRequired) { try draft.configuration() }
    }

    @Test func malformedNamesAndCredentialURLsCannotBeSaved() {
        var draft = SourceDraft()
        draft.name = "\n"
        #expect(throws: SourceDraftError.invalidName) { try draft.configuration() }
        draft.name = "Team"
        draft.catalogURL = "https://user:password@example.invalid/catalog.json"
        draft.downloadRootURL = "https://example.invalid/docsets/"
        #expect(throws: SourceTransportError.credentialsNotAllowed) { try draft.configuration() }
    }

    @Test func editingRetainsEndpointPolicyAndUUID() throws {
        let config = DocsetSourceConfiguration(id: firstID, name: "Local", kind: .feed(url: URL(string: "http://localhost/docset.xml")!),
                                               transportPolicy: .localHTTP)
        var draft = SourceDraft(editing: config)
        draft.name = "Renamed"
        draft.isEnabled = false
        draft.catalogURL = "https://different.invalid/feed.xml"
        draft.allowsLocalHTTP = false
        let renamed = try draft.configuration()
        #expect(renamed.id == firstID)
        #expect(renamed.kind == config.kind)
        #expect(renamed.transportPolicy == .localHTTP)
        #expect(!renamed.isEnabled)
        #expect(renamed.name == "Renamed")
    }

    @Test func onlyCustomSourcesOfferDeletion() {
        #expect(!SourcePresentation.canDelete(DocsetSourceConfiguration.defaults[0]))
        #expect(!SourcePresentation.canDelete(DocsetSourceConfiguration.defaults[1]))
        #expect(SourcePresentation.canDelete(source(firstID, "Team")))
    }

    private func source(_ id: UUID, _ name: String) -> DocsetSourceConfiguration {
        DocsetSourceConfiguration(id: id, name: name, kind: .feed(url: URL(string: "https://example.invalid/\(id).xml")!))
    }

    private func entry() -> CatalogEntry {
        CatalogEntry(name: "python", title: "Python", sourceId: "publisher", version: "3.14", revision: nil,
                     downloadURL: URL(string: "https://example.invalid/python.tgz")!, keywords: ["python"])
    }

    private func installed(id: String, sourceID: UUID?, sourceName: String?) throws -> InstalledDocset {
        let descriptor = try JSONDecoder().decode(DocsetDescriptor.self, from: Data("""
        {"identifier":"\(id)","name":"Python","displayName":"Python","keywords":[],
         "bundleURL":"file:///tmp/\(id).docset","documentsURL":"file:///tmp/docs", "indexURL":"file:///tmp/index",
         "indexSchema":"dash","isJavaScriptEnabled":false}
        """.utf8))
        return InstalledDocset(descriptor: descriptor, source: sourceID == nil ? .localImport : .catalog(name: "python", sourceId: "publisher"),
                               advertisedVersion: DocsetVersion(version: "3.14", revision: nil),
                               sourceConfigurationID: sourceID, sourceName: sourceName)
    }
}
