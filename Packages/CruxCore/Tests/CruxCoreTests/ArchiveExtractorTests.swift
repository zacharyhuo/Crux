import Foundation
import Testing

@testable import CruxCore

@Suite
struct ArchiveExtractorTests {
    private func makeWorkspace() throws -> (root: URL, archive: URL, destination: URL) {
        let root = try TestDocsetFixture.makeRoot()
        let destination = root.appending(path: "staging", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        return (root, root.appending(path: "input.tgz", directoryHint: .notDirectory), destination)
    }

    private func extract(
        _ entries: [TestArchiveEntry],
        limits: ArchiveLimits = .default,
        compressed: Bool = true
    ) async throws -> Result<(URL, ArchiveExtractionReport), any Error> {
        let workspace = try makeWorkspace()
        if compressed {
            try TestArchiveFixture.writeTarGzip(entries, to: workspace.archive)
        } else {
            try TestArchiveFixture.writeTar(entries, to: workspace.archive)
        }

        do {
            let report = try await StreamingArchiveExtractor().extract(
                archiveURL: workspace.archive,
                into: workspace.destination,
                limits: limits,
                progress: nil
            )
            return .success((workspace.destination, report))
        } catch {
            return .failure(error)
        }
    }

    @Test
    func expandsAGzippedTarWithNestedDirectoriesAndLinks() async throws {
        let outcome = try await extract([
            .directory("Fixture.docset"),
            .file("Fixture.docset/Contents/Info.plist", contents: "plist"),
            .file("Fixture.docset/Contents/Resources/Documents/index.html", contents: "<html>hi</html>"),
            .symbolicLink("Fixture.docset/Contents/Resources/Documents/alias.html", to: "index.html"),
        ])

        let (destination, report) = try outcome.get()
        #expect(report.entryCount == 4)
        #expect(report.totalBytesWritten == Int64("plist".utf8.count + "<html>hi</html>".utf8.count))

        let indexURL = destination.appending(path: "Fixture.docset/Contents/Resources/Documents/index.html")
        #expect(try String(contentsOf: indexURL, encoding: .utf8) == "<html>hi</html>")

        let aliasURL = destination.appending(path: "Fixture.docset/Contents/Resources/Documents/alias.html")
        let linkTarget = try FileManager.default.destinationOfSymbolicLink(atPath: aliasURL.path)
        #expect(linkTarget == "index.html")
    }

    @Test
    func rejectsAbsoluteAndTraversingEntryPaths() async throws {
        for path in ["/etc/passwd", "../escape.html", "Fixture/../../escape.html", "~/escape.html"] {
            let outcome = try await extract([.file(path, contents: "x")])
            guard case let .failure(error) = outcome else {
                Issue.record("\(path) should have been rejected.")
                continue
            }
            #expect(error as? ArchiveExtractionError == .unsafeEntryPath(path))
        }
    }

    @Test
    func rejectsSymbolicLinksThatLeaveTheStagingRoot() async throws {
        let escaping: [(String, String)] = [
            ("Fixture.docset/link", "/etc/passwd"),
            ("Fixture.docset/link", "../../../../etc/passwd"),
            ("link", "../outside"),
        ]

        for (path, target) in escaping {
            let outcome = try await extract([.symbolicLink(path, to: target)])
            guard case let .failure(error) = outcome else {
                Issue.record("\(path) -> \(target) should have been rejected.")
                continue
            }
            #expect(error as? ArchiveExtractionError == .unsafeEntryPath(path))
        }

        // A link that stays inside its own tree remains allowed.
        let allowed = try await extract([
            .file("Fixture/deep/page.html", contents: "page"),
            .symbolicLink("Fixture/deep/nested/alias.html", to: "../page.html"),
        ])
        #expect((try? allowed.get()) != nil)
    }

    @Test
    func rejectsDeviceNodesAndHardLinks() async throws {
        let device = try await extract([
            TestArchiveEntry(path: "Fixture/null", kind: .characterDevice),
        ])
        #expect(
            (try? device.get()) == nil,
            "A character device entry should never be materialized."
        )

        let hardLink = try await extract([
            .file("Fixture/real.html", contents: "real"),
            TestArchiveEntry(path: "Fixture/alias.html", kind: .hardLink(target: "Fixture/real.html")),
        ])
        guard case let .failure(error) = hardLink else {
            Issue.record("A hard link should have been rejected.")
            return
        }
        #expect(error as? ArchiveExtractionError == .unsupportedEntryKind("Fixture/alias.html"))
    }

    @Test
    func enforcesEntryCountAndSizeLimits() async throws {
        var limits = ArchiveLimits.default
        limits.maximumEntryCount = 2
        let tooMany = try await extract(
            (0..<5).map { .file("Fixture/\($0).html", contents: "x") },
            limits: limits
        )
        guard case let .failure(countError) = tooMany else {
            Issue.record("The entry count limit should have tripped.")
            return
        }
        #expect(countError as? ArchiveExtractionError == .entryCountLimitExceeded(limit: 2))

        var fileLimits = ArchiveLimits.default
        fileLimits.maximumFileSize = 8
        let tooLarge = try await extract(
            [.file("Fixture/big.html", contents: String(repeating: "a", count: 4_096))],
            limits: fileLimits
        )
        guard case let .failure(sizeError) = tooLarge else {
            Issue.record("The per-file limit should have tripped.")
            return
        }
        #expect(sizeError as? ArchiveExtractionError == .fileSizeLimitExceeded(
            path: "Fixture/big.html",
            limit: 8
        ))

        var totalLimits = ArchiveLimits.default
        totalLimits.maximumTotalSize = 16
        let tooBig = try await extract(
            (0..<4).map { .file("Fixture/\($0).html", contents: String(repeating: "b", count: 32)) },
            limits: totalLimits
        )
        guard case let .failure(totalError) = tooBig else {
            Issue.record("The total size limit should have tripped.")
            return
        }
        #expect(totalError as? ArchiveExtractionError == .totalSizeLimitExceeded(limit: 16))
    }

    @Test
    func rejectsAnArchiveBombByCompressionRatio() async throws {
        // Highly repetitive content compresses far beyond any real docset.
        var limits = ArchiveLimits.default
        limits.maximumCompressionRatio = 20
        limits.compressionRatioGracePeriod = 1_024

        let bomb = try await extract(
            [.file("Fixture/bomb.bin", bytes: Data(count: 4 * 1_024 * 1_024))],
            limits: limits
        )
        guard case let .failure(error) = bomb else {
            Issue.record("The compression ratio limit should have tripped.")
            return
        }
        #expect(error as? ArchiveExtractionError == .compressionRatioLimitExceeded(limit: 20))
    }

    @Test
    func leavesNothingUsableBehindWhenAnEntryIsRejected() async throws {
        let workspace = try makeWorkspace()
        try TestArchiveFixture.writeTarGzip([
            .file("Fixture/good.html", contents: "good"),
            .file("../escape.html", contents: "bad"),
        ], to: workspace.archive)

        await #expect(throws: (any Error).self) {
            try await StreamingArchiveExtractor().extract(
                archiveURL: workspace.archive,
                into: workspace.destination,
                limits: .default,
                progress: nil
            )
        }

        // The caller discards the whole staging directory, but the escaping file
        // must never have been created next to it either.
        let escaped = workspace.root.appending(path: "escape.html", directoryHint: .notDirectory)
        #expect(!FileManager.default.fileExists(atPath: escaped.path))
    }

    @Test
    func rejectsAnEmptyArchive() async throws {
        let outcome = try await extract([])
        guard case let .failure(error) = outcome else {
            Issue.record("An archive with no entries should be rejected.")
            return
        }
        #expect(error as? ArchiveExtractionError == .emptyArchive)
    }

    @Test
    func readsUncompressedTarArchivesToo() async throws {
        let outcome = try await extract(
            [.file("Fixture/plain.html", contents: "plain")],
            compressed: false
        )
        let (destination, report) = try outcome.get()
        #expect(report.entryCount == 1)
        #expect(FileManager.default.fileExists(
            atPath: destination.appending(path: "Fixture/plain.html").path
        ))
    }

    @Test
    func blockingExtractionLeavesTheCooperativeExecutorFreeToCancel() async throws {
        // Run this regression with LIBDISPATCH_COOPERATIVE_POOL_STRICT=1. The
        // old extractor performed every libarchive and FileHandle call inline
        // on Swift's only cooperative worker. Consequently the cancellation
        // task below could not run until all 1,000 files had been expanded.
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        try TestArchiveFixture.writeTar(
            (0..<1_000).map { .file("Fixture/\($0).html", contents: "page \($0)") },
            to: workspace.archive
        )

        let cancellation = ExtractionCancellationBox()
        let extraction = Task {
            try await StreamingArchiveExtractor().extract(
                archiveURL: workspace.archive,
                into: workspace.destination,
                limits: .default,
                progress: { _ in cancellation.requestFromAnotherTask() }
            )
        }
        cancellation.store(extraction)

        await #expect(throws: CancellationError.self) {
            try await extraction.value
        }
        let extractedDirectory = workspace.destination.appending(path: "Fixture", directoryHint: .isDirectory)
        let extractedCount = try FileManager.default.contentsOfDirectory(atPath: extractedDirectory.path).count
        #expect(extractedCount < 1_000, "Cancellation must stop before every entry is expanded.")
    }
}

/// Holds the structured extraction task without making the production
/// extractor aware of this regression harness.
private final class ExtractionCancellationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<ArchiveExtractionReport, any Error>?
    private var hasRequestedCancellation = false

    func store(_ task: Task<ArchiveExtractionReport, any Error>) {
        lock.withLock { self.task = task }
    }

    func requestFromAnotherTask() {
        let shouldSchedule = lock.withLock { () -> Bool in
            guard task != nil, !hasRequestedCancellation else { return false }
            hasRequestedCancellation = true
            return true
        }
        guard shouldSchedule else { return }

        // This deliberately needs a free cooperative executor slot. A direct
        // task.cancel() call from the blocking callback would hide the bug.
        Task { [weak self] in
            self?.lock.withLock { self?.task?.cancel() }
        }
    }
}
