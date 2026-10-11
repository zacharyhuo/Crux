import Foundation
import Testing
@testable import CruxCore

struct DocsetSourceTests {
    @Test func legacyDuplicateAndInvalidFeedsCanStillBeRevoked() async throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = try DocsetRegistry(databaseURL: root.appending(path: "library.sqlite"))
        let a = DashFeed(feedURL: URL(string: "https://a.invalid/feed.xml")!, name: "Python", version: "1", revision: 1, downloadURL: URL(string: "https://a.invalid/doc.tgz")!)
        let b = DashFeed(feedURL: URL(string: "https://b.invalid/feed.xml")!, name: "Python", version: "1", revision: 1, downloadURL: URL(string: "https://b.invalid/doc.tgz")!)
        let invalid = DashFeed(feedURL: URL(string: "https://user:example@c.invalid/feed.xml")!, name: String(repeating: "x", count: 150), version: "1", revision: 1, downloadURL: URL(string: "https://c.invalid/doc.tgz")!)
        try await registry.saveFeed(a); try await registry.saveFeed(b); try await registry.saveFeed(invalid)
        try await registry.initializeSources()
        var first = try #require(try await registry.source(id: a.id))
        first.isEnabled = false
        try await registry.saveSource(first)
        try await registry.deleteSource(id: b.id)
        let unsafe = try #require(try await registry.source(id: invalid.id))
        #expect(!unsafe.canFetch)
        try await registry.deleteSource(id: invalid.id)
        #expect(try await registry.source(id: invalid.id)?.isDeleted == true)
    }
    @Test func defaultsDoNotSilentlyUseZealAndDeletionRetainsOrigin() async throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = try DocsetRegistry(databaseURL: root.appending(path: "library.sqlite"))
        try await registry.initializeSources()
        let initial = try await registry.allSources()
        #expect(initial.count == 2)
        #expect(initial.first { $0.id == DocsetSourceConfiguration.cruxID }?.isEnabled == true)
        #expect(initial.first { $0.id == DocsetSourceConfiguration.zealID }?.isEnabled == false)
        let source = DocsetSourceConfiguration(name: "Mirror", kind: .zeal(catalogURL: URL(string: "https://mirror.invalid/catalog")!, downloadRootURL: URL(string: "https://mirror.invalid/d")!))
        try await registry.saveSource(source)
        try await registry.deleteSource(id: source.id)
        let deleted = try #require(try await registry.source(id: source.id))
        #expect(deleted.isDeleted)
        #expect(!deleted.isEnabled)
        #expect(deleted.name == "Mirror")
    }

    @Test func samePublisherAndFamilyHaveIndependentSourceSlots() throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try TestReleaseFixture.make(in: root)
        let a = try DocsetInstallTarget(entry: fixture.entry, sourceConfigurationID: UUID())
        let b = try DocsetInstallTarget(entry: fixture.entry, sourceConfigurationID: UUID())
        #expect(a.slotKey != b.slotKey)
        #expect(a.slotFileName != b.slotFileName)
        #expect(a.metadata == b.metadata)
    }

    @Test func sourceScopedVersionSwitchReplacesOnlyItsOwnInstallation() async throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = try DocsetRegistry(databaseURL: root.appending(path: "library.sqlite"))
        let old = try TestReleaseFixture.make(in: root, old: true)
        let latest = try TestReleaseFixture.make(in: root)
        let a = UUID(), b = UUID()
        let transaction = DocsetReplacementTransaction(registry: registry, docsetsDirectory: root.appending(path: "installed"))
        let aOld = try await transaction.perform(target: DocsetInstallTarget(entry: old.entry, selection: old.target.selectionPolicy, sourceConfigurationID: a), artifactAt: old.archive, sourceName: "A")
        let bOld = try await transaction.perform(target: DocsetInstallTarget(entry: old.entry, selection: old.target.selectionPolicy, sourceConfigurationID: b), artifactAt: old.archive, sourceName: "B")
        let aNew = try await transaction.perform(target: DocsetInstallTarget(entry: latest.entry, sourceConfigurationID: a), artifactAt: latest.archive, existing: aOld, sourceName: "A")
        #expect(aNew.identifier == aOld.identifier)
        #expect(aNew.descriptor.bundleURL == aOld.descriptor.bundleURL)
        #expect(aNew.descriptor.bundleIdentifier == "dev.crux.python")
        #expect(aNew.identifier != bOld.identifier)
        #expect(aNew.descriptor.version == "3.14.7")
        #expect(try await registry.installed(identifier: bOld.identifier) == bOld)
        #expect(try await registry.allInstalled().count == 2)
        let library = try await registry.allDocsets()
        let service = SymbolSearchService()
        let found = try await service.search("newAPI", in: library, limit: 20)
        #expect(!found.isEmpty)
        #expect(found.allSatisfy { $0.docsetIdentifier == aNew.identifier })
        let down = try await transaction.perform(target: DocsetInstallTarget(entry: old.entry, selection: old.target.selectionPolicy, sourceConfigurationID: a), artifactAt: old.archive, existing: aNew, sourceName: "A")
        #expect(down.identifier == aOld.identifier)
        #expect(try await registry.allInstalled().count == 2)
        _ = try await registry.scanAndRegister(docsetsDirectory: root.appending(path: "installed"), assignRuntimeIDs: true)
        #expect(try await registry.allInstalled().count == 2)
    }

    @Test func legacyOriginMigrationIsIdempotentAndDoesNotMoveOrRenameDocuments() async throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try TestDocsetFixture.create(in: root)
        let registry = try DocsetRegistry(databaseURL: root.appending(path: "library.sqlite"))
        let parsed = try DocsetParser().parse(bundleAt: bundle)
        try await registry.upsert(InstalledDocset(descriptor: parsed, source: .catalog(name: "Python", sourceId: "com.kapeli"), advertisedVersion: DocsetVersion(descriptor: parsed)))
        try await registry.initializeSources()
        let record = try #require(try await registry.allInstalled().first)
        #expect(record.identifier == "org.python.Python")
        #expect(record.descriptor.bundleURL == bundle)
        #expect(record.sourceConfigurationID == DocsetSourceConfiguration.legacyID)
        #expect(try await registry.source(id: DocsetSourceConfiguration.legacyID)?.canFetch == false)
        try await registry.initializeSources(legacyCatalogSourceID: DocsetSourceConfiguration.zealID)
        #expect(try await registry.allInstalled() == [record])
    }
}
