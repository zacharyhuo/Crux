import Foundation
import Testing

@testable import CruxCore

struct CatalogClientTests {
    private let sampleJSON = """
    [
      {
        "name": "Python_3",
        "title": "Python 3",
        "sourceId": "com.kapeli",
        "revision": "12",
        "versions": ["3.13.0", "3.12.0"],
        "icon": "not-base64",
        "icon2x": "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9WlS5b8AAAAASUVORK5CYII=",
        "extra": { "keywords": ["python", "py"] },
        "unknownField": true
      },
      {
        "name": "Go",
        "title": "Go",
        "sourceId": "com.kapeli",
        "revision": 4,
        "versions": ["1.22"]
      }
    ]
    """.data(using: .utf8)!

    @Test
    func parsesKnownFieldsAndIgnoresUnknownOnes() throws {
        let entries = try CatalogEntry.parseList(sampleJSON, provider: .zeal)
        #expect(entries.map(\.name) == ["Python_3", "Go"])
        #expect(entries[0].title == "Python 3")
        #expect(entries[0].revision == 12)
        #expect(entries[0].version == "3.13.0")
        #expect(entries[0].keywords.contains("python"))
        #expect(entries[0].downloadURL.scheme == "https")
        #expect(entries[0].downloadURL.absoluteString.contains("Python_3"))
        #expect(entries[0].iconData != nil)
        #expect(try TransferRequest.catalog(entries[0]).fallbackIconData == entries[0].iconData)
    }

    @Test
    func rejectsCatalogIconsThatAreInvalidOrLargerThanTheSafetyLimit() throws {
        let oversized = Data(repeating: 0x41, count: CatalogEntry.maximumIconBytes + 1).base64EncodedString()
        let json = Data("""
        [{"name":"Unsafe","icon2x":"\(oversized)","icon":"bad"}]
        """.utf8)

        let entry = try #require(CatalogEntry.parseList(json, provider: .zeal).first)

        #expect(entry.iconData == nil)
    }

    @Test
    func rejectsAnImageSignatureWithoutDecodableImageContent() throws {
        let truncatedPNG = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
            .base64EncodedString()
        let json = Data("""
        [{"name":"Truncated","icon2x":"\(truncatedPNG)"}]
        """.utf8)

        let entry = try #require(CatalogEntry.parseList(json, provider: .zeal).first)

        #expect(entry.iconData == nil)
    }

    @Test
    func skipsNullVersionElementsWithoutRejectingTheCatalog() throws {
        // The live Zeal catalog contains contributed docsets whose `versions`
        // arrays mix strings and nulls. One malformed element must not make all
        // otherwise valid docsets disappear from Crux.
        let liveShape = Data("""
        [
          {
            "name": "Apache_Commons_Collections_Contrib",
            "title": "Apache Commons Collections",
            "sourceId": "com.kapeli",
            "revision": "0",
            "versions": [null, "4.0", "3.2.1"]
          }
        ]
        """.utf8)

        let entries = try CatalogEntry.parseList(liveShape, provider: .zeal)

        #expect(entries.count == 1)
        #expect(entries[0].version == "4.0")
    }

    @Test
    func dropsCatalogEntriesWhenTheProviderUsesAnInsecureDownloadRoot() throws {
        let provider = CatalogProvider(
            catalogURL: URL(string: "https://example.com/catalog.json")!,
            downloadRootURL: URL(string: "http://example.com/downloads")!
        )

        #expect(try CatalogEntry.parseList(sampleJSON, provider: provider).isEmpty)
    }

    @Test
    func redirectPolicyAllowsOnlyHTTPSDestinations() {
        let secure = URLRequest(url: URL(string: "https://mirror.example.com/docset.tgz")!)
        let insecure = URLRequest(url: URL(string: "http://mirror.example.com/docset.tgz")!)

        #expect(HTTPSRedirectPolicy.allows(secure))
        #expect(!HTTPSRedirectPolicy.allows(insecure))
    }

    @Test
    func refreshFallsBackToCacheWhenTheNetworkFails() async throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appending(path: "Cache", directoryHint: .isDirectory)

        let client = RemoteCatalogClient(
            httpClient: StubHTTPClient(result: .success(http(sampleJSON))),
            cacheDirectory: cache
        )
        let first = try await client.fetch(forceRefresh: true)
        #expect(first.entries.count == 2)
        #expect(!first.isFromCache)

        let failing = RemoteCatalogClient(
            httpClient: StubHTTPClient(result: .failure(CatalogError.unavailable("offline"))),
            cacheDirectory: cache
        )
        let cached = try await failing.fetch(forceRefresh: true)
        #expect(cached.isFromCache)
        #expect(cached.entries.map(\.name) == ["Python_3", "Go"])
    }

    @Test
    func onlyLegacyCacheFilesRequestAnArtworkMigration() async throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appending(path: "Cache", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let legacy = LegacyStoredCatalog(entries: [], fetchedAt: .distantPast)
        try JSONEncoder().encode(legacy).write(to: cache.appending(path: "catalog.json"))

        let legacyClient = RemoteCatalogClient(
            httpClient: StubHTTPClient(result: .failure(CatalogError.unavailable("unused"))),
            cacheDirectory: cache
        )
        #expect(await legacyClient.cachedSnapshot()?.requiresArtworkRefresh == true)

        let currentClient = RemoteCatalogClient(
            httpClient: StubHTTPClient(result: .success(http(sampleJSON))),
            cacheDirectory: cache
        )
        _ = try await currentClient.fetch(forceRefresh: true)
        #expect(await currentClient.cachedSnapshot()?.requiresArtworkRefresh == false)
    }

    @Test
    func aFailedFirstFetchDoesNotInventACache() async throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = RemoteCatalogClient(
            httpClient: StubHTTPClient(result: .failure(URLError(.notConnectedToInternet))),
            cacheDirectory: root
        )
        await #expect(throws: CatalogError.self) {
            try await client.fetch(forceRefresh: true)
        }
        #expect(await client.cachedSnapshot() == nil)
    }
}

private struct LegacyStoredCatalog: Encodable {
    var entries: [CatalogEntry]
    var fetchedAt: Date
}

struct DashFeedParserTests {
    @Test
    func parsesVersionAndRewritesKapeliHTTPMirrorsToHTTPS() throws {
        let xml = """
        <entry>
          <version>3.14.6</version>
          <revision>2</revision>
          <url>http://london.kapeli.com/feeds/Python.tgz</url>
          <url>https://tokyo.kapeli.com/feeds/Python.tgz</url>
        </entry>
        """.data(using: .utf8)!
        let feedURL = URL(string: "https://kapeli.com/feeds/Python.xml")!
        let feed = try DashFeedParser.parse(xml: xml, feedURL: feedURL)

        #expect(feed.name == "Python")
        #expect(feed.version == "3.14.6")
        #expect(feed.revision == 2)
        #expect(feed.downloadURL.scheme == "https")
        #expect(feed.downloadURL.host == "london.kapeli.com")
    }

    @Test
    func rejectsPlainHTTPDownloadURLsFromUnknownHosts() throws {
        let xml = """
        <entry>
          <version>1.0</version>
          <url>http://example.invalid/Evil.tgz</url>
        </entry>
        """.data(using: .utf8)!
        #expect(throws: DashFeedError.insecureDownloadURL(URL(string: "http://example.invalid/Evil.tgz")!)) {
            try DashFeedParser.parse(xml: xml, feedURL: URL(string: "https://example.invalid/feed.xml")!)
        }
    }

    @Test
    func rejectsAFeedServedOverHTTP() throws {
        let xml = Data("<entry><version>1</version><url>https://example.com/a.tgz</url></entry>".utf8)
        #expect(throws: DashFeedError.notHTTPS(URL(string: "http://example.com/feed.xml")!)) {
            try DashFeedParser.parse(xml: xml, feedURL: URL(string: "http://example.com/feed.xml")!)
        }
    }

    @Test
    func rejectsMissingFieldsAndMalformedXML() throws {
        let feedURL = URL(string: "https://example.com/feed.xml")!
        #expect(throws: DashFeedError.missingField("version")) {
            try DashFeedParser.parse(
                xml: Data("<entry><url>https://example.com/a.tgz</url></entry>".utf8),
                feedURL: feedURL
            )
        }
        #expect(throws: DashFeedError.invalidXML) {
            try DashFeedParser.parse(xml: Data("not xml".utf8), feedURL: feedURL)
        }
    }

    @Test
    func registryRejectsDuplicateFeeds() async throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = try DocsetRegistry(databaseURL: root.appending(path: "Crux.sqlite"))
        let feed = DashFeed(
            feedURL: URL(string: "https://example.com/Python.xml")!,
            name: "Python",
            version: "1",
            revision: 1,
            downloadURL: URL(string: "https://example.com/Python.tgz")!
        )
        try await registry.saveFeed(feed)
        await #expect(throws: DashFeedError.duplicateFeed) {
            try await registry.saveFeed(DashFeed(
                feedURL: feed.feedURL,
                name: "Other",
                version: "2",
                revision: nil,
                downloadURL: URL(string: "https://example.com/Other.tgz")!
            ))
        }
    }
}

struct DocsetVersionTests {
    @Test
    func comparesDottedVersionsNumericallyAndFallsBackToRevision() {
        #expect(DocsetVersion(version: "1.9", revision: 1) < DocsetVersion(version: "1.10", revision: 0))
        #expect(DocsetVersion(version: "2.0", revision: 1) < DocsetVersion(version: "2.0", revision: 2))
        #expect(!(DocsetVersion(version: "2.0-beta", revision: 0) < DocsetVersion(version: "2.0-alpha", revision: 0)))
    }
}

private struct StubHTTPClient: HTTPClient {
    let result: Result<(Data, URLResponse), any Error>

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try result.get()
    }
}

private func http(_ data: Data, status: Int = 200) -> (Data, URLResponse) {
    let response = HTTPURLResponse(
        url: URL(string: "https://api.zealdocs.org/v1/docsets")!,
        statusCode: status,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/json"]
    )!
    return (data, response)
}
