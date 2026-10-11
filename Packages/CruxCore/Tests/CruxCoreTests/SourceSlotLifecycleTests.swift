import Foundation
import Testing

@testable import CruxCore

struct SourceSlotLifecycleTests {
    @Test(arguments: ["versioned", "zeal", "feed"])
    func versionChangesKeepOneInstallationPerSource(_ format: String) async throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = try TestReleaseFixture.make(in: root, old: true)
        let latest = try TestReleaseFixture.make(in: root)
        let layout = AppDirectoryLayout(applicationSupportDirectory: root.appending(path: "app"))
        let registry = try DocsetRegistry(databaseURL: layout.databaseURL)
        let a = source(format, name: "A"), b = source(format, name: "B")
        try await registry.saveSource(a)
        try await registry.saveSource(b)
        let queue = TransferQueue(downloadClient: SlotArchives(old: old, latest: latest), registry: registry, layout: layout)
        _ = await queue.enqueue(try request(old, format: format, source: a))
        _ = await queue.enqueue(try request(old, format: format, source: b))
        try await finished(queue)
        let initial = try await registry.allInstalled()
        let originalA = try #require(initial.first { $0.sourceConfigurationID == a.id })
        let originalB = try #require(initial.first { $0.sourceConfigurationID == b.id })
        #expect(initial.count == 2)
        #expect(originalA.identifier != originalB.identifier)
        #expect(originalA.descriptor.bundleURL != originalB.descriptor.bundleURL)

        // Only a versioned catalog offers explicit downgrade selection. Zeal
        // and XML feeds exercise an advertised update, not a history picker.
        let changes = format == "versioned" ? [latest, old, latest] : [latest]
        for fixture in changes {
            _ = await queue.enqueue(try request(fixture, format: format, source: a))
            try await finished(queue)
            let records = try await registry.allInstalled()
            let currentA = try #require(records.first { $0.sourceConfigurationID == a.id })
            #expect(records.count == 2)
            #expect(records.first { $0.sourceConfigurationID == b.id } == originalB)
            #expect(currentA.identifier == originalA.identifier)
            #expect(currentA.descriptor.bundleURL == originalA.descriptor.bundleURL)
            #expect(currentA.descriptor.bundleIdentifier == "dev.crux.python")
            #expect(currentA.descriptor.version == fixture.target.release.version)
            let visible = try FileManager.default.contentsOfDirectory(at: layout.defaultDocsetsDirectory,
                includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            #expect(visible.filter { $0.pathExtension == "docset" }.count == 2)
        }

        let reopened = try DocsetRegistry(databaseURL: layout.databaseURL)
        let restored = TransferQueue(downloadClient: SlotArchives(old: old, latest: latest), registry: reopened, layout: layout)
        try await restored.restorePersistedJobs()
        let afterRestart = try await reopened.allInstalled()
        #expect(afterRestart.count == 2)
        let currentA = try #require(afterRestart.first { $0.sourceConfigurationID == a.id })
        #expect(currentA.identifier == originalA.identifier)
        #expect(currentA.descriptor.version == "3.14.7")
        #expect(afterRestart.first { $0.sourceConfigurationID == b.id } == originalB)

        try await DocsetInstaller().uninstall(currentA.descriptor)
        try await reopened.unregister(identifier: currentA.identifier)
        #expect(try await reopened.allInstalled() == [originalB])
        #expect(!FileManager.default.fileExists(atPath: currentA.descriptor.bundleURL.path))
        #expect(FileManager.default.fileExists(atPath: originalB.descriptor.bundleURL.path))
        let symbols = try await SymbolSearchService().search("", in: [originalB.descriptor])
        #expect(symbols.map(\.name) == ["oldAPI"])
    }

    @Test func restartRejectsASecondVersionInTheSameSourceSlotButAllowsAnotherSource() async throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = try TestReleaseFixture.make(in: root, old: true)
        let latest = try TestReleaseFixture.make(in: root)
        let layout = AppDirectoryLayout(applicationSupportDirectory: root.appending(path: "app"))
        let registry = try DocsetRegistry(databaseURL: layout.databaseURL)
        let a = source("versioned", name: "A"), b = source("versioned", name: "B")
        try await registry.saveSource(a)
        try await registry.saveSource(b)
        let first = job(try request(old, format: "versioned", source: a), date: Date(timeIntervalSince1970: 1))
        let conflict = job(try request(latest, format: "versioned", source: a), date: Date(timeIntervalSince1970: 2))
        let independent = job(try request(old, format: "versioned", source: b), date: Date(timeIntervalSince1970: 3))
        try await registry.saveJobs([first, conflict, independent])
        let queue = TransferQueue(downloadClient: SlotArchives(old: old, latest: latest), registry: registry, layout: layout)
        try await queue.restorePersistedJobs(startQueued: false)
        let pending = await queue.snapshot
        #expect(pending.first { $0.id == first.id }?.status == .queued)
        #expect(pending.first { $0.id == independent.id }?.status == .queued)
        #expect(pending.first { $0.id == conflict.id }?.status ==
            .failed(message: DocsetReplacementError.slotBusy.localizedDescription))
        await queue.resumeScheduling()
        try await finished(queue)
        let beforeRetry = try await registry.allInstalled()
        let originalA = try #require(beforeRetry.first { $0.sourceConfigurationID == a.id })
        let originalB = try #require(beforeRetry.first { $0.sourceConfigurationID == b.id })
        #expect(beforeRetry.count == 2)
        #expect(originalA.descriptor.version == "3.13.9")
        await queue.retry(conflict.id)
        try await finished(queue)
        let afterRetry = try await registry.allInstalled()
        #expect(afterRetry.count == 2)
        #expect(afterRetry.first { $0.sourceConfigurationID == b.id } == originalB)
        #expect(afterRetry.first { $0.sourceConfigurationID == a.id }?.identifier == originalA.identifier)
        #expect(afterRetry.first { $0.sourceConfigurationID == a.id }?.descriptor.version == "3.14.7")
    }

    private func source(_ format: String, name: String) -> DocsetSourceConfiguration {
        let endpoint = URL(string: "https://\(name.lowercased()).invalid/catalog")!
        let kind: DocsetSourceConfiguration.Kind
        switch format {
        case "versioned": kind = .versioned(catalogURL: endpoint, sourceId: "dev.crux")
        case "feed": kind = .feed(url: endpoint)
        default: kind = .zeal(catalogURL: endpoint, downloadRootURL: URL(string: "https://\(name.lowercased()).invalid/d")!)
        }
        return DocsetSourceConfiguration(name: name, kind: kind)
    }

    private func request(_ fixture: TestReleaseFixture, format: String,
                         source: DocsetSourceConfiguration) throws -> TransferRequest {
        if format == "feed" {
            let feed = DashFeed(id: source.id, feedURL: try #require(source.endpointURL), name: "Python",
                version: fixture.target.release.version, revision: fixture.target.release.revision,
                downloadURL: fixture.target.release.downloadURL)
            return .feed(feed, source: source)
        }
        let entry = format == "versioned" ? fixture.entry : CatalogEntry(name: "python", title: "Python",
            sourceId: "dev.crux", version: fixture.target.release.version, revision: fixture.target.release.revision,
            downloadURL: fixture.target.release.downloadURL, keywords: ["py"])
        return try .catalog(SourcedCatalogEntry(source: source, entry: entry),
            selection: format == "versioned" ? fixture.target.selectionPolicy : .latest)
    }

    private func job(_ request: TransferRequest, date: Date) -> TransferJob {
        TransferJob(kind: request.kind, displayName: request.displayName, sourceURL: request.sourceURL,
            expectedIdentifier: request.expectedIdentifier, catalogName: request.catalogName,
            catalogSourceId: request.catalogSourceId, feedURL: request.feedURL,
            advertisedVersion: request.advertisedVersion, target: request.target, createdAt: date,
            sourceConfigurationID: request.sourceConfigurationID, sourceName: request.sourceName,
            transportPolicy: request.transportPolicy)
    }

    private func finished(_ queue: TransferQueue) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while await queue.snapshot.contains(where: \.isActive) {
            guard ContinuousClock.now < deadline else { throw CocoaError(.fileReadUnknown) }
            try await Task.sleep(for: .milliseconds(5))
        }
        for job in await queue.snapshot {
            if case .failed = job.status {
                // Persisted same-slot conflicts intentionally remain visible
                // until retried; every executed job must have completed.
                #expect(job.status == .failed(message: DocsetReplacementError.slotBusy.localizedDescription))
            }
        }
    }
}

private struct SlotArchives: DownloadClient {
    let old: TestReleaseFixture
    let latest: TestReleaseFixture
    func download(from url: URL, to destination: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws {
        let fixture = url == old.target.release.downloadURL ? old : latest
        guard url == fixture.target.release.downloadURL else { throw URLError(.resourceUnavailable) }
        try FileManager.default.copyItem(at: fixture.archive, to: destination)
    }
}
