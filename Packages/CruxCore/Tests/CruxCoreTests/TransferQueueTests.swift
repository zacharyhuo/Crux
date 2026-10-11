import Foundation
import Testing

@testable import CruxCore

@Suite(.serialized)
struct TransferQueueTests {
    @Test
    func downloadProgressIsPublishedBeforeCancellation() async throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try TestReleaseFixture.make(in: root)
        let layout = AppDirectoryLayout(applicationSupportDirectory: root.appending(path: "app"))
        let registry = try DocsetRegistry(databaseURL: layout.databaseURL)
        let downloader = DownloadGate(limit: 2)
        let queue = TransferQueue(downloadClient: downloader, registry: registry, layout: layout)
        let job = await queue.enqueue(try .catalog(fixture.entry))
        try await waitUntil { await downloader.inFlight == 1 }
        let progress = try #require(await downloader.currentProgressCallback())
        progress(25, 100)
        try await waitUntil {
            await queue.snapshot.contains {
                $0.id == job.id && $0.status == .downloading(bytesReceived: 25, bytesExpected: 100)
            }
        }
        await queue.cancel(job.id)
        try await waitUntil { await downloader.cancelledCount == 1 }
        #expect(await queue.snapshot.first(where: { $0.id == job.id })?.status == .cancelled)
        #expect(try await registry.allInstalled().isEmpty)
    }

    @Test
    func libraryMutationHoldsNewDownloadsUntilReleased() async throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try TestReleaseFixture.make(in: root)
        let layout = AppDirectoryLayout(applicationSupportDirectory: root.appending(path: "app"))
        let registry = try DocsetRegistry(databaseURL: layout.databaseURL)
        let queue = TransferQueue(
            downloadClient: ReleaseDownloadFixture(files: [fixture.target.release.downloadURL: fixture.archive]),
            registry: registry, layout: layout)
        #expect(await queue.beginLibraryMutation())
        #expect(await queue.beginLibraryMutation() == false)
        let job = await queue.enqueue(try .catalog(fixture.entry))
        // Explicitly requesting scheduling must not bypass the reservation.
        await queue.resumeScheduling()
        #expect(await queue.snapshot.first?.status == .queued)
        #expect(try await registry.allInstalled().isEmpty)
        await queue.endLibraryMutation()
        try await waitUntil { await queue.snapshot.contains { $0.id == job.id && $0.isFinished } }
        #expect(try await registry.allInstalled().first?.installTarget == fixture.target)
    }

    @Test
    func startupCanRecoverAndScanBeforeStartingAFrozenPersistedDownload() async throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try TestReleaseFixture.make(in: root, old: true)
        let layout = AppDirectoryLayout(applicationSupportDirectory: root.appending(path: "app"))
        let registry = try DocsetRegistry(databaseURL: layout.databaseURL)
        let target = fixture.target
        let job = TransferJob(kind: .catalog, displayName: "Python", sourceURL: target.release.downloadURL,
            expectedIdentifier: target.release.identifier, catalogName: target.familyId, catalogSourceId: target.sourceId,
            advertisedVersion: target.release.advertisedVersion, target: target)
        try await registry.saveJobs([job])
        let queue = TransferQueue(downloadClient: ReleaseDownloadFixture(files: [target.release.downloadURL: fixture.archive]),
                                  registry: registry, layout: layout)
        try await queue.restorePersistedJobs(startQueued: false)
        #expect(await queue.snapshot.first?.status == .queued)
        #expect(await queue.snapshot.first?.target == target)
        #expect(try await registry.allInstalled().isEmpty)
        _ = try await registry.scanAndRegister(docsetsDirectory: layout.defaultDocsetsDirectory)
        await queue.resumeScheduling()
        try await waitUntil { await queue.snapshot.first?.isFinished == true }
        #expect(try await registry.allInstalled().first?.installTarget == target)
    }

    @Test
    func importingAConflictingIdentityDoesNotLeaveAnotherVersionOnDisk() async throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try TestReleaseFixture.make(in: root)
        let layout = AppDirectoryLayout(applicationSupportDirectory: root.appending(path: "app"))
        let registry = try DocsetRegistry(databaseURL: layout.databaseURL)
        let original = try await DocsetReplacementTransaction(registry: registry, docsetsDirectory: layout.defaultDocsetsDirectory)
            .perform(target: fixture.target, artifactAt: fixture.archive)
        let queue = TransferQueue(downloadClient: DownloadGate(limit: 0), registry: registry, layout: layout)
        let job = await queue.enqueue(.importing(fileURL: fixture.bundle))
        try await waitUntil { await queue.snapshot.contains { $0.id == job.id && $0.isFinished } }
        let finalJob = try #require(await queue.snapshot.first)
        if case .failed = finalJob.status {} else { Issue.record("Untrusted import should be rejected before activation") }
        #expect(try await registry.allInstalled() == [original])
        let visible = try FileManager.default.contentsOfDirectory(at: layout.defaultDocsetsDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        #expect(visible.filter { $0.pathExtension == "docset" }.map(\.lastPathComponent) == [original.descriptor.bundleURL.lastPathComponent])
    }

    @Test
    func versionedDownloadsFreezeExactTargetsAndReplaceInsteadOfAddingCopies() async throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = try TestReleaseFixture.make(in: root, old: true)
        let latest = try TestReleaseFixture.make(in: root)
        let layout = AppDirectoryLayout(applicationSupportDirectory: root.appending(path: "app"))
        let registry = try DocsetRegistry(databaseURL: layout.databaseURL)
        let downloader = ReleaseDownloadFixture(files: [old.target.release.downloadURL: old.archive, latest.target.release.downloadURL: latest.archive])
        let queue = TransferQueue(downloadClient: downloader, registry: registry, layout: layout)
        for fixture in [latest, old] {
            let request = try TransferRequest.catalog(fixture.entry, selection: fixture.target.selectionPolicy)
            #expect(request.target == fixture.target)
            #expect(request.sourceURL == fixture.target.release.downloadURL)
            let job = await queue.enqueue(request)
            #expect(try JSONDecoder().decode(TransferJob.self, from: JSONEncoder().encode(job)).target == fixture.target)
            try await waitUntil { await queue.snapshot.contains { $0.id == job.id && $0.isFinished } }
            #expect(await queue.snapshot.first(where: { $0.id == job.id })?.status == .completed(identifier: "dev.crux.python"))
            let installed = try await registry.allInstalled()
            #expect(installed.count == 1)
            #expect(installed.first?.installTarget == fixture.target)
        }
        let original = try await registry.allInstalled()
        await downloader.failAll()
        let failed = await queue.enqueue(try .catalog(latest.entry))
        try await waitUntil { await queue.snapshot.contains { $0.id == failed.id && $0.isFinished } }
        #expect(try await registry.allInstalled() == original)
    }

    @Test
    func anotherVersionOfAnActiveFamilyFailsClearlyWithoutStartingASecondDownload() async throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = try TestReleaseFixture.make(in: root, old: true)
        let latest = try TestReleaseFixture.make(in: root)
        let layout = AppDirectoryLayout(applicationSupportDirectory: root.appending(path: "app"))
        let registry = try DocsetRegistry(databaseURL: layout.databaseURL)
        let gate = DownloadGate(limit: 2)
        let queue = TransferQueue(downloadClient: gate, registry: registry, layout: layout)
        let first = await queue.enqueue(try .catalog(latest.entry))
        try await waitUntil { await gate.inFlight == 1 }
        let conflict = await queue.enqueue(try .catalog(old.entry, selection: old.target.selectionPolicy))
        if case .failed = conflict.status {} else { Issue.record("Expected a visible same-family conflict") }
        #expect(await gate.inFlight == 1)
        await queue.cancel(first.id)
        try await waitUntil { await gate.cancelledCount == 1 }
    }

    @Test
    func runsAtMostTwoJobsAtOnceAndCancelsWithoutInstalling() async throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = AppDirectoryLayout(applicationSupportDirectory: root)
        let registry = try DocsetRegistry(databaseURL: layout.databaseURL)
        let gate = DownloadGate(limit: 3)
        let queue = TransferQueue(
            downloadClient: gate,
            installer: DocsetInstaller(),
            registry: registry,
            layout: layout
        )

        let requests = (0..<3).map { index in
            TransferRequest(
                kind: .catalog,
                displayName: "Doc \(index)",
                sourceURL: URL(string: "https://example.com/\(index).tgz")!
            )
        }
        let jobs = requests.map { queueEnqueue in
            // Can't capture mutating enqueue easily from sync map.
            queueEnqueue
        }
        _ = jobs
        var enqueued: [TransferJob] = []
        for request in requests {
            enqueued.append(await queue.enqueue(request))
        }

        try await waitUntil {
            let inFlight = await gate.inFlight
            return inFlight == 2
        }
        #expect(await gate.peak == 2)

        await queue.cancel(enqueued[0].id)
        try await waitUntil { await gate.cancelledCount == 1 }
        await gate.releaseOne()
        await gate.releaseOne()
        try await waitUntil { await queue.snapshot.filter(\.isActive).isEmpty }

        let snapshot = await queue.snapshot
        #expect(snapshot.contains { $0.id == enqueued[0].id && $0.status == .cancelled })
        #expect(try await registry.allInstalled().isEmpty)
    }

    @Test
    func restoringAMidDownloadJobFailsClearlyInsteadOfInstallingResidue() async throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = AppDirectoryLayout(applicationSupportDirectory: root)
        let registry = try DocsetRegistry(databaseURL: layout.databaseURL)
        var job = TransferJob(
            kind: .catalog,
            displayName: "Python",
            sourceURL: URL(string: "https://example.com/Python.tgz")!,
            status: .downloading(bytesReceived: 10, bytesExpected: 100)
        )
        job.downloadedFileURL = layout.downloadsDirectory.appending(path: "partial.tgz")
        try await registry.saveJobs([job])

        let queue = TransferQueue(
            downloadClient: DownloadGate(limit: 0),
            registry: registry,
            layout: layout
        )
        try await queue.restorePersistedJobs()
        let restored = try #require(await queue.snapshot.first)
        guard case let .failed(message) = restored.status else {
            Issue.record("Expected a failed restore, got \(restored.status).")
            return
        }
        #expect(message.contains("restored") || message.contains("restart"))
    }

    @Test
    func importInstallsThroughTheQueueAndRecordsTheSource() async throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = AppDirectoryLayout(applicationSupportDirectory: root)
        try FileManager.default.createDirectory(at: layout.defaultDocsetsDirectory, withIntermediateDirectories: true)
        let registry = try DocsetRegistry(databaseURL: layout.databaseURL)
        let bundle = try TestDocsetFixture.create(in: root, name: "Imported", identifier: "dev.crux.imported")
        let queue = TransferQueue(
            downloadClient: DownloadGate(limit: 0),
            registry: registry,
            layout: layout
        )

        _ = await queue.enqueue(.importing(fileURL: bundle))
        try await waitUntil { await queue.snapshot.contains { job in
            if case .completed = job.status { return true }
            return false
        } }

        let installed = try await registry.allInstalled()
        #expect(installed.map(\.identifier) == ["dev.crux.imported"])
        #expect(installed.first?.source == .localImport)
        #expect(FileManager.default.fileExists(atPath: bundle.path), "Import must not consume the source file.")
    }
}

private actor ReleaseDownloadFixture: DownloadClient {
    let files: [URL: URL]
    private var shouldFail = false
    init(files: [URL: URL]) { self.files = files }
    func failAll() { shouldFail = true }
    func download(from url: URL, to destination: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws {
        guard !shouldFail, let source = files[url] else { throw URLError(.resourceUnavailable) }
        try FileManager.default.copyItem(at: source, to: destination)
    }
}

struct StorageMigratorTests {
    @Test
    func pinnedReleaseNeverParticipatesInUpdateAllButLatestStillResolvesAnExactTarget() throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = try TestReleaseFixture.make(in: root, old: true)
        let latest = try TestReleaseFixture.make(in: root)
        var record = InstalledDocset(descriptor: try DocsetParser().parse(bundleAt: old.bundle),
            source: .catalog(name: "python", sourceId: "dev.crux"), advertisedVersion: old.target.release.advertisedVersion,
            selectionPolicy: old.target.selectionPolicy, installTarget: old.target)
        #expect(DocsetUpdateChecker.availableUpdate(for: record, catalog: [latest.entry], feeds: []) == nil)
        record.selectionPolicy = .latest
        let request = try #require(DocsetUpdateChecker.availableUpdate(for: record, catalog: [latest.entry], feeds: []))
        #expect(request.target == latest.target)
        #expect(request.sourceURL == latest.target.release.downloadURL)
        // Even a newer legacy entry must not strip integrity verification from
        // a trusted installation just because the provider format changed.
        let legacy = CatalogEntry(name: "python", title: "Python", sourceId: "dev.crux", version: "4.0", revision: 1,
                                  downloadURL: URL(string: "https://example.invalid/latest.tgz")!, keywords: [])
        #expect(DocsetUpdateChecker.availableUpdate(for: record, catalog: [legacy], feeds: []) == nil)
    }

    @Test
    func copiesVerifiesThenSwitchesAndLeavesTheOldTreeUntilAskedToTrash() async throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceRoot = root.appending(path: "old", directoryHint: .isDirectory)
        let destinationRoot = root.appending(path: "new", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        let bundle = try TestDocsetFixture.create(in: sourceRoot, name: "Python", identifier: "org.python.Python")
        let descriptor = try DocsetParser().parse(bundleAt: bundle)
        let record = InstalledDocset(
            descriptor: descriptor,
            source: .catalog(name: "Python_3", sourceId: "com.kapeli"),
            advertisedVersion: DocsetVersion(descriptor: descriptor)
        )

        let (relocated, report) = try await StorageMigrator().migrate(
            records: [record],
            from: sourceRoot,
            to: destinationRoot,
            trashSourceAfterSwitch: false
        )

        #expect(report.trashedSource == false)
        #expect(report.sourceItemsEligibleForTrash == [bundle.standardizedFileURL])
        #expect(FileManager.default.fileExists(atPath: bundle.path))
        #expect(relocated[0].descriptor.bundleURL.path.hasPrefix(destinationRoot.path))
        #expect(try DocsetParser().parse(bundleAt: relocated[0].descriptor.bundleURL).identifier == "org.python.Python")
    }


    @Test
    func reportsOnlyCopiedDocsetBundlesAsEligibleForTrash() async throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceRoot = root.appending(path: "old", directoryHint: .isDirectory)
        let destinationRoot = root.appending(path: "new", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        let unrelated = sourceRoot.appending(path: "personal-notes.txt")
        try Data("keep me".utf8).write(to: unrelated)
        let bundle = try TestDocsetFixture.create(
            in: sourceRoot,
            name: "Swift",
            identifier: "dev.crux.swift"
        )
        let descriptor = try DocsetParser().parse(bundleAt: bundle)
        let record = InstalledDocset(
            descriptor: descriptor,
            source: .localImport,
            advertisedVersion: DocsetVersion(descriptor: descriptor)
        )

        let (_, report) = try await StorageMigrator().migrate(
            records: [record],
            from: sourceRoot,
            to: destinationRoot,
            trashSourceAfterSwitch: false
        )

        #expect(report.sourceItemsEligibleForTrash == [bundle.standardizedFileURL])
        #expect(!report.sourceItemsEligibleForTrash.contains(sourceRoot.standardizedFileURL))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
    }

    @Test
    func refusesToMigrateARegistryRecordOutsideTheSelectedSourceRoot() async throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceRoot = root.appending(path: "selected-source", directoryHint: .isDirectory)
        let outsideRoot = root.appending(path: "outside", directoryHint: .isDirectory)
        let destinationRoot = root.appending(path: "new", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideRoot, withIntermediateDirectories: true)
        let bundle = try TestDocsetFixture.create(in: outsideRoot, name: "Outside")
        let descriptor = try DocsetParser().parse(bundleAt: bundle)
        let record = InstalledDocset(
            descriptor: descriptor,
            source: .localImport,
            advertisedVersion: DocsetVersion(descriptor: descriptor)
        )

        await #expect(throws: StorageMigrationError.sourceOutsideRoot(bundle.standardizedFileURL)) {
            try await StorageMigrator().migrate(
                records: [record],
                from: sourceRoot,
                to: destinationRoot,
                trashSourceAfterSwitch: false
            )
        }
    }

    @Test
    func updateCheckerUsesVersionAndRevisionTogether() {
        let descriptor = DocsetDescriptor(
            identifier: "org.python.Python",
            name: "Python",
            displayName: "Python",
            version: "3.13",
            revision: 1,
            keywords: [],
            bundleURL: URL(fileURLWithPath: "/tmp/Python.docset"),
            documentsURL: URL(fileURLWithPath: "/tmp/Python.docset/Contents/Resources/Documents"),
            indexURL: URL(fileURLWithPath: "/tmp/Python.docset/Contents/Resources/docSet.dsidx"),
            indexSchema: .dash,
            indexPagePath: "index.html",
            isJavaScriptEnabled: false
        )
        let record = InstalledDocset(
            descriptor: descriptor,
            source: .catalog(name: "Python_3", sourceId: "com.kapeli"),
            advertisedVersion: DocsetVersion(version: "3.13.0", revision: 1)
        )
        let stale = CatalogEntry(
            name: "Python_3",
            title: "Python 3",
            sourceId: "com.kapeli",
            version: "3.13.0",
            revision: 1,
            downloadURL: URL(string: "https://go.zealdocs.org/d/com.kapeli/Python_3/latest")!,
            keywords: []
        )
        let newer = CatalogEntry(
            name: "Python_3",
            title: "Python 3",
            sourceId: "com.kapeli",
            version: "3.14.0",
            revision: 0,
            downloadURL: URL(string: "https://go.zealdocs.org/d/com.kapeli/Python_3/latest")!,
            keywords: []
        )
        #expect(DocsetUpdateChecker.availableUpdate(for: record, catalog: [stale], feeds: []) == nil)
        #expect(DocsetUpdateChecker.availableUpdate(for: record, catalog: [newer], feeds: []) != nil)
    }
}

/// A download client that holds every transfer until `releaseOne` is called.
///
/// Continuations keep the actor free while a job is parked, so a second
/// download can register itself as in-flight before any file is written.
private actor DownloadGate: DownloadClient {
    private struct Parked {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
        let progress: @Sendable (Int64, Int64?) -> Void
    }

    private var currentlyDownloading = 0
    private(set) var peak = 0
    private var parked: [Parked] = []
    private(set) var cancelledCount = 0
    /// Releases that arrived before a waiter parked, so a job started after
    /// `releaseOne` can proceed immediately instead of waiting forever.
    private var prepaid = 0

    init(limit: Int) {
        _ = limit
    }

    var inFlight: Int { currentlyDownloading }

    func download(
        from url: URL,
        to destinationURL: URL,
        progress: @escaping @Sendable (Int64, Int64?) -> Void
    ) async throws {
        currentlyDownloading += 1
        peak = max(peak, currentlyDownloading)
        defer { currentlyDownloading = max(0, currentlyDownloading - 1) }
        if prepaid > 0 {
            prepaid -= 1
        } else {
            let ticket = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    parked.append(Parked(id: ticket, continuation: continuation, progress: progress))
                }
            } onCancel: {
                Task { await self.fail(ticket, CancellationError()) }
            }
        }
        try Data("not-an-archive".utf8).write(to: destinationURL)
        progress(1, 1)
    }

    func currentProgressCallback() -> (@Sendable (Int64, Int64?) -> Void)? {
        parked.first?.progress
    }

    func releaseOne() {
        if parked.isEmpty {
            prepaid += 1
        } else {
            parked.removeFirst().continuation.resume()
        }
    }

    private func fail(_ id: UUID, _ error: any Error) {
        guard let index = parked.firstIndex(where: { $0.id == id }) else { return }
        cancelledCount += 1
        parked.remove(at: index).continuation.resume(throwing: error)
    }
}

private func waitUntil(
    timeout: Duration = .seconds(5),
    _ condition: () async -> Bool
) async throws {
    let deadline = ContinuousClock().now + timeout
    while ContinuousClock().now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    Issue.record("Timed out waiting for the transfer queue.")
}
