import Foundation
import SQLite3
import Testing

@testable import CruxCore

struct DocsetRegistryTests {
    @Test func reopensAnInstalledLibraryAfterABriefConcurrentWrite() async throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appending(path: "Crux.sqlite")
        let bundle = try TestDocsetFixture.create(in: root)
        let original = try DocsetRegistry(databaseURL: databaseURL)
        let descriptor = try await original.register(bundleAt: bundle)
        var connection: OpaquePointer?
        try #require(sqlite3_open(databaseURL.path, &connection) == SQLITE_OK)
        let writer = try #require(connection)
        defer {
            sqlite3_exec(writer, "ROLLBACK", nil, nil, nil)
            sqlite3_close(writer)
        }
        try #require(sqlite3_exec(writer, "BEGIN EXCLUSIVE TRANSACTION", nil, nil, nil) == SQLITE_OK)
        let started = ReopenArrival()
        let reopening = Task.detached {
            await started.signal()
            return Result { try DocsetRegistry(databaseURL: databaseURL) }
        }
        await started.wait()
        // Keep a real second connection's short transaction alive while the
        // reader opens; this reproduces the observed SQLite startup lock.
        try await Task.sleep(for: .milliseconds(150))
        try #require(sqlite3_exec(writer, "COMMIT", nil, nil, nil) == SQLITE_OK)
        let reopened = try await reopening.value.get()
        #expect(try await reopened.allDocsets() == [descriptor])
    }

    @Test
    func persistsTrustedSlotsAndPinsAcrossReopenScanAndStorageMigration() async throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try TestReleaseFixture.make(in: root, old: true)
        let descriptor = try DocsetParser().parse(bundleAt: fixture.bundle)
        let record = InstalledDocset(descriptor: descriptor, source: .catalog(name: "python", sourceId: "dev.crux"),
                                     advertisedVersion: fixture.target.release.advertisedVersion,
                                     selectionPolicy: fixture.target.selectionPolicy, installTarget: fixture.target)
        let databaseURL = root.appending(path: "Crux.sqlite")
        let registry = try DocsetRegistry(databaseURL: databaseURL)
        try await registry.upsert(record)
        let reopened = try DocsetRegistry(databaseURL: databaseURL)
        #expect(try await reopened.installed(sourceId: "dev.crux", familyId: "python") == record)
        _ = try await reopened.scanAndRegister(docsetsDirectory: fixture.bundle.deletingLastPathComponent())
        #expect(try await reopened.allInstalled() == [record])
        let destination = root.appending(path: "relocated")
        let result = try await StorageMigrator().migrate(records: [record], from: fixture.bundle.deletingLastPathComponent(),
                                                        to: destination, trashSourceAfterSwitch: false)
        try await reopened.applyStorageMigration(records: result.records, settings: LibrarySettings(customDocsetsPath: destination.path))
        let moved = try #require(try await reopened.installed(sourceId: "dev.crux", familyId: "python"))
        #expect(moved.selectionPolicy == .pinnedRelease(String(repeating: "1", count: 64)))
        #expect(moved.installTarget == record.installTarget)
        #expect(moved.descriptor.bundleURL.deletingLastPathComponent().path == destination.path)
    }

    @Test
    func refusesToAdoptAnUntrustedInstallOnlyBecauseItsIdentifierMatches() async throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try TestReleaseFixture.make(in: root)
        let registry = try DocsetRegistry(databaseURL: root.appending(path: "Crux.sqlite"))
        let descriptor = try await registry.register(bundleAt: fixture.bundle)
        let before = try await registry.allInstalled()
        await #expect(throws: (any Error).self) {
            try await registry.upsert(InstalledDocset(descriptor: descriptor,
                source: .catalog(name: "python", sourceId: "dev.crux"), advertisedVersion: fixture.target.release.advertisedVersion,
                installTarget: fixture.target))
        }
        #expect(try await registry.allInstalled() == before)
        #expect(try await registry.installed(sourceId: "dev.crux", familyId: "python") == nil)
    }

    @Test
    func concurrentReadsReturnValueSnapshotsRatherThanDatabaseRows() async throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try TestDocsetFixture.create(in: root)
        let registry = try DocsetRegistry(databaseURL: root.appending(path: "Crux.sqlite"))
        let descriptor = try await registry.register(bundleAt: bundle)

        async let listed = registry.allInstalled()
        async let found = registry.installed(identifier: descriptor.identifier)
        let (snapshot, record) = try await (listed, found)

        #expect(snapshot.count == 1)
        #expect(record == snapshot.first)
        #expect(record?.descriptor == descriptor)
        #expect(record?.source == .localImport)
    }

    @Test
    func persistsRegisteredDocsetsAcrossRegistryInstances() async throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try TestDocsetFixture.create(in: root)
        let databaseURL = root.appending(path: "Crux.sqlite")

        let registry = try DocsetRegistry(databaseURL: databaseURL)
        let registered = try await registry.register(bundleAt: bundle)
        let reopened = try DocsetRegistry(databaseURL: databaseURL)
        let stored = try await reopened.allDocsets()

        #expect(registered.identifier == "org.python.Python")
        #expect(stored == [registered])
    }

    @Test
    func invalidDocsetsNeverPolluteTheRegistry() async throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let invalidBundle = try TestDocsetFixture.create(in: root, schema: .incompatible)
        let registry = try DocsetRegistry(databaseURL: root.appending(path: "Crux.sqlite"))

        await #expect(throws: DocsetParseError.self) {
            try await registry.register(bundleAt: invalidBundle)
        }
        #expect(try await registry.allDocsets().isEmpty)
    }

    @Test
    func scansAStorageRootAndReportsInvalidBundlesSeparately() async throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try TestDocsetFixture.create(in: root, name: "Python")
        _ = try TestDocsetFixture.create(in: root, name: "Broken", schema: .incompatible)
        let registry = try DocsetRegistry(databaseURL: root.appending(path: "Crux.sqlite"))

        let report = try await registry.scanAndRegister(docsetsDirectory: root)

        #expect(report.registered.map(\.name) == ["Python"])
        #expect(report.failures.count == 1)
        #expect(report.failures[0].bundleURL.lastPathComponent == "Broken.docset")
        #expect(try await registry.allDocsets().map(\.name) == ["Python"])
    }

    @Test
    func scanDoesNotDropUnreachableRegisteredDocsets() async throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let stored = root.appending(path: "stored", directoryHint: .isDirectory)
        let empty = root.appending(path: "empty", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: stored, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let bundle = try TestDocsetFixture.create(in: stored, name: "Python")
        let registry = try DocsetRegistry(databaseURL: root.appending(path: "Crux.sqlite"))
        _ = try await registry.register(bundleAt: bundle)

        let report = try await registry.scanAndRegister(docsetsDirectory: empty)

        #expect(report.registered.isEmpty)
        #expect(try await registry.allDocsets().map(\.name) == ["Python"])
    }

    @Test
    func appliesRelocatedRecordsAndStorageSettingsTogether() async throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let oldRoot = root.appending(path: "old", directoryHint: .isDirectory)
        let newRoot = root.appending(path: "new", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: oldRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newRoot, withIntermediateDirectories: true)
        let originalBundle = try TestDocsetFixture.create(in: oldRoot, name: "Swift")
        let relocatedBundle = newRoot.appending(path: originalBundle.lastPathComponent, directoryHint: .isDirectory)
        try FileManager.default.copyItem(at: originalBundle, to: relocatedBundle)
        let relocated = try DocsetParser().parse(bundleAt: relocatedBundle)
        let record = InstalledDocset(
            descriptor: relocated,
            source: .localImport,
            advertisedVersion: DocsetVersion(descriptor: relocated)
        )
        let settings = LibrarySettings(customDocsetsPath: newRoot.path, bookmarkData: nil)
        let registry = try DocsetRegistry(databaseURL: root.appending(path: "Crux.sqlite"))

        try await registry.applyStorageMigration(records: [record], settings: settings)

        #expect(try await registry.allInstalled() == [record])
        #expect(try await registry.loadSettings() == settings)
    }
}

private actor ReopenArrival {
    private var arrived = false
    private var waiter: CheckedContinuation<Void, Never>?
    func signal() { arrived = true; waiter?.resume(); waiter = nil }
    func wait() async {
        if !arrived { await withCheckedContinuation { waiter = $0 } }
    }
}
