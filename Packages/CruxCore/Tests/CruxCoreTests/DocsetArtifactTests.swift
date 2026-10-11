import Foundation
import Testing

@testable import CruxCore

struct DocsetArtifactTests {
    @Test
    func recognizesDocsetBundlesAndSupportedArchives() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let bundle = root.appending(path: "Python.docset", directoryHint: .isDirectory)
        let tgz = root.appending(path: "Python.tgz", directoryHint: .notDirectory)
        let tarGzip = root.appending(path: "Python.tar.gz", directoryHint: .notDirectory)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        #expect(FileManager.default.createFile(atPath: tgz.path, contents: Data()))
        #expect(FileManager.default.createFile(atPath: tarGzip.path, contents: Data()))

        #expect(try DocsetArtifact.detect(at: bundle) == .bundle(bundle.standardizedFileURL))
        #expect(try DocsetArtifact.detect(at: tgz) == .archive(tgz.standardizedFileURL, format: .tarGzip))
        #expect(try DocsetArtifact.detect(at: tarGzip) == .archive(tarGzip.standardizedFileURL, format: .tarGzip))
    }

    @Test
    func rejectsUnsupportedArtifacts() throws {
        let file = FileManager.default.temporaryDirectory
            .appending(path: "unsupported-\(UUID().uuidString).txt", directoryHint: .notDirectory)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(FileManager.default.createFile(atPath: file.path, contents: Data()))

        #expect(throws: DocsetArtifactError.unsupportedFormat(file.standardizedFileURL)) {
            try DocsetArtifact.detect(at: file)
        }
    }
}
