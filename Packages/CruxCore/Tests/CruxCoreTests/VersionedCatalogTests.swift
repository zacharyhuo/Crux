import CryptoKit
import Foundation
import Testing

@testable import CruxCore

struct VersionedCatalogTests {
    private let oldID = String(repeating: "1", count: 64)
    private let latestID = String(repeating: "2", count: 64)
    private var provider: CatalogProvider {
        .versioned(catalogURL: URL(string: "https://example.invalid/catalog.json")!, sourceId: "dev.crux")
    }

    private func fixture() throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "ContractFixtures/version-catalog-v1.json")
        return try Data(contentsOf: url)
    }

    @Test
    func resolvesLatestAndPinnedReleasesFromTheSharedSupplyContract() throws {
        let data = try fixture()
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(hash == "097af598938773ab257a30b09640ce2d26b6ee0c84530053b24801db7d391586")
        let entries = try CatalogEntry.parseList(data, provider: provider)
        let entry = try #require(entries.first)
        #expect(entries.count == 1)
        #expect(entry.id == "dev.crux/python")
        #expect(entry.releases.count == 2)
        #expect(entry.supportsVersionSelection)
        let latest = try entry.resolve(.latest)
        #expect(latest.id == latestID)
        #expect(latest.revision == 2)
        #expect(latest.sha256 == String(repeating: "b", count: 64))
        #expect(latest.bytes == 23456)
        let old = try entry.resolve(.pinnedRelease(oldID))
        #expect(old.id == oldID)
        #expect(old.identifier == "dev.crux.python")
        #expect(old.downloadURL.absoluteString == "https://example.invalid/artifacts/python-3-13-en/\(oldID)/Python.tgz")
        #expect(old.downloadURL != latest.downloadURL)
        #expect(throws: CatalogError.self) { try entry.resolve(.pinnedRelease("unknown")) }
    }

    @Test
    func fourComponentStableJavaUpdatesKeepTheirExactVersionAndOrdering() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "ContractFixtures/version-catalog-java-v1.json")
        let entry = try #require(CatalogEntry.parseList(Data(contentsOf: url), provider: provider).first)
        let latest = try entry.resolve(.latest)
        let previous = try entry.resolve(.pinnedRelease(String(repeating: "3", count: 64)))
        #expect(latest.version == "25.0.4.1")
        #expect(latest.advertisedVersion > previous.advertisedVersion)
        #expect(DocsetVersion(version: "25.0.4.1", revision: 1) > DocsetVersion(version: "25.0.4", revision: 99))
        #expect(DocsetVersion(version: "25.0.5", revision: 1) > latest.advertisedVersion)
        for invalid in ["25.0.4.1.1", "25.0.4.01", "25.0.4.1-ea"] {
            #expect(!ReleaseValidation.stableVersion(invalid))
        }
    }

    @Test
    func explicitProviderTrustPreventsAResponseFromClaimingAnotherSource() throws {
        let other = CatalogProvider.versioned(catalogURL: provider.catalogURL, sourceId: "another.source")
        #expect(throws: CatalogError.self) { try CatalogEntry.parseList(fixture(), provider: other) }
        #expect(throws: CatalogError.self) { try CatalogEntry.parseList(fixture(), provider: .zeal) }
    }

    @Test
    func rejectsInvalidAndWithdrawnWireEntriesInsteadOfGuessingAnotherLatest() throws {
        for mutation in ["unknown-latest", "duplicate", "withdrawn", "checksum", "bytes", "http", "wrong-variant", "unknown-schema"] {
            var catalog = try #require(JSONSerialization.jsonObject(with: fixture()) as? [String: Any])
            var families = try #require(catalog["families"] as? [[String: Any]])
            var family = families[0]
            var releases = try #require(family["releases"] as? [[String: Any]])
            var artifact = try #require(releases[0]["artifact"] as? [String: Any])
            switch mutation {
            case "unknown-latest": family["latestReleaseId"] = String(repeating: "f", count: 64)
            case "duplicate": releases.append(releases[0])
            case "withdrawn": releases[0]["status"] = "withdrawn"
            case "checksum": artifact["sha256"] = "invalid"
            case "bytes": artifact["bytes"] = 0
            case "http": artifact["url"] = "http://example.invalid/unsafe.tgz"
            case "wrong-variant": family["defaultVariantId"] = "python-3-13-en"
            case "unknown-schema": catalog["schemaVersion"] = 99
            default: Issue.record("Unexpected mutation")
            }
            releases[0]["artifact"] = artifact
            family["releases"] = releases
            families[0] = family
            catalog["families"] = families
            let data = try JSONSerialization.data(withJSONObject: catalog)
            #expect(throws: CatalogError.self) { try CatalogEntry.parseList(data, provider: provider) }
        }
    }

    @Test
    func legacyCatalogRemainsSingleVersionWithoutInventingHistoricalURLs() throws {
        let data = Data(#"[{"name":"Python","versions":["3.14","3.13"]}]"#.utf8)
        let entry = try #require(CatalogEntry.parseList(data, provider: .zeal).first)
        #expect(!entry.supportsVersionSelection)
        #expect(entry.releases.isEmpty)
        #expect(entry.downloadURL.lastPathComponent == "latest")
        #expect(throws: CatalogError.self) { try entry.resolve(.pinnedRelease(oldID)) }
    }

    @Test
    func catalogAndSelectionPoliciesRoundTripWithoutLosingThePinnedRevision() throws {
        let entry = try #require(CatalogEntry.parseList(fixture(), provider: provider).first)
        let copy = try JSONDecoder().decode(CatalogEntry.self, from: JSONEncoder().encode(entry))
        #expect(copy == entry)
        #expect(try copy.resolve(.pinnedRelease(oldID)).id == oldID)
        for policy in [DocsetSelectionPolicy.latest, .pinnedRelease(oldID)] {
            #expect(try JSONDecoder().decode(DocsetSelectionPolicy.self, from: JSONEncoder().encode(policy)) == policy)
        }
        let legacy = Data(#"{"name":"Python","title":"Python","sourceId":"com.kapeli","downloadURL":"https://example.invalid/latest","keywords":[]}"#.utf8)
        #expect(try JSONDecoder().decode(CatalogEntry.self, from: legacy).releases.isEmpty)
    }

    @Test
    func independentCatalogCachesAreBoundToTheirProviderAndAcceptAnExplicitEmptySnapshot() async throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = RemoteCatalogClient(provider: provider, httpClient: VersionCatalogHTTP(data: try fixture()), cacheDirectory: root)
        let first = try await client.fetch(forceRefresh: true)
        #expect(first.entries.count == 1)
        #expect(try first.entries[0].resolve(.latest).id == latestID)
        let wrongProvider = RemoteCatalogClient(httpClient: VersionCatalogHTTP(data: Data()), cacheDirectory: root)
        #expect(await wrongProvider.cachedSnapshot() == nil)
        let restored = RemoteCatalogClient(provider: provider, httpClient: VersionCatalogHTTP(data: Data()), cacheDirectory: root)
        let cached = try #require(await restored.cachedSnapshot())
        #expect(try cached.entries[0].resolve(.pinnedRelease(oldID)).id == oldID)
        let withdrawn = RemoteCatalogClient(provider: provider, httpClient: VersionCatalogHTTP(data: Data(#"{"schemaVersion":1,"families":[]}"#.utf8)), cacheDirectory: root)
        let empty = try await withdrawn.fetch(forceRefresh: true)
        #expect(empty.entries.isEmpty)
        #expect(!empty.isFromCache)
    }
}

private struct VersionCatalogHTTP: HTTPClient {
    let data: Data
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
}
