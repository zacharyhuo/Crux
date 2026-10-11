import AppKit
import CruxCore
import Foundation
import SQLite3
import Testing
import WebKit

@testable import Crux

/// Sandboxed coverage of import, uninstall and catalog-driven update detection.
@MainActor
@Suite(.serialized)
struct LibraryLifecycleTests {
    private func withModel(
        catalog: [CatalogEntry] = [],
        catalogClient: (any CatalogClient)? = nil,
        downloadClient: (any DownloadClient)? = nil,
        _ body: (AppModel, URL) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "CruxLibraryTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = AppDirectoryLayout(applicationSupportDirectory: root)
        try FileManager.default.createDirectory(at: layout.defaultDocsetsDirectory, withIntermediateDirectories: true)

        let preferences = ReaderPreferences(defaults: try #require(UserDefaults(suiteName: root.lastPathComponent)))
        let snapshot = CatalogSnapshot(entries: catalog, fetchedAt: Date(), isFromCache: true)
        let model = AppModel(
            preferences: preferences,
            layout: layout,
            catalogClient: catalogClient ?? StaticCatalogClient(snapshot: snapshot),
            downloadClient: downloadClient ?? FailingDownloadClient()
        )
        await model.bootstrap()
        do {
            try await body(model, root)
            await model.shutdown()
        } catch {
            await model.shutdown()
            throw error
        }
    }

    @Test
    func confirmationSnapshotCannotInstallAReleaseWithdrawnByCatalogRefresh() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "CruxWithdrawn-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try VersionedLibraryFixture.make(in: root)
        let cached = CatalogSnapshot(entries: [fixture.entry], fetchedAt: .now, isFromCache: true)
        let empty = CatalogSnapshot(entries: [], fetchedAt: .now, isFromCache: false)
        let catalog = RefreshingCatalogClient(cached: cached, refreshed: empty)
        try await withModel(catalogClient: catalog, downloadClient: VersionedLibraryDownloadClient(files: fixture.downloads)) { model, _ in
            let choice = try #require(DocsetInstallChoice(entry: fixture.entry, policy: .latest, installed: nil, isBusy: false))
            await model.refreshCatalog()
            await model.installCatalogEntry(choice.entry, selection: choice.policy)
            #expect(model.transferJobs.isEmpty)
            #expect(model.libraryError != nil)
        }
    }

    @Test
    func uninstallCannotRemoveTheOldVersionDuringAReplacementDownload() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "CruxBusy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try VersionedLibraryFixture.make(in: root)
        let downloads = PausedVersionDownloadClient(files: fixture.downloads)
        try await withModel(catalog: [fixture.entry], downloadClient: downloads) { model, _ in
            await model.installCatalogEntry(fixture.entry, selection: .pinnedRelease(VersionedLibraryFixture.oldID))
            try await waitUntil { model.installed.count == 1 }
            let previous = try #require(model.installed.first)
            await downloads.pause()
            await model.installCatalogEntry(fixture.entry)
            try await waitUntil { model.isTransferring(fixture.entry) }
            await model.uninstall(previous)
            #expect(model.installed == [previous])
            #expect(FileManager.default.fileExists(atPath: previous.descriptor.bundleURL.path))
            #expect(model.libraryError != nil)
            await downloads.resume()
            try await waitUntil { model.installed.first?.installTarget?.release.id == VersionedLibraryFixture.latestID }
        }
    }

    @Test
    func pinnedVersionSurvivesUpdateAllAndFailedSwitchWithoutChangingTheReader() async throws {
        let fixtureRoot = FileManager.default.temporaryDirectory.appending(path: "CruxVersionFixtures-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        let fixture = try VersionedLibraryFixture.make(in: fixtureRoot)
        let client = VersionedLibraryDownloadClient(files: fixture.downloads)
        try await withModel(catalog: [fixture.entry], downloadClient: client) { model, _ in
            await model.installCatalogEntry(fixture.entry, selection: .pinnedRelease(VersionedLibraryFixture.oldID))
            try await waitUntil { model.installed.first?.installTarget?.release.id == VersionedLibraryFixture.oldID }
            let original = try #require(model.installed.first)
            model.open(ReaderLocation(docsetIdentifier: original.identifier, relativePath: "old-only.html"))
            let tab = try #require(model.selectedTab)
            #expect(model.availableUpdates.isEmpty)
            let count = model.transferJobs.count
            await model.updateAllDocsets()
            #expect(model.transferJobs.count == count)
            await client.failDownloads()
            await model.installCatalogEntry(fixture.entry, selection: .latest)
            try await waitUntil { model.transferJobs.contains { if case .failed = $0.status { true } else { false } } }
            #expect(model.installed == [original])
            #expect(model.selectedTab?.id == tab.id)
            #expect(tab.currentLocation?.relativePath == "old-only.html")
            let reopened = try DocsetRegistry(databaseURL: model.layout.databaseURL)
            #expect(try await reopened.allInstalled() == [original])
        }
    }

    @Test(arguments: ["index.html", "old-only.html"])
    func switchingVersionReloadsSurvivingPagesOrFallsBackToTheNewHome(_ path: String) async throws {
        let fixtureRoot = FileManager.default.temporaryDirectory.appending(path: "CruxVersionFixtures-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        let fixture = try VersionedLibraryFixture.make(in: fixtureRoot)
        let client = VersionedLibraryDownloadClient(files: fixture.downloads)
        try await withModel(catalog: [fixture.entry], downloadClient: client) { model, _ in
            await model.installCatalogEntry(fixture.entry, selection: .pinnedRelease(VersionedLibraryFixture.oldID))
            try await waitUntil { model.installed.first?.installTarget?.release.id == VersionedLibraryFixture.oldID }
            let old = try #require(model.docsets.first)
            await model.enableFullTextSearch(for: old)
            let oldSignature = model.fullTextStates[old.identifier]?.contentSignature
            model.open(ReaderLocation(docsetIdentifier: old.identifier, relativePath: path))
            let tab = try #require(model.selectedTab)
            try await waitUntil { tab.webView.title == "Old Python" }
            await model.installCatalogEntry(fixture.entry, selection: .latest)
            try await waitUntil { model.installed.first?.installTarget?.release.id == VersionedLibraryFixture.latestID && tab.webView.title == "Latest Python" }
            #expect(model.installed.count == 1)
            #expect(model.installed.first?.selectionPolicy == .latest)
            #expect(model.selectedTab?.id == tab.id)
            #expect(tab.currentLocation?.relativePath == "index.html")
            if path == "old-only.html" { #expect(model.libraryNotice != nil) }
            try await waitUntil { model.fullTextStates[old.identifier]?.phase == .ready && model.fullTextStates[old.identifier]?.contentSignature != oldSignature }
            #expect(try await model.searchFullText("OldOnlyContent", in: model.docsets, limit: 10).isEmpty)
            #expect(try await model.searchFullText("LatestOnlyContent", in: model.docsets, limit: 10).count > 0)
            let newSignature = model.fullTextStates[old.identifier]?.contentSignature
            // A delayed action still holding the old descriptor cannot rebuild
            // over the new version's index after the replacement completed.
            await model.rebuildFullTextIndex(for: old)
            #expect(model.fullTextStates[old.identifier]?.contentSignature == newSignature)
        }
    }

    @Test
    func importingALocalBundleRegistersItWithoutConsumingTheSource() async throws {
        try await withModel { model, root in
            let source = root.appending(path: "source", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            let bundle = try makeDocset(in: source, name: "Imported", identifier: "dev.crux.imported")

            await model.importDocsets(at: [bundle])
            try await waitUntil { model.installed.contains { $0.identifier == "dev.crux.imported" } }

            let record = try #require(model.installed.first)
            #expect(record.source == .localImport)
            #expect(record.isReachable)
            #expect(FileManager.default.fileExists(atPath: bundle.path))
            #expect(model.docsets.map(\.identifier) == ["dev.crux.imported"])
        }
    }

    @Test
    func uninstallRequiresTheModelToDropSearchAndRegistryState() async throws {
        try await withModel { model, root in
            let bundle = try makeDocset(
                in: model.layout.defaultDocsetsDirectory,
                name: "Doomed",
                identifier: "dev.crux.doomed"
            )
            await model.refreshLibrary()
            #expect(model.installed.map(\.identifier) == ["dev.crux.doomed"])

            let record = try #require(model.installed.first)
            model.open(ReaderLocation(
                docsetIdentifier: record.identifier,
                relativePath: "index.html"
            ))
            await model.uninstall(record)

            #expect(model.installed.isEmpty)
            #expect(model.docsets.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: bundle.path))
            #expect(model.tabs.count == 1)
            #expect(model.selectedTab?.isWelcome == true)
        }
    }

    @Test
    func updateCheckerSurfacesANewerCatalogRevision() async throws {
        let newer = CatalogEntry(
            name: "Python_3",
            title: "Python 3",
            sourceId: "com.kapeli",
            version: "3.14.0",
            revision: 2,
            downloadURL: URL(string: "https://go.zealdocs.org/d/com.kapeli/Python_3/latest")!,
            keywords: []
        )
        try await withModel(catalog: [newer]) { model, root in
            let bundle = try makeDocset(
                in: model.layout.defaultDocsetsDirectory,
                name: "Python",
                identifier: "org.python.Python"
            )
            await model.refreshLibrary()
            var record = try #require(model.installed.first)
            record.source = .catalog(name: "Python_3", sourceId: "com.kapeli")
            record.advertisedVersion = DocsetVersion(version: "3.13.0", revision: 1)
            // The test talks to the live registry through import/refresh; stamp
            // the catalog source the same way a completed download would.
            let registry = try DocsetRegistry(databaseURL: model.layout.databaseURL)
            _ = try await registry.upsert(record)
            await model.refreshLibrary()

            #expect(model.availableUpdates[record.identifier] != nil)
            #expect(FileManager.default.fileExists(atPath: bundle.path))
        }
    }

    @Test
    func refreshIfNeededRepairsAnExplicitlyLegacyArtworkCache() async throws {
        let legacy = makeCatalogEntry(name: "Java", title: "Java", iconData: nil)
        let refreshed = makeCatalogEntry(name: "Java", title: "Java", iconData: Self.samplePNG)
        let client = RefreshingCatalogClient(
            cached: CatalogSnapshot(
                entries: [legacy],
                fetchedAt: .distantPast,
                isFromCache: true,
                requiresArtworkRefresh: true
            ),
            refreshed: CatalogSnapshot(entries: [refreshed], fetchedAt: Date(), isFromCache: false)
        )

        try await withModel(catalogClient: client) { model, _ in
            #expect(await client.fetchCount == 0)
            await model.refreshCatalogIfNeeded()
            try await waitUntil { model.catalog.first?.iconData == Self.samplePNG }

            #expect(model.catalog.first?.iconData == Self.samplePNG)
            #expect(await client.fetchCount == 1)
        }
    }

    @Test
    func bootstrapKeepsCatalogLoadingLazyWhenThereIsNoCache() async throws {
        let fresh = makeCatalogEntry(name: "Java", title: "Java", iconData: Self.samplePNG)
        let client = RefreshingCatalogClient(
            cached: CatalogSnapshot(entries: [], fetchedAt: .distantPast, isFromCache: true),
            refreshed: CatalogSnapshot(entries: [fresh], fetchedAt: Date(), isFromCache: false)
        )

        try await withModel(catalogClient: client) { _, _ in
            #expect(await client.fetchCount == 0)
        }
    }

    @Test
    func localImportsCanUseMatchingCatalogArtwork() async throws {
        let catalog = makeCatalogEntry(name: "Java", title: "Java", iconData: Self.samplePNG)

        try await withModel(catalog: [catalog]) { model, _ in
            _ = try makeDocset(
                in: model.layout.defaultDocsetsDirectory,
                name: "Java",
                identifier: "java"
            )
            await model.refreshLibrary()
            let descriptor = try #require(model.docsets.first)

            #expect(model.catalogIconData(forDocset: descriptor.identifier) == Self.samplePNG)
        }
    }

    @Test
    func localImportArtworkPrefersAnExactNameOverAnEarlierSharedKeyword() async throws {
        let generic = makeCatalogEntry(
            name: "Java_EE6",
            title: "Java EE6",
            iconData: Data([0x01]),
            keywords: ["java"]
        )
        let exact = makeCatalogEntry(
            name: "Java_SE25",
            title: "Java SE25",
            iconData: Data([0x02]),
            keywords: ["java"]
        )

        try await withModel(catalog: [generic, exact]) { model, _ in
            _ = try makeDocset(
                in: model.layout.defaultDocsetsDirectory,
                name: "Java SE25",
                identifier: "java"
            )
            await model.refreshLibrary()
            let descriptor = try #require(model.docsets.first)

            #expect(model.catalogIconData(forDocset: descriptor.identifier) == Data([0x02]))
        }
    }

    @Test
    func localImportArtworkPreservesMeaningfulNamePunctuation() async throws {
        let c = makeCatalogEntry(name: "C", title: "C", iconData: Data([0x01]))
        let cpp = makeCatalogEntry(name: "C++", title: "C++", iconData: Data([0x02]))

        try await withModel(catalog: [c, cpp]) { model, _ in
            _ = try makeDocset(
                in: model.layout.defaultDocsetsDirectory,
                name: "C++",
                identifier: "cpp"
            )
            await model.refreshLibrary()
            let descriptor = try #require(model.docsets.first)

            #expect(model.catalogIconData(forDocset: descriptor.identifier) == Data([0x02]))
        }
    }

    @Test
    func iconlessLocalDocsetsReceiveDistinctGeneratedArtwork() async throws {
        try await withModel { model, _ in
            _ = try makeDocset(
                in: model.layout.defaultDocsetsDirectory,
                name: "Java",
                identifier: "java"
            )
            _ = try makeDocset(
                in: model.layout.defaultDocsetsDirectory,
                name: "Python",
                identifier: "python"
            )
            await model.refreshLibrary()
            let java = try #require(model.docsets.first { $0.identifier == "java" })
            let python = try #require(model.docsets.first { $0.identifier == "python" })
            let javaIcon = try #require(DocsetIconResolver.image(for: java))
            let pythonIcon = try #require(DocsetIconResolver.image(for: python))

            #expect(javaIcon.tiffRepresentation != pythonIcon.tiffRepresentation)
        }
    }


    @Test
    func confirmedStorageCleanupTrashesOnlyTheCopiedBundles() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "CruxTrashTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let docset = root.appending(path: "Swift.docset", directoryHint: .isDirectory)
        let unrelated = root.appending(path: "personal-notes.txt")
        try FileManager.default.createDirectory(at: docset, withIntermediateDirectories: true)
        try Data("keep me".utf8).write(to: unrelated)
        let recorder = TrashRecorder()
        let model = AppModel(
            layout: AppDirectoryLayout(applicationSupportDirectory: root.appending(path: "AppSupport")),
            trashItem: { recorder.record($0) }
        )
        model.pendingTrashItems = [docset]

        model.trashPendingStorageCopy()

        #expect(recorder.urls == [docset])
        #expect(!recorder.urls.contains(root))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
    }

    private func waitUntil(timeout: Duration = .seconds(5), _ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock().now + timeout
        while ContinuousClock().now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        Issue.record("Timed out waiting for the expected library state.")
    }

    private func makeDocset(in directory: URL, name: String, identifier: String) throws -> URL {
        let bundleURL = directory.appending(path: "\(name).docset", directoryHint: .isDirectory)
        let resourcesURL = bundleURL.appending(path: "Contents/Resources", directoryHint: .isDirectory)
        let documentsURL = resourcesURL.appending(path: "Documents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: documentsURL, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": identifier,
            "CFBundleName": name,
            "CFBundleShortVersionString": "1.0",
            "dashIndexFilePath": "index.html",
        ]
        try PropertyListSerialization
            .data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: bundleURL.appending(path: "Contents/Info.plist", directoryHint: .notDirectory))
        try Data("<html>index</html>".utf8)
            .write(to: documentsURL.appending(path: "index.html", directoryHint: .notDirectory))

        var handle: OpaquePointer?
        let indexPath = resourcesURL.appending(path: "docSet.dsidx", directoryHint: .notDirectory).path
        guard sqlite3_open(indexPath, &handle) == SQLITE_OK, let database = handle else {
            throw TestError.couldNotCreateIndex
        }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(
            database,
            "CREATE TABLE searchIndex(id INTEGER PRIMARY KEY, name TEXT, type TEXT, path TEXT)",
            nil, nil, nil
        ) == SQLITE_OK else {
            throw TestError.couldNotCreateIndex
        }
        return bundleURL
    }

    private enum TestError: Error {
        case couldNotCreateIndex
    }

    private static let samplePNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9WlS5b8AAAAASUVORK5CYII="
    )!

    private func makeCatalogEntry(
        name: String,
        title: String,
        iconData: Data?,
        keywords: [String]? = nil
    ) -> CatalogEntry {
        CatalogEntry(
            name: name,
            title: title,
            sourceId: "com.kapeli",
            version: "1.0",
            revision: 1,
            downloadURL: URL(string: "https://go.zealdocs.org/d/com.kapeli/\(name)/latest")!,
            keywords: keywords ?? [name.lowercased()],
            iconData: iconData
        )
    }
}

private final class TrashRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL] = []

    var urls: [URL] { lock.withLock { storage } }

    func record(_ url: URL) {
        lock.withLock { storage.append(url) }
    }
}

private struct StaticCatalogClient: CatalogClient {
    let snapshot: CatalogSnapshot

    func fetch(forceRefresh: Bool) async throws -> CatalogSnapshot { snapshot }
    func cachedSnapshot() async -> CatalogSnapshot? { snapshot }
}

private actor RefreshingCatalogClient: CatalogClient {
    let cached: CatalogSnapshot
    let refreshed: CatalogSnapshot
    private(set) var fetchCount = 0

    init(cached: CatalogSnapshot, refreshed: CatalogSnapshot) {
        self.cached = cached
        self.refreshed = refreshed
    }

    func fetch(forceRefresh: Bool) async throws -> CatalogSnapshot {
        fetchCount += 1
        return refreshed
    }

    func cachedSnapshot() async -> CatalogSnapshot? { cached }
}

private struct FailingDownloadClient: DownloadClient {
    func download(
        from url: URL,
        to destinationURL: URL,
        progress: @escaping @Sendable (Int64, Int64?) -> Void
    ) async throws {
        throw TransferError.insecureDownloadURL(url)
    }
}

private actor PausedVersionDownloadClient: DownloadClient {
    let files: [URL: Data]
    var paused = false
    var waiters: [CheckedContinuation<Void, Never>] = []
    init(files: [URL: Data]) { self.files = files }
    func pause() { paused = true }
    func resume() {
        paused = false
        let ready = waiters
        waiters = []
        ready.forEach { $0.resume() }
    }
    func download(from url: URL, to destinationURL: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws {
        if paused { await withCheckedContinuation { waiters.append($0) } }
        guard let bytes = files[url] else { throw URLError(.resourceUnavailable) }
        try bytes.write(to: destinationURL)
    }
}
