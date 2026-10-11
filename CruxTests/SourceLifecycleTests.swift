import CruxCore
import Foundation
import Testing
@testable import Crux

@MainActor struct SourceLifecycleTests {
    @Test func installedOriginRemainsVisibleAfterDisableDeleteAndRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "CruxOriginLifecycle-\(UUID().uuidString)")
        let defaults = try #require(UserDefaults(suiteName: root.lastPathComponent))
        defer {
            defaults.removePersistentDomain(forName: root.lastPathComponent)
            try? FileManager.default.removeItem(at: root)
        }
        let layout = AppDirectoryLayout(applicationSupportDirectory: root)
        let registry = try DocsetRegistry(databaseURL: layout.databaseURL)
        try await registry.initializeSources()
        for var source in try await registry.allSources() {
            source.isEnabled = false
            try await registry.saveSource(source)
        }
        var mirror = source("SavedMirror")
        mirror.name = "Saved Mirror"
        try await registry.saveSource(mirror)
        let fixture = try VersionedLibraryFixture.make(in: root.appending(path: "fixtures"))
        let target = try DocsetInstallTarget(entry: fixture.entry, sourceConfigurationID: mirror.id)
        let archive = root.appending(path: "python.tgz")
        try #require(fixture.downloads[target.release.downloadURL]).write(to: archive)
        let original = try await DocsetReplacementTransaction(registry: registry, docsetsDirectory: layout.defaultDocsetsDirectory)
            .perform(target: target, artifactAt: archive, sourceName: mirror.name)
        let model = AppModel(preferences: ReaderPreferences(defaults: defaults), layout: layout)
        await model.bootstrap()
        #expect(!model.showsInstalledSourceNames)
        #expect(model.docsetDisplayName(for: original.descriptor) == "Python")
        await model.setSourceEnabled(mirror, enabled: false)
        #expect(model.showsInstalledSourceNames)
        #expect(model.docsetDisplayName(for: original.descriptor) == "Python（Saved Mirror）")
        await model.deleteSource(mirror)
        #expect(!model.sources.contains { $0.id == mirror.id })
        #expect(model.docsetDisplayName(for: original.descriptor) == "Python（Saved Mirror）")
        #expect(try await registry.installed(identifier: original.identifier) == original)
        // Another single enabled source must not erase this installation's origin.
        try await registry.saveSource(DocsetSourceConfiguration.defaults[0])
        try await model.sourceLibrary?.reload()
        #expect(model.enabledSourceCount == 1)
        #expect(model.showsInstalledSourceNames)
        #expect(model.docsetDisplayName(for: original.descriptor) == "Python（Saved Mirror）")
        await model.shutdown()

        let restarted = AppModel(preferences: ReaderPreferences(defaults: defaults), layout: layout)
        await restarted.bootstrap()
        #expect(restarted.installed == [original])
        #expect(restarted.docsetDisplayName(for: original.descriptor) == "Python（Saved Mirror）")
        #expect(restarted.searchDocsetTitle(for: original.descriptor)?.contains("Saved Mirror") == true)
        await restarted.shutdown()
    }

    @Test func missingSourceConfigurationStillUsesInstallationSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "CruxMissingOrigin-\(UUID().uuidString)")
        let defaults = try #require(UserDefaults(suiteName: root.lastPathComponent))
        defer {
            defaults.removePersistentDomain(forName: root.lastPathComponent)
            try? FileManager.default.removeItem(at: root)
        }
        let layout = AppDirectoryLayout(applicationSupportDirectory: root)
        let registry = try DocsetRegistry(databaseURL: layout.databaseURL)
        try await registry.initializeSources()
        let fixture = try VersionedLibraryFixture.make(in: root.appending(path: "fixtures"))
        let originID = UUID()
        let target = try DocsetInstallTarget(entry: fixture.entry, sourceConfigurationID: originID)
        let archive = root.appending(path: "python.tgz")
        try #require(fixture.downloads[target.release.downloadURL]).write(to: archive)
        let original = try await DocsetReplacementTransaction(registry: registry, docsetsDirectory: layout.defaultDocsetsDirectory)
            .perform(target: target, artifactAt: archive, sourceName: "Original Mirror")
        let model = AppModel(preferences: ReaderPreferences(defaults: defaults), layout: layout)
        await model.bootstrap()
        #expect(model.sources.allSatisfy { $0.id != originID })
        #expect(model.installed == [original])
        #expect(model.sourceDisplayName(for: original) == "Original Mirror")
        #expect(model.docsetDisplayName(for: original.descriptor) == "Python（Original Mirror）")
        #expect(model.showsInstalledSourceNames)
        await model.shutdown()
    }

    @Test func editorSaveDisablesAndCancelsTheSourcesDownload() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "CruxSourceLifecycle-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = AppDirectoryLayout(applicationSupportDirectory: root)
        let registry = try DocsetRegistry(databaseURL: layout.databaseURL)
        try await registry.initializeSources()
        for var source in try await registry.allSources() {
            source.isEnabled = false
            try await registry.saveSource(source)
        }
        var mirror = source("Mirror")
        try await registry.saveSource(mirror)
        let downloads = SuspendedSourceDownload()
        let defaults = try #require(UserDefaults(suiteName: root.lastPathComponent))
        let model = AppModel(preferences: ReaderPreferences(defaults: defaults), layout: layout,
            sourceCatalogOverrides: [mirror.id: ImmediateSourceCatalog()], downloadClient: downloads)
        await model.bootstrap()
        await model.refreshCatalog()
        let item = try #require(model.availableDocsets.first)
        await model.installCatalogEntry(item)
        try await waitUntil { await downloads.started }
        mirror.isEnabled = false
        await model.saveSource(mirror)
        try await waitUntil { model.transferJobs.contains { $0.status == .cancelled } }
        #expect(model.installed.isEmpty)
        #expect(model.availableDocsets.isEmpty)
        #expect(model.sources.first { $0.id == mirror.id }?.isEnabled == false)
        await model.shutdown()
    }

    @Test func healthySourcePublishesBeforeAHungRefreshCompletes() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "CruxSourceRefresh-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = try DocsetRegistry(databaseURL: root.appending(path: "library.sqlite"))
        let slow = source("Slow"), healthy = source("Healthy")
        try await registry.saveSource(slow); try await registry.saveSource(healthy)
        let gate = SuspendedSourceCatalogClient()
        let library = SourceLibrary(registry: registry, cacheDirectory: root,
            catalogOverrides: [slow.id: gate, healthy.id: ImmediateSourceCatalog()])
        try await library.reload()
        let refresh = Task { await library.refreshAll() }
        try await waitUntil { await gate.started }
        try await waitUntil { library.entries.contains { $0.sourceConfigurationID == healthy.id } }
        #expect(library.states[healthy.id]?.isRefreshing == false)
        #expect(library.states[slow.id]?.isRefreshing == true)
        await gate.release()
        await refresh.value
    }

    private func source(_ name: String) -> DocsetSourceConfiguration {
        DocsetSourceConfiguration(name: name, kind: .zeal(catalogURL: URL(string: "https://\(name.lowercased()).invalid/catalog")!, downloadRootURL: URL(string: "https://\(name.lowercased()).invalid/d")!))
    }
    private func waitUntil(_ predicate: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await predicate()) {
            guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private struct ImmediateSourceCatalog: CatalogClient {
    func fetch(forceRefresh: Bool) async throws -> CatalogSnapshot { Self.snapshot }
    func cachedSnapshot() async -> CatalogSnapshot? { nil }
    static var snapshot: CatalogSnapshot { CatalogSnapshot(entries: [CatalogEntry(name: "Python", title: "Python", sourceId: "com.kapeli", version: "3.14", revision: 1,
        downloadURL: URL(string: "https://mirror.invalid/d/com.kapeli/Python/latest")!, keywords: ["py"])], fetchedAt: Date(), isFromCache: false) }
}
private actor SuspendedSourceCatalogClient: CatalogClient {
    var started = false
    private var continuation: CheckedContinuation<CatalogSnapshot, Never>?
    func fetch(forceRefresh: Bool) async throws -> CatalogSnapshot {
        started = true
        return await withCheckedContinuation { continuation = $0 }
    }
    func cachedSnapshot() async -> CatalogSnapshot? { nil }
    func release() { continuation?.resume(returning: ImmediateSourceCatalog.snapshot); continuation = nil }
}
private actor SuspendedSourceDownload: DownloadClient {
    var started = false
    private var continuation: CheckedContinuation<Void, any Error>?
    func download(from url: URL, to destination: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws {
        try await withTaskCancellationHandler {
            started = true
            try await withCheckedThrowingContinuation { continuation = $0 }
        } onCancel: { Task { await self.cancel() } }
    }
    private func cancel() { continuation?.resume(throwing: CancellationError()); continuation = nil }
}
