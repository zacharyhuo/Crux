import Foundation
import Testing
@testable import CruxCore

struct SourceTransferTests {
    @Test func reimportRetainsTheMigratedLegacyRawRuntimeID() async throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = try DocsetRegistry(databaseURL: root.appending(path: "library.sqlite"))
        let latest = try TestReleaseFixture.make(in: root)
        let old = try TestReleaseFixture.make(in: root, old: true)
        let layout = AppDirectoryLayout(applicationSupportDirectory: root.appending(path: "app"))
        try FileManager.default.createDirectory(at: layout.defaultDocsetsDirectory, withIntermediateDirectories: true)
        let installed = layout.defaultDocsetsDirectory.appending(path: "Python.docset")
        try FileManager.default.copyItem(at: latest.bundle, to: installed)
        let original = try await registry.register(bundleAt: installed)
        try await registry.initializeSources()
        let queue = TransferQueue(downloadClient: ForbiddenDownload(), registry: registry, layout: layout)
        var request = TransferRequest.importing(fileURL: old.bundle)
        request.sourceConfigurationID = DocsetSourceConfiguration.localID
        request.sourceName = "Local Imports"
        _ = await queue.enqueue(request)
        try await finished(queue)
        let records = try await registry.allInstalled()
        #expect(records.count == 1)
        #expect(records.first?.identifier == original.identifier)
        #expect(records.first?.descriptor.bundleURL == original.bundleURL)
        #expect(records.first?.descriptor.version == "3.13.9")
    }
    @Test func identicalDownloadsFromDifferentSourcesInstallIndependently() async throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = try DocsetRegistry(databaseURL: root.appending(path: "library.sqlite"))
        let fixture = try TestReleaseFixture.make(in: root)
        let a = source("A", endpoint: "a"), b = source("B", endpoint: "b")
        try await registry.saveSource(a); try await registry.saveSource(b)
        let layout = AppDirectoryLayout(applicationSupportDirectory: root.appending(path: "app"))
        let queue = TransferQueue(downloadClient: ArchiveDownload(archive: fixture.archive), registry: registry, layout: layout)
        let first = await queue.enqueue(try .catalog(SourcedCatalogEntry(source: a, entry: fixture.entry)))
        let second = await queue.enqueue(try .catalog(SourcedCatalogEntry(source: b, entry: fixture.entry)))
        #expect(first.id != second.id)
        try await finished(queue)
        let jobs = await queue.snapshot
        #expect(jobs.allSatisfy { if case .completed = $0.status { return true }; return false }, "\(jobs.map(\.status))")
        let records = try await registry.allInstalled()
        #expect(records.count == 2)
        #expect(Set(records.compactMap(\.sourceConfigurationID)) == [a.id, b.id])
        #expect(Set(records.map(\.identifier)).count == 2)
        #expect(Set(records.map { $0.descriptor.bundleURL }).count == 2)
    }

    @Test func disabledPersistedSourceDoesNotResumeQueuedDownload() async throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = try DocsetRegistry(databaseURL: root.appending(path: "library.sqlite"))
        var source = source("Paused", endpoint: "paused")
        source.isEnabled = false
        try await registry.saveSource(source)
        let job = TransferJob(kind: .catalog, displayName: "Python", sourceURL: URL(string: "https://paused.invalid/artifact.tgz")!,
            catalogName: "Python", catalogSourceId: "com.kapeli", sourceConfigurationID: source.id,
            sourceName: source.name, transportPolicy: .strictHTTPS)
        try await registry.saveJobs([job])
        let queue = TransferQueue(downloadClient: ForbiddenDownload(), registry: registry,
            layout: AppDirectoryLayout(applicationSupportDirectory: root.appending(path: "app")))
        try await queue.restorePersistedJobs()
        #expect(await queue.snapshot.first?.status == .cancelled)
        #expect(try await registry.allInstalled().isEmpty)
        #expect(try await registry.allJobs().isEmpty)
    }

    @Test func reimportingALocalDocsetReplacesItsVersionInsteadOfAddingACopy() async throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = try DocsetRegistry(databaseURL: root.appending(path: "library.sqlite"))
        let latest = try TestReleaseFixture.make(in: root)
        let older = try TestReleaseFixture.make(in: root, old: true)
        let queue = TransferQueue(downloadClient: ForbiddenDownload(), registry: registry,
            layout: AppDirectoryLayout(applicationSupportDirectory: root.appending(path: "app")))
        func request(_ url: URL) -> TransferRequest {
            var value = TransferRequest.importing(fileURL: url)
            value.sourceConfigurationID = DocsetSourceConfiguration.localID
            value.sourceName = "Local Imports"
            return value
        }
        _ = await queue.enqueue(request(latest.bundle))
        try await finished(queue)
        let first = try #require(try await registry.allInstalled().first)
        _ = await queue.enqueue(request(older.bundle))
        try await finished(queue)
        let records = try await registry.allInstalled()
        #expect(records.count == 1)
        #expect(records.first?.identifier == first.identifier)
        #expect(records.first?.descriptor.bundleURL == first.descriptor.bundleURL)
        #expect(records.first?.descriptor.version == "3.13.9")
    }

    private func source(_ name: String, endpoint: String) -> DocsetSourceConfiguration {
        DocsetSourceConfiguration(name: name, kind: .zeal(catalogURL: URL(string: "https://\(endpoint).invalid/catalog")!, downloadRootURL: URL(string: "https://\(endpoint).invalid/d")!))
    }
    private func finished(_ queue: TransferQueue) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while await queue.snapshot.contains(where: \.isActive) {
            guard ContinuousClock.now < deadline else { throw CocoaError(.fileReadUnknown) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
private struct ArchiveDownload: DownloadClient {
    let archive: URL
    func download(from: URL, to: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws {
        try FileManager.default.copyItem(at: archive, to: to)
    }
}
private struct ForbiddenDownload: DownloadClient {
    func download(from: URL, to: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws {
        throw URLError(.networkConnectionLost)
    }
}
