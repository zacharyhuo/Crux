import CryptoKit
import Foundation

@testable import CruxCore

struct TestReleaseFixture {
    let bundle: URL
    let archive: URL
    let entry: CatalogEntry
    let target: DocsetInstallTarget

    static func make(in root: URL, old: Bool = false, pinned: Bool = false) throws -> Self {
        let base = root.appending(path: UUID().uuidString)
        let version = old ? "3.13.9" : "3.14.7"
        let line = old ? "3.13" : "3.14"
        let releaseId = String(repeating: old ? "1" : "2", count: 64)
        let bundle = try TestDocsetFixture.create(
            in: base, identifier: "dev.crux.python", version: version, revision: old ? 1 : 2,
            symbols: [TestSymbol(old ? "oldAPI" : "newAPI", type: "Function", path: "index.html")]
        )
        let metadataURL = bundle.appending(path: "meta.json")
        var metadata = try requireObject(Data(contentsOf: metadataURL))
        metadata.merge([
            "sourceId": "dev.crux", "familyId": "python", "variantId": "python-\(line.replacingOccurrences(of: ".", with: "-"))-en",
            "versionLine": line, "language": "en", "identifier": "dev.crux.python",
            "bundleName": "Python", "releaseId": releaseId,
        ]) { _, value in value }
        try JSONSerialization.data(withJSONObject: metadata).write(to: metadataURL)
        let paths = ["meta.json", "Contents/Info.plist", "Contents/Resources/docSet.dsidx", "Contents/Resources/Documents/index.html"]
        let archive = try TestArchiveFixture.writeTarGzip(try paths.map {
            .file("Python.docset/\($0)", bytes: try Data(contentsOf: bundle.appending(path: $0)))
        }, to: base.appending(path: "Python.tgz"))
        let bytes = try Data(contentsOf: archive)
        let fixtureURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "ContractFixtures/version-catalog-v1.json")
        var catalog = try requireObject(Data(contentsOf: fixtureURL))
        var families = catalog["families"] as! [[String: Any]]
        var releases = families[0]["releases"] as! [[String: Any]]
        let index = old ? 0 : 1
        releases[index]["artifact"] = [
            "url": "https://example.invalid/artifacts/\(releaseId)/Python.tgz",
            "sha256": SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), "bytes": bytes.count,
        ]
        families[0]["releases"] = releases
        catalog["families"] = families
        let entry = try CatalogEntry.parseList(JSONSerialization.data(withJSONObject: catalog), provider: .versioned(
            catalogURL: URL(string: "https://example.invalid/catalog.json")!, sourceId: "dev.crux"
        ))[0]
        return Self(bundle: bundle, archive: archive, entry: entry,
                    target: try DocsetInstallTarget(entry: entry, selection: old || pinned ? .pinnedRelease(releaseId) : .latest))
    }
}

// Kept in test utilities; malformed fixture JSON is a test setup error.
private func requireObject(_ data: Data) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: data) as! [String: Any]
}
