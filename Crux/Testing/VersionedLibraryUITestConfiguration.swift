#if DEBUG
import CruxCore
import Foundation

/// Only the explicitly isolated Beta UI-test process can create these inputs.
/// Downloads, SQLite, extraction, registry and SwiftUI remain real; only the
/// network boundary is replaced. No paths or preferences come from the caller.
struct VersionedLibraryUITestConfiguration {
    let catalog: any CatalogClient
    let downloads: any DownloadClient

    static func resolve(runtime: CruxAppRuntimeConfiguration) throws -> Self? {
        let arguments = ProcessInfo.processInfo.arguments
        guard AppIdentity.current.isBeta, runtime.isUITesting,
              arguments.contains("-crux-ui-testing"),
              arguments.contains("-crux-version-fixture"),
              let root = runtime.applicationSupportDirectory else { return nil }
        let python = try VersionedLibraryFixture.make(in: root.appending(path: "fixtures"))
        let sample = try VersionedLibraryFixture.make(in: root.appending(path: "fixtures"), family: "sample", name: "Sample")
        let entries = [python.entry, sample.entry]
        let oldURL = try python.entry.resolve(.pinnedRelease(VersionedLibraryFixture.oldID)).downloadURL
        return Self(
            catalog: VersionedUITestCatalog(
                entries: entries,
                offline: arguments.contains("-crux-fixture-offline"),
                withdrawOnRefresh: arguments.contains("-crux-fixture-withdraw")
            ),
            downloads: VersionedLibraryDownloadClient(
                files: python.downloads.merging(sample.downloads) { first, _ in first },
                rejectedURL: arguments.contains("-crux-fixture-failure") ? oldURL : nil
            )
        )
    }
}

private actor VersionedUITestCatalog: CatalogClient {
    let entries: [CatalogEntry]
    let offline: Bool
    let withdrawOnRefresh: Bool

    init(entries: [CatalogEntry], offline: Bool, withdrawOnRefresh: Bool) {
        self.entries = entries
        self.offline = offline
        self.withdrawOnRefresh = withdrawOnRefresh
    }

    func cachedSnapshot() -> CatalogSnapshot? {
        CatalogSnapshot(entries: entries, fetchedAt: .now, isFromCache: true)
    }

    func fetch(forceRefresh: Bool) throws -> CatalogSnapshot {
        if offline { throw URLError(.notConnectedToInternet) }
        let visible: [CatalogEntry]
        if withdrawOnRefresh {
            // Round-trip the real contract with only its explicit latest releases.
            var families = try entries.map { entry -> [String: Any] in
                let data = try JSONEncoder().encode(entry.releaseFamily!)
                return try JSONSerialization.jsonObject(with: data) as! [String: Any]
            }
            for index in families.indices {
                families[index]["releases"] = (families[index]["releases"] as! [[String: Any]]).filter {
                    $0["releaseId"] as? String == families[index]["latestReleaseId"] as? String
                }
            }
            visible = try CatalogEntry.parseList(JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "families": families]), provider: .versioned(catalogURL: URL(string: "https://example.invalid/catalog.json")!, sourceId: "dev.crux"))
        } else { visible = entries }
        return CatalogSnapshot(entries: visible, fetchedAt: .now, isFromCache: false)
    }
}
#endif
