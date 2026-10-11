import Foundation
import GRDB
import Testing

@testable import CruxCore

struct DocsetReplacementTests {
    @Test(arguments: ["version", "identifier", "releaseId"])
    func validArchiveDigestCannotOverrideAMismatchingSelectedIdentity(_ field: String) async throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = try TestReleaseFixture.make(in: root, old: true)
        let latest = try TestReleaseFixture.make(in: root)
        let registry = try DocsetRegistry(databaseURL: root.appending(path: "Crux.sqlite"))
        let transaction = DocsetReplacementTransaction(registry: registry, docsetsDirectory: root.appending(path: "Docsets"))
        let original = try await transaction.perform(target: old.target, artifactAt: old.archive)
        var targetJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(latest.target)) as! [String: Any]
        var release = targetJSON["release"] as! [String: Any]
        release[field] = field == "version" ? "3.14.8" : field == "identifier" ? "dev.crux.other" : String(repeating: "3", count: 64)
        targetJSON["release"] = release
        let mismatched = try JSONDecoder().decode(DocsetInstallTarget.self, from: JSONSerialization.data(withJSONObject: targetJSON))
        await #expect(throws: (any Error).self) {
            try await transaction.perform(target: mismatched, artifactAt: latest.archive, existing: original)
        }
        #expect(try await registry.allInstalled() == [original])
        #expect(try DocsetParser().parse(bundleAt: original.descriptor.bundleURL) == original.descriptor)
    }

    @Test(arguments: ["prepared", "oldMoved", "activated", "committed"])
    func recoversEachDurableCrashBoundaryBeforeScanningTheLibrary(_ boundary: String) async throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = try TestReleaseFixture.make(in: root, old: true)
        let latest = try TestReleaseFixture.make(in: root)
        let dbURL = root.appending(path: "Crux.sqlite")
        let registry = try DocsetRegistry(databaseURL: dbURL)
        let library = root.appending(path: "Docsets")
        let original = try await DocsetReplacementTransaction(registry: registry, docsetsDirectory: library)
            .perform(target: old.target, artifactAt: old.archive)
        // Construct disk state at abrupt termination boundaries. This tests the
        // recovery protocol without killing the test runner or touching an app.
        let operation = library.appending(path: ".crux-replacements/\(latest.target.slotFileName)")
        try FileManager.default.createDirectory(at: operation, withIntermediateDirectories: false)
        let id = UUID()
        let journal = CrashJournal(id: id, target: latest.target, previous: original, prepared: true)
        try JSONEncoder().encode(journal).write(to: operation.appending(path: "journal.json"))
        let candidate = operation.appending(path: "candidate.docset")
        try FileManager.default.copyItem(at: latest.bundle, to: candidate)
        if boundary != "prepared" {
            try FileManager.default.moveItem(at: original.descriptor.bundleURL, to: operation.appending(path: "previous.docset"))
        }
        if boundary == "activated" || boundary == "committed" {
            try FileManager.default.moveItem(at: candidate, to: original.descriptor.bundleURL)
        }
        var expected = original
        if boundary == "committed" {
            expected = InstalledDocset(descriptor: try DocsetParser().parse(bundleAt: original.descriptor.bundleURL),
                source: original.source, advertisedVersion: latest.target.release.advertisedVersion,
                selectionPolicy: latest.target.selectionPolicy, installTarget: latest.target)
            try await registry.commitReplacement(expected, replacing: original, transactionId: id)
        }
        let reopened = try DocsetRegistry(databaseURL: dbURL)
        let recovery = DocsetReplacementTransaction(registry: reopened, docsetsDirectory: library)
        try await recovery.recoverPending()
        try await recovery.recoverPending() // recovery is idempotent
        let report = try await reopened.scanAndRegister(docsetsDirectory: library)
        #expect(report.failures.isEmpty)
        #expect(try await reopened.allInstalled() == [expected])
        #expect(try DocsetParser().parse(bundleAt: original.descriptor.bundleURL) == expected.descriptor)
        #expect(!FileManager.default.fileExists(atPath: operation.path))
    }

    @Test
    func databaseFailureAfterActivationRestoresFilesAndPolicyTogether() async throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = try TestReleaseFixture.make(in: root, old: true)
        let latest = try TestReleaseFixture.make(in: root)
        let dbURL = root.appending(path: "Crux.sqlite")
        let registry = try DocsetRegistry(databaseURL: dbURL)
        let transaction = DocsetReplacementTransaction(registry: registry, docsetsDirectory: root.appending(path: "Docsets"))
        let original = try await transaction.perform(target: old.target, artifactAt: old.archive)
        let injector = try DatabaseQueue(path: dbURL.path)
        try await injector.write { db in
            try db.execute(sql: """
                CREATE TRIGGER reject_commit BEFORE INSERT ON replacement_commits
                BEGIN SELECT RAISE(ABORT, 'injected commit failure'); END;
                """)
        }
        await #expect(throws: (any Error).self) {
            try await transaction.perform(target: latest.target, artifactAt: latest.archive, existing: original)
        }
        let reopened = try DocsetRegistry(databaseURL: dbURL)
        try await transaction.recoverPending()
        #expect(try await reopened.allInstalled() == [original])
        #expect(try DocsetParser().parse(bundleAt: original.descriptor.bundleURL) == original.descriptor)
    }

    @Test
    func sameSlotIsLockedAcrossInstancesAndCancellationPreservesThePreviousVersion() async throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = try TestReleaseFixture.make(in: root, old: true)
        let latest = try TestReleaseFixture.make(in: root)
        let registry = try DocsetRegistry(databaseURL: root.appending(path: "Crux.sqlite"))
        let library = root.appending(path: "Docsets")
        let normal = DocsetReplacementTransaction(registry: registry, docsetsDirectory: library)
        let original = try await normal.perform(target: old.target, artifactAt: old.archive)
        let gate = PausingReleaseExtractor()
        let first = DocsetReplacementTransaction(registry: registry, docsetsDirectory: library,
                                                installer: DocsetInstaller(extractor: gate))
        let task = Task { try await first.perform(target: latest.target, artifactAt: latest.archive, existing: original) }
        await gate.waitUntilEntered()
        await #expect(throws: DocsetReplacementError.slotBusy) {
            try await normal.perform(target: latest.target, artifactAt: latest.archive, existing: original)
        }
        task.cancel()
        await gate.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try await registry.allInstalled() == [original])
        #expect(try DocsetParser().parse(bundleAt: original.descriptor.bundleURL) == original.descriptor)
    }

    @Test
    func switchesBackAndForthInOneSlotAndSearchesOnlyTheCurrentVersion() async throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = try TestReleaseFixture.make(in: root, old: true)
        let latest = try TestReleaseFixture.make(in: root)
        let registry = try DocsetRegistry(databaseURL: root.appending(path: "Crux.sqlite"))
        let library = root.appending(path: "Docsets")
        let transaction = DocsetReplacementTransaction(registry: registry, docsetsDirectory: library)
        let search = SymbolSearchService()
        var previous: InstalledDocset?
        for fixture in [old, latest, old] {
            let installed = try await transaction.perform(target: fixture.target, artifactAt: fixture.archive, existing: previous)
            #expect(try await registry.allInstalled() == [installed])
            #expect(installed.installTarget == fixture.target)
            #expect(installed.selectionPolicy == fixture.target.selectionPolicy)
            #expect(try await search.search("", in: [installed.descriptor]).map(\.name) == [fixture.target.release.version == "3.13.9" ? "oldAPI" : "newAPI"])
            let visible = try FileManager.default.contentsOfDirectory(at: library, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            #expect(visible.filter { $0.pathExtension == "docset" }.count == 1)
            if let previous { #expect(installed.descriptor.bundleURL == previous.descriptor.bundleURL) }
            previous = installed
        }
        let reopened = DocsetReplacementTransaction(registry: registry, docsetsDirectory: library)
        try await reopened.recoverPending()
        #expect(try await registry.allInstalled() == [try #require(previous)])
    }

    @Test
    func rejectsAWrongArchiveBeforeChangingTheInstalledVersionOrPin() async throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = try TestReleaseFixture.make(in: root, old: true)
        let latest = try TestReleaseFixture.make(in: root)
        let registry = try DocsetRegistry(databaseURL: root.appending(path: "Crux.sqlite"))
        let transaction = DocsetReplacementTransaction(registry: registry, docsetsDirectory: root.appending(path: "Docsets"))
        let original = try await transaction.perform(target: old.target, artifactAt: old.archive)
        await #expect(throws: DocsetReplacementError.artifactMismatch) {
            try await transaction.perform(target: latest.target, artifactAt: old.archive, existing: original)
        }
        #expect(try await registry.allInstalled() == [original])
        #expect(try DocsetParser().parse(bundleAt: original.descriptor.bundleURL) == original.descriptor)
    }
}

private struct CrashJournal: Encodable {
    let schemaVersion = 1
    let id: UUID
    let target: DocsetInstallTarget
    let previous: InstalledDocset?
    let prepared: Bool
}

private actor PausingReleaseExtractor: ArchiveExtractor {
    private var entered = false
    private var arrival: CheckedContinuation<Void, Never>?
    private var continuation: CheckedContinuation<Void, Never>?
    func waitUntilEntered() async {
        if !entered { await withCheckedContinuation { arrival = $0 } }
    }
    func release() { continuation?.resume(); continuation = nil }
    func extract(archiveURL: URL, into destinationURL: URL, limits: ArchiveLimits,
                 progress: (@Sendable (Int64) -> Void)?) async throws -> ArchiveExtractionReport {
        entered = true
        arrival?.resume(); arrival = nil
        await withCheckedContinuation { continuation = $0 }
        return try await StreamingArchiveExtractor().extract(archiveURL: archiveURL, into: destinationURL,
                                                            limits: limits, progress: progress)
    }
}
