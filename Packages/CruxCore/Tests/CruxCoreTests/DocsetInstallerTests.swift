import Foundation
import GRDB
import Testing

@testable import CruxCore

@Suite
struct DocsetInstallerTests {
    private var validPNG: Data {
        Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9WlS5b8AAAAASUVORK5CYII=")!
    }

    private func makeIndexData(symbol: String) throws -> Data {
        let temporaryURL = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString).dsidx", directoryHint: .notDirectory)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        let database = try DatabaseQueue(path: temporaryURL.path)
        try database.write { db in
            try db.execute(sql: "CREATE TABLE searchIndex(id INTEGER PRIMARY KEY, name TEXT, type TEXT, path TEXT)")
            try db.execute(
                sql: "INSERT INTO searchIndex(name, type, path) VALUES (?, 'Class', 'index.html')",
                arguments: [symbol]
            )
        }
        return try Data(contentsOf: temporaryURL)
    }

    @Test
    func installsADownloadedArchiveAtomically() async throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let docsets = root.appending(path: "Docsets", directoryHint: .isDirectory)
        let archive = root.appending(path: "Fixture.tgz", directoryHint: .notDirectory)
        try TestArchiveFixture.writeDocsetArchive(to: archive, indexData: try makeIndexData(symbol: "Alpha"))

        var phases: [InstallationPhase] = []
        let recorder = PhaseRecorder()
        let descriptor = try await DocsetInstaller().install(
            artifactAt: archive,
            into: docsets,
            progress: { recorder.record($0) }
        )
        phases = recorder.phases

        #expect(descriptor.identifier == "dev.crux.fixture")
        #expect(descriptor.bundleURL == docsets.appending(path: "Fixture.docset", directoryHint: .isDirectory))
        #expect(phases.contains(.staging))
        #expect(phases.contains(.validating))
        #expect(phases.contains(.activating))

        // Staging must not survive a successful install.
        let staging = docsets.appending(path: ".staging", directoryHint: .isDirectory)
        let leftovers = try? FileManager.default.contentsOfDirectory(atPath: staging.path)
        #expect(leftovers?.isEmpty != false)
    }

    @Test
    func installsCatalogFallbackIconOnlyWhenTheBundleHasNoIcon() async throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let docsets = root.appending(path: "Docsets", directoryHint: .isDirectory)
        let archive = root.appending(path: "Fixture.tgz", directoryHint: .notDirectory)
        try TestArchiveFixture.writeDocsetArchive(to: archive, indexData: try makeIndexData(symbol: "Alpha"))
        let icon = validPNG

        let descriptor = try await DocsetInstaller().install(
            artifactAt: archive,
            into: docsets,
            fallbackIconData: icon
        )

        #expect(try Data(contentsOf: descriptor.bundleURL.appending(path: "icon.png")) == icon)
    }

    @Test
    func replacesAnInvalidBundleIconWithTheValidatedCatalogFallback() async throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "source", directoryHint: .isDirectory)
        let bundle = try TestDocsetFixture.create(in: source, name: "Imported", identifier: "dev.crux.imported")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: bundle.appending(path: "icon.png"))
        let docsets = root.appending(path: "Docsets", directoryHint: .isDirectory)

        let descriptor = try await DocsetInstaller().install(
            artifactAt: bundle,
            into: docsets,
            fallbackIconData: validPNG
        )

        #expect(try Data(contentsOf: descriptor.bundleURL.appending(path: "icon.png")) == validPNG)
    }

    @Test
    func selfSuppliedBundleUsesCanonicalNameInsteadOfDisplayName() async throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try TestDocsetFixture.create(in: root.appending(path: "source"),
            name: "Spring Framework", identifier: "dev.crux.spring-framework")
        let metadata: [String: Any] = [
            "name": "Spring Framework", "sourceId": "dev.crux", "familyId": "spring-framework",
            "variantId": "spring-framework-7-0-en", "versionLine": "7.0", "language": "en",
            "identifier": "dev.crux.spring-framework", "bundleName": "Spring_Framework",
            "releaseId": String(repeating: "a", count: 64), "version": "7.0.9", "revision": 2,
        ]
        try JSONSerialization.data(withJSONObject: metadata).write(to: bundle.appending(path: "meta.json"))
        let installed = try await DocsetInstaller().install(artifactAt: bundle, into: root.appending(path: "Docsets"))
        #expect(installed.bundleURL.lastPathComponent == "Spring_Framework.docset")
        #expect(installed.name == "Spring Framework")
        #expect(installed.displayName == "Spring Framework")
        #expect(installed.supplyMetadata?.bundleName == "Spring_Framework")
    }

    @Test
    func localImportLeavesTheSourceBundleUntouched() async throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "source", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let bundleURL = try TestDocsetFixture.create(in: source, name: "Imported", identifier: "dev.crux.imported")
        let docsets = root.appending(path: "Docsets", directoryHint: .isDirectory)

        let descriptor = try await DocsetInstaller().install(artifactAt: bundleURL, into: docsets)

        #expect(descriptor.identifier == "dev.crux.imported")
        #expect(FileManager.default.fileExists(atPath: bundleURL.path), "The imported bundle must not be moved.")
        #expect(FileManager.default.fileExists(
            atPath: docsets.appending(path: "Imported.docset/Contents/Info.plist").path
        ))
    }

    @Test
    func updatingReplacesTheBundleInPlace() async throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let docsets = root.appending(path: "Docsets", directoryHint: .isDirectory)
        let installer = DocsetInstaller()

        let firstArchive = root.appending(path: "v1.tgz", directoryHint: .notDirectory)
        try TestArchiveFixture.writeDocsetArchive(to: firstArchive, indexData: try makeIndexData(symbol: "Alpha"))
        let installed = try await installer.install(artifactAt: firstArchive, into: docsets)

        let secondArchive = root.appending(path: "v2.tgz", directoryHint: .notDirectory)
        try TestArchiveFixture.writeDocsetArchive(to: secondArchive, indexData: try makeIndexData(symbol: "Beta"))
        let updated = try await installer.install(
            artifactAt: secondArchive,
            into: docsets,
            replacing: installed,
            expectedIdentifier: installed.identifier
        )

        #expect(updated.bundleURL == installed.bundleURL)
        let results = try await SymbolSearchService().search("Beta", in: [updated], limit: 10)
        #expect(results.first?.name == "Beta")

        let installedFolders = try FileManager.default.contentsOfDirectory(atPath: docsets.path)
            .filter { $0.hasSuffix(".docset") }
        #expect(installedFolders == ["Fixture.docset"], "An update must not leave a second copy behind.")
    }

    @Test
    func aFailedUpdateLeavesTheInstalledVersionUsable() async throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let docsets = root.appending(path: "Docsets", directoryHint: .isDirectory)
        let installer = DocsetInstaller()

        let goodArchive = root.appending(path: "good.tgz", directoryHint: .notDirectory)
        try TestArchiveFixture.writeDocsetArchive(to: goodArchive, indexData: try makeIndexData(symbol: "Alpha"))
        let installed = try await installer.install(artifactAt: goodArchive, into: docsets)

        // An archive whose index is not a usable database must fail validation.
        let brokenArchive = root.appending(path: "broken.tgz", directoryHint: .notDirectory)
        try TestArchiveFixture.writeDocsetArchive(
            to: brokenArchive,
            indexData: Data("this is not a database".utf8)
        )

        await #expect(throws: (any Error).self) {
            try await installer.install(
                artifactAt: brokenArchive,
                into: docsets,
                replacing: installed,
                expectedIdentifier: installed.identifier
            )
        }

        let stillThere = try DocsetParser().parse(bundleAt: installed.bundleURL)
        let results = try await SymbolSearchService().search("Alpha", in: [stillThere], limit: 10)
        #expect(results.first?.name == "Alpha", "The previous version must remain searchable.")
    }

    @Test
    func refusesAnArchiveThatContainsADifferentDocset() async throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let docsets = root.appending(path: "Docsets", directoryHint: .isDirectory)
        let archive = root.appending(path: "other.tgz", directoryHint: .notDirectory)
        try TestArchiveFixture.writeDocsetArchive(
            to: archive,
            bundleName: "Other",
            identifier: "dev.crux.other",
            indexData: try makeIndexData(symbol: "Alpha")
        )

        await #expect(throws: DocsetInstallError.identityMismatch(
            expected: "dev.crux.expected",
            found: "dev.crux.other"
        )) {
            try await DocsetInstaller().install(
                artifactAt: archive,
                into: docsets,
                expectedIdentifier: "dev.crux.expected"
            )
        }
        #expect(!FileManager.default.fileExists(atPath: docsets.appending(path: "Other.docset").path))
    }

    @Test
    func rejectsArchivesWithoutExactlyOneBundle() async throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let docsets = root.appending(path: "Docsets", directoryHint: .isDirectory)

        let empty = root.appending(path: "empty.tgz", directoryHint: .notDirectory)
        try TestArchiveFixture.writeTarGzip([.file("readme.txt", contents: "nothing here")], to: empty)
        await #expect(throws: DocsetInstallError.noDocsetInArchive) {
            try await DocsetInstaller().install(artifactAt: empty, into: docsets)
        }

        let twoBundles = root.appending(path: "two.tgz", directoryHint: .notDirectory)
        try TestArchiveFixture.writeTarGzip([
            .file("A.docset/Contents/Info.plist", contents: "a"),
            .file("B.docset/Contents/Info.plist", contents: "b"),
        ], to: twoBundles)
        await #expect(throws: DocsetInstallError.multipleDocsetsInArchive(count: 2)) {
            try await DocsetInstaller().install(artifactAt: twoBundles, into: docsets)
        }
    }

    @Test
    func cancellationAfterExtractionDoesNotActivateTheDocset() async throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let docsets = root.appending(path: "Docsets", directoryHint: .isDirectory)
        let archive = root.appending(path: "Fixture.tgz", directoryHint: .notDirectory)
        try Data("fixture".utf8).write(to: archive)
        let extractor = CancellationIgnoringExtractor(indexData: try makeIndexData(symbol: "Cancelled"))
        let installer = DocsetInstaller(extractor: extractor)

        let task = Task {
            try await installer.install(artifactAt: archive, into: docsets)
        }
        await extractor.waitUntilExtractionStarted()
        task.cancel()
        await extractor.finishExtraction()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(!FileManager.default.fileExists(
            atPath: docsets.appending(path: "Fixture.docset", directoryHint: .isDirectory).path
        ))
    }

    @Test
    func findsABundleNestedInsideOneWrapperDirectory() async throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let docsets = root.appending(path: "Docsets", directoryHint: .isDirectory)
        let archive = root.appending(path: "wrapped.tgz", directoryHint: .notDirectory)

        let indexData = try makeIndexData(symbol: "Wrapped")
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>CFBundleIdentifier</key><string>dev.crux.wrapped</string>
        <key>CFBundleName</key><string>Wrapped</string>
        </dict></plist>
        """
        try TestArchiveFixture.writeTarGzip([
            .directory("payload"),
            .file("payload/Wrapped.docset/Contents/Info.plist", contents: plist),
            .file("payload/Wrapped.docset/Contents/Resources/Documents/index.html", contents: "<html>w</html>"),
            TestArchiveEntry(
                path: "payload/Wrapped.docset/Contents/Resources/docSet.dsidx",
                kind: .regularFile(indexData)
            ),
        ], to: archive)

        let descriptor = try await DocsetInstaller().install(artifactAt: archive, into: docsets)
        #expect(descriptor.identifier == "dev.crux.wrapped")
    }

    @Test
    func uninstallRemovesTheBundleAndReportsMissingOnes() async throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let docsets = root.appending(path: "Docsets", directoryHint: .isDirectory)
        let archive = root.appending(path: "Fixture.tgz", directoryHint: .notDirectory)
        try TestArchiveFixture.writeDocsetArchive(to: archive, indexData: try makeIndexData(symbol: "Alpha"))

        let installer = DocsetInstaller()
        let descriptor = try await installer.install(artifactAt: archive, into: docsets)
        try await installer.uninstall(descriptor)

        #expect(!FileManager.default.fileExists(atPath: descriptor.bundleURL.path))
        await #expect(throws: DocsetInstallError.notInstalled(identifier: descriptor.identifier)) {
            try await installer.uninstall(descriptor)
        }
    }
}

/// Deliberately ignores task cancellation to verify that the installer checks
/// cancellation at its own stage boundary before it mutates installed state.
private actor CancellationIgnoringExtractor: ArchiveExtractor {
    private let indexData: Data
    private var started = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(indexData: Data) {
        self.indexData = indexData
    }

    func extract(
        archiveURL: URL,
        into destinationURL: URL,
        limits: ArchiveLimits,
        progress: (@Sendable (Int64) -> Void)?
    ) async throws -> ArchiveExtractionReport {
        started = true
        await withCheckedContinuation { continuation = $0 }
        try writeBundle(to: destinationURL)
        return ArchiveExtractionReport(entryCount: 3, totalBytesWritten: Int64(indexData.count))
    }

    func waitUntilExtractionStarted() async {
        while !started { await Task.yield() }
    }

    func finishExtraction() {
        continuation?.resume()
        continuation = nil
    }

    private func writeBundle(to destinationURL: URL) throws {
        let bundle = destinationURL.appending(path: "Fixture.docset", directoryHint: .isDirectory)
        let resources = bundle.appending(path: "Contents/Resources", directoryHint: .isDirectory)
        let documents = resources.appending(path: "Documents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": "dev.crux.fixture",
            "CFBundleName": "Fixture",
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: bundle.appending(path: "Contents/Info.plist"))
        try Data("<html></html>".utf8).write(to: documents.appending(path: "index.html"))
        try indexData.write(to: resources.appending(path: "docSet.dsidx"))
    }
}

/// Collects progress callbacks that arrive from the installer's executor.
private final class PhaseRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [InstallationPhase] = []

    var phases: [InstallationPhase] {
        lock.withLock { storage }
    }

    func record(_ phase: InstallationPhase) {
        lock.withLock { storage.append(phase) }
    }
}
