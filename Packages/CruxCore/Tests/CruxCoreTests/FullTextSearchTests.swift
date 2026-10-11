import Foundation
import Testing

@testable import CruxCore

@Suite(.serialized)
struct FullTextSearchTests {
    @Test
    func indexesOnlyAfterExplicitOptInAndFindsBodyTextMissingFromSymbols() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = try FullTextSearchService(databaseURL: fixture.databaseURL)

        #expect(try await service.search("distributed actor", in: [fixture.descriptor], limit: 20).isEmpty)

        try await service.enable(for: fixture.descriptor)
        let state = try await service.index(fixture.descriptor)
        let results = try await service.search("distributed actor", in: [fixture.descriptor], limit: 20)

        #expect(state.phase == .ready)
        #expect(results.first?.relativePath == "guide/concurrency.html")
        #expect(results.first?.title == "Concurrency Guide")
        #expect(results.first?.excerpt.contains("distributed") == true)
        #expect(results.first?.excerpt.isEmpty == false)
    }

    @Test
    func enablingAReadyIndexAgainIsIdempotentAndKeepsItsDocuments() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = try FullTextSearchService(databaseURL: fixture.databaseURL)
        try await service.enable(for: fixture.descriptor)
        _ = try await service.index(fixture.descriptor)

        try await service.enable(for: fixture.descriptor)

        #expect(try await service.state(for: fixture.descriptor.identifier)?.phase == .ready)
        #expect(try await service.search("distributed actor", in: [fixture.descriptor], limit: 20).count == 1)
    }

    @Test
    func trigramSearchSupportsCJKAndShortQueriesUseBoundedLikeFallback() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = try FullTextSearchService(databaseURL: fixture.databaseURL)
        try await service.enable(for: fixture.descriptor)
        _ = try await service.index(fixture.descriptor)

        let cjk = try await service.search("并发编程", in: [fixture.descriptor], limit: 20)
        let short = try await service.search("并发", in: [fixture.descriptor], limit: 20)

        #expect(cjk.first?.relativePath == "guide/concurrency.html")
        #expect(short.first?.relativePath == "guide/concurrency.html")
        #expect(short.count <= FullTextSearchService.shortQueryResultLimit)
    }

    @Test
    func interruptedIndexingResumesAndRemovalDropsEveryStaleResult() async throws {
        let fixture = try makeFixture(extraPageCount: 300)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = try FullTextSearchService(databaseURL: fixture.databaseURL)
        try await service.enable(for: fixture.descriptor)
        let progress = IndexProgressRecorder()

        let task = Task {
            try await service.index(fixture.descriptor) { update in
                progress.record(update)
            }
        }
        while progress.latestIndexedCount < 1 { await Task.yield() }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try await service.state(for: fixture.descriptor.identifier)?.phase == .interrupted)

        let resumed = try await service.index(fixture.descriptor)
        #expect(resumed.phase == .ready)
        #expect(resumed.indexedDocumentCount == resumed.totalDocumentCount)
        #expect(try await service.search("resumable marker 299", in: [fixture.descriptor], limit: 20).count == 1)

        try await service.removeIndex(for: fixture.descriptor.identifier)
        #expect(try await service.search("distributed actor", in: [fixture.descriptor], limit: 20).isEmpty)
        #expect(try await service.state(for: fixture.descriptor.identifier) == nil)
    }

    @Test
    func rebuildingAfterAChangedDocsetRemovesOldContent() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = try FullTextSearchService(databaseURL: fixture.databaseURL)
        try await service.enable(for: fixture.descriptor)
        _ = try await service.index(fixture.descriptor)
        let page = fixture.descriptor.documentsURL.appending(path: "guide/concurrency.html")
        try Data("<html><title>Replacement</title><body>brand new marker</body></html>".utf8)
            .write(to: page)

        _ = try await service.index(fixture.descriptor, forceRebuild: true)

        #expect(try await service.search("distributed actor", in: [fixture.descriptor], limit: 20).isEmpty)
        #expect(try await service.search("brand new marker", in: [fixture.descriptor], limit: 20).count == 1)
    }

    @Test
    func skipsEscapingSymlinksAndDocumentsAboveTheConfiguredMemoryLimit() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let outside = fixture.root.appending(path: "outside.html")
        try Data("<html><body>outside secret marker</body></html>".utf8).write(to: outside)
        let link = fixture.descriptor.documentsURL.appending(path: "linked.html")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let oversized = fixture.descriptor.documentsURL.appending(path: "oversized.html")
        try Data("<html><body>oversized secret marker \(String(repeating: "x", count: 512))</body></html>".utf8)
            .write(to: oversized)
        let service = try FullTextSearchService(
            databaseURL: fixture.databaseURL,
            maximumDocumentBytes: 128
        )
        try await service.enable(for: fixture.descriptor)
        _ = try await service.index(fixture.descriptor)

        #expect(try await service.search("outside secret", in: [fixture.descriptor], limit: 20).isEmpty)
        #expect(try await service.search("oversized secret", in: [fixture.descriptor], limit: 20).isEmpty)
    }

    private func makeFixture(extraPageCount: Int = 0) throws -> (
        root: URL,
        databaseURL: URL,
        descriptor: DocsetDescriptor
    ) {
        let root = try TestDocsetFixture.makeRoot()
        let bundle = try TestDocsetFixture.create(
            in: root,
            name: "Swift",
            identifier: "org.swift.Swift",
            symbols: [TestSymbol("Task", type: "Structure", path: "task.html")]
        )
        let descriptor = try DocsetParser().parse(bundleAt: bundle)
        let guide = descriptor.documentsURL.appending(path: "guide/concurrency.html")
        try FileManager.default.createDirectory(at: guide.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("""
            <html><head><title>Concurrency Guide</title></head>
            <body>Learn the distributed actor model and 并发编程 fundamentals.</body></html>
            """.utf8).write(to: guide)
        for index in 0..<extraPageCount {
            let page = descriptor.documentsURL.appending(path: "generated/page-\(index).html")
            try FileManager.default.createDirectory(at: page.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("<html><title>Page \(index)</title><body>resumable marker \(index)</body></html>".utf8)
                .write(to: page)
        }
        return (root, root.appending(path: "FullText.sqlite"), descriptor)
    }
}

private final class IndexProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var latestIndexedCount: Int { lock.withLock { count } }

    func record(_ progress: FullTextIndexProgress) {
        lock.withLock { count = progress.indexedDocumentCount }
    }
}
