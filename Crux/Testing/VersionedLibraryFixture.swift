#if DEBUG
import CryptoKit
import CruxCore
import Foundation
import SQLite3

/// Tiny real indexes/archives for app-hosted tests; no network or production data.
struct VersionedLibraryFixture {
    let entry: CatalogEntry
    let downloads: [URL: Data]
    static let oldID = String(repeating: "1", count: 64)
    static let latestID = String(repeating: "2", count: 64)

    static func make(in root: URL, family: String = "python", name: String = "Python") throws -> Self {
        var releases: [[String: Any]] = [], downloads: [URL: Data] = [:]
        for old in [true, false] {
            let version = old ? "3.13.9" : "3.14.7", line = old ? "3.13" : "3.14"
            let id = family == "python" ? (old ? oldID : latestID) : String(repeating: old ? "3" : "4", count: 64)
            let variant = "\(family)-\(line.replacingOccurrences(of: ".", with: "-"))-en"
            let revision = old ? 1 : 2
            let directory = root.appending(path: variant)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let indexURL = directory.appending(path: "docSet.dsidx")
            var db: OpaquePointer?
            guard sqlite3_open(indexURL.path, &db) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
            defer { sqlite3_close(db) }
            guard sqlite3_exec(db, "CREATE TABLE searchIndex(id INTEGER PRIMARY KEY, name TEXT, type TEXT, path TEXT); INSERT INTO searchIndex VALUES(1, '\(old ? "oldAPI" : "newAPI")', 'Function', 'index.html')", nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
            let url = URL(string: "https://example.invalid/artifacts/\(id)/\(name).tgz")!
            let metadata: [String: Any] = [
                "name": name, "title": name, "version": version, "revision": revision,
                "sourceId": "dev.crux", "familyId": family, "variantId": variant, "versionLine": line,
                "language": "en", "identifier": "dev.crux.\(family)", "bundleName": name, "releaseId": id,
            ]
            let plist: [String: Any] = ["CFBundleIdentifier": "dev.crux.\(family)", "CFBundleName": name,
                                      "CFBundleShortVersionString": version, "dashIndexFilePath": "index.html"]
            let title = old ? "Old Python" : "Latest Python"
            let page = Data("<html><head><title>\(title)</title></head><body>\(old ? "OldOnlyContent" : "LatestOnlyContent")</body></html>".utf8)
            let files: [(String, Data)] = [
                ("meta.json", try JSONSerialization.data(withJSONObject: metadata)),
                ("Contents/Info.plist", try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)),
                ("Contents/Resources/docSet.dsidx", try Data(contentsOf: indexURL)),
                ("Contents/Resources/Documents/index.html", page),
                ("Contents/Resources/Documents/\(old ? "old-only" : "new-only").html", page),
            ]
            let archive = tar(files.map { ("\(name).docset/" + $0.0, $0.1) })
            downloads[url] = archive
            releases.append([
                "releaseId": id, "variantId": variant, "versionLine": line, "language": "en", "version": version,
                "revision": revision, "identifier": "dev.crux.\(family)", "publishedAt": "2026-09-27T00:00:00.000Z",
                "channel": "stable", "support": old ? "archived" : "supported",
                "artifact": ["url": url.absoluteString, "bytes": archive.count,
                             "sha256": SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined()],
            ])
        }
        let catalog: [String: Any] = ["schemaVersion": 1, "families": [[
            "sourceId": "dev.crux", "familyId": family, "title": name, "identifier": "dev.crux.\(family)",
            "bundleName": name, "defaultVariantId": "\(family)-3-14-en", "latestReleaseId": releases[1]["releaseId"]!, "releases": releases,
        ]]]
        let entries = try CatalogEntry.parseList(JSONSerialization.data(withJSONObject: catalog), provider: .versioned(
            catalogURL: URL(string: "https://example.invalid/catalog.json")!, sourceId: "dev.crux"))
        return Self(entry: entries[0], downloads: downloads)
    }

    /// Libarchive also accepts uncompressed tar in a .tgz download. Keeping
    /// fixtures uncompressed makes their on-disk contents easy to inspect.
    private static func tar(_ files: [(String, Data)]) -> Data {
        var archive = Data()
        for (path, bytes) in files {
            var header = [UInt8](repeating: 0, count: 512)
            func write(_ text: String, _ offset: Int) {
                for (index, byte) in text.utf8.enumerated() { header[offset + index] = byte }
            }
            write(path, 0); write("0000644", 100); write("0000000", 108); write("0000000", 116)
            write(String(format: "%011o", bytes.count), 124); write("00000000000", 136)
            for index in 148..<156 { header[index] = 32 }
            header[156] = 48; write("ustar", 257); write("00", 263)
            write(String(format: "%06o", header.reduce(0) { $0 + Int($1) }), 148)
            header[154] = 0; header[155] = 32
            archive.append(contentsOf: header); archive.append(bytes)
            archive.append(Data(count: (512 - bytes.count % 512) % 512))
        }
        archive.append(Data(count: 1024))
        return archive
    }
}

actor VersionedLibraryDownloadClient: DownloadClient {
    let files: [URL: Data]
    private let rejectedURL: URL?
    private var failing = false
    init(files: [URL: Data], rejectedURL: URL? = nil) {
        self.files = files
        self.rejectedURL = rejectedURL
    }
    func failDownloads() { failing = true }
    func download(from url: URL, to destinationURL: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws {
        guard !failing, url != rejectedURL, let data = files[url] else { throw URLError(.resourceUnavailable) }
        try data.write(to: destinationURL)
    }
}
#endif
