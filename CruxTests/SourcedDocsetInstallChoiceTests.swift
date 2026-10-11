import CruxCore
import Foundation
import Testing

@testable import Crux

@MainActor
struct SourcedDocsetInstallChoiceTests {
    @Test func choicesKeepIdenticalFamiliesInSeparateSourceSlots() throws {
        let entry = try versionedEntry()
        let first = sourced(entry, id: UUID())
        let second = sourced(entry, id: UUID())
        let a = try #require(DocsetInstallChoice(entry: first, policy: .latest, installed: nil, isBusy: false))
        let b = try #require(DocsetInstallChoice(entry: second, policy: .latest, installed: nil, isBusy: false))
        #expect(a.id != b.id)
        #expect(a.target?.sourceConfigurationID == first.sourceConfigurationID)
        #expect(a.target?.slotKey != b.target?.slotKey)
        #expect(a.summary.contains("（Team）"))
        #expect(a.sourcedEntry == first)
    }

    @Test func sameSourceNoOpAndPolicyChangeUseScopedTarget() throws {
        let entry = sourced(try versionedEntry(), id: UUID())
        let initial = try #require(DocsetInstallChoice(entry: entry, policy: .latest, installed: nil, isBusy: false))
        let installed = try record(target: #require(initial.target))
        #expect(DocsetInstallChoice(entry: entry, policy: .latest, installed: installed, isBusy: false) == nil)
        let pinned = try #require(DocsetInstallChoice(entry: entry, policy: .pinnedRelease(entry.entry.releases[0].id), installed: installed, isBusy: false))
        #expect(pinned.requiresReplacement)
        #expect(pinned.target?.sourceConfigurationID == entry.sourceConfigurationID)
        #expect(DocsetInstallChoice(entry: entry, policy: .latest, installed: nil, isBusy: true) == nil)
    }

    @Test func anotherSourceInstallationCannotBecomeAReplacementChoice() throws {
        let entry = try versionedEntry()
        let first = sourced(entry, id: UUID())
        let second = sourced(entry, id: UUID())
        let choice = try #require(DocsetInstallChoice(entry: first, policy: .latest, installed: nil, isBusy: false))
        let installed = try record(target: #require(choice.target))
        let other = try #require(DocsetInstallChoice(entry: second, policy: .latest, installed: installed, isBusy: false))
        #expect(!other.requiresReplacement)
        #expect(other.installed == nil)
    }

    @Test func legacyRawInitializerRemainsUnscoped() throws {
        let choice = try #require(DocsetInstallChoice(entry: versionedEntry(), policy: .latest, installed: nil, isBusy: false))
        #expect(choice.target?.sourceConfigurationID == nil)
        #expect(choice.sourcedEntry == nil)
    }

    @Test func scopedChoiceDoesNotAdoptALegacyNilSourceInstallation() throws {
        let entry = try versionedEntry()
        let legacyChoice = try #require(DocsetInstallChoice(entry: entry, policy: .latest, installed: nil, isBusy: false))
        let legacy = try record(target: #require(legacyChoice.target))
        let item = sourced(entry, id: UUID())
        let scoped = try #require(DocsetInstallChoice(entry: item, policy: .latest, installed: legacy, isBusy: false))
        #expect(scoped.installed == nil)
        #expect(!scoped.requiresReplacement)
        #expect(scoped.target?.sourceConfigurationID == item.sourceConfigurationID)
        #expect(scoped.target?.slotKey != legacy.installTarget?.slotKey)
    }

    private func sourced(_ entry: CatalogEntry, id: UUID) -> SourcedCatalogEntry {
        SourcedCatalogEntry(source: DocsetSourceConfiguration(id: id, name: "Team", kind: .versioned(catalogURL: URL(string: "https://example.invalid/catalog.json")!, sourceId: "publisher")), entry: entry)
    }

    private func versionedEntry() throws -> CatalogEntry {
        let hash = String(repeating: "a", count: 64)
        let family = try JSONDecoder().decode(DocsetReleaseFamily.self, from: Data("""
        {"sourceId":"publisher","familyId":"python","title":"Python","identifier":"python","bundleName":"Python",
         "defaultVariantId":"python-3-en","latestReleaseId":"\(hash)","releases":[
         {"releaseId":"\(hash)","variantId":"python-3-en","versionLine":"3","language":"en","version":"3.14","revision":1,
          "identifier":"python","artifact":{"url":"https://example.invalid/\(hash).tgz","sha256":"\(hash)","bytes":100},
          "publishedAt":"2026-10-09T00:00:00.000Z","channel":"stable","support":"supported"}]}
        """.utf8))
        return CatalogEntry(name: "python", title: "Python", sourceId: "publisher", version: "3.14", revision: 1,
                            downloadURL: family.releases[0].downloadURL, keywords: [], releaseFamily: family)
    }

    private func record(target: DocsetInstallTarget) throws -> InstalledDocset {
        let descriptor = try JSONDecoder().decode(DocsetDescriptor.self, from: Data("""
        {"identifier":"installed","name":"Python","displayName":"Python","version":"3.14","keywords":[],
         "bundleURL":"file:///tmp/Python.docset","documentsURL":"file:///tmp/docs", "indexURL":"file:///tmp/index",
         "indexSchema":"dash","isJavaScriptEnabled":false}
        """.utf8))
        return InstalledDocset(descriptor: descriptor, source: .catalog(name: "python", sourceId: "publisher"),
                               advertisedVersion: target.release.advertisedVersion, installTarget: target,
                               sourceConfigurationID: target.sourceConfigurationID, sourceName: "Team")
    }
}
