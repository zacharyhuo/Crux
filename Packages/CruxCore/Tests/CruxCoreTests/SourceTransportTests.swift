import Foundation
import Network
import Testing

@testable import CruxCore

struct SourceTransportTests {
    // Requiring HTTPS for an explicitly consented literal LAN endpoint breaks these requests.
    @Test(arguments: [
        "http://localhost:8080/catalog.json", "http://LOCALHOST/feed.xml",
        "http://127.0.0.1/a", "http://127.255.255.254/a",
        "http://10.0.0.1/a", "http://10.255.255.254/a",
        "http://172.16.0.1/a", "http://172.31.255.254/a",
        "http://192.168.0.1/a", "http://192.168.255.254/a",
        "http://[::1]/a", "http://[fc00::1]/a", "http://[fdff::1234]/a",
        "http://[::ffff:127.0.0.1]/a", "http://[::ffff:192.168.1.2]/a",
        "http://[::ffff:ac10:1]/a",
    ])
    func localHTTPAllowsOnlyExplicitLocalAddresses(_ address: String) throws {
        try SourceTransportPolicy.localHTTP.validate(#require(URL(string: address)))
    }

    // Treating arbitrary DNS, numeric shorthand, or a reserved address as local breaks this boundary.
    @Test(arguments: [
        "http://example.invalid/a", "http://lan.internal/a", "http://localhost.evil.invalid/a",
        "http://localhost./a", "http://%6cocalhost/a",
        "http://8.8.8.8/a", "http://172.15.255.255/a", "http://172.32.0.1/a",
        "http://192.167.255.255/a", "http://192.169.0.1/a", "http://100.64.0.1/a",
        "http://0.0.0.0/a", "http://169.254.1.2/a", "http://224.0.0.1/a", "http://255.255.255.255/a",
        "http://127.1/a", "http://2130706433/a", "http://0177.0.0.1/a",
        "http://0x7f000001/a", "http://127.000.0.1/a", "http://127.0.0.1./a",
        "http://[::]/a", "http://[fe80::1]/a", "http://[ff02::1]/a",
        "http://[::1%25en0]/a", "http://[::ffff:8.8.8.8]/a", "http://[::ffff:169.254.1.1]/a",
        "http://[::ffff:0.0.0.0]/a", "http://[::127.0.0.1]/a",
        "http://user:password@localhost/a", "http://@127.0.0.1/a",
    ])
    func localHTTPRejectsNonlocalAndAmbiguousAddresses(_ address: String) throws {
        #expect(throws: (any Error).self) {
            try SourceTransportPolicy.localHTTP.validate(#require(URL(string: address)))
        }
    }

    @Test(arguments: ["http://localhost/a", "file:///tmp/a", "/relative/a", "https:///a",
                      "https://example.invalid:99999/a", "https://user:password@example.invalid/a"])
    func strictPolicyRejectsUnsafeInitialURLs(_ address: String) throws {
        #expect(throws: (any Error).self) {
            try SourceTransportPolicy.strictHTTPS.validate(#require(URL(string: address)))
        }
    }

    @Test(arguments: ["https://127.1/a", "https://2130706433/a", "https://0177.0.0.1/a",
                      "https://0x7f000001/a", "https://[abc]/a", "https://[:::]/a",
                      "https://example..invalid/a", "https://.example.invalid/a",
                      "https://example.invalid:/a", "https://127.0.0.1./a"])
    func policiesRejectMalformedAuthoritiesEvenOverHTTPS(_ address: String) throws {
        let url = try #require(URL(string: address))
        for policy in [SourceTransportPolicy.strictHTTPS, .localHTTP] {
            #expect(throws: SourceTransportError.invalidURL) { try policy.validate(url) }
        }
    }

    @Test
    func localConsentNeverAllowsAnHTTPSDowngrade() throws {
        let secure = try #require(URL(string: "https://example.invalid/a"))
        let local = try #require(URL(string: "http://localhost/a"))
        #expect(throws: SourceTransportError.httpsDowngrade) {
            try SourceTransportPolicy.localHTTP.validateRedirect(from: secure, to: local)
        }
        try SourceTransportPolicy.localHTTP.validateRedirect(from: local, to: secure)
        try SourceTransportPolicy.strictHTTPS.validateRedirect(
            from: secure, to: #require(URL(string: "https://mirror.invalid/a")))
    }

    @Test
    func policiesDecodeThePersistentSourceConsent() throws {
        let decoder = JSONDecoder()
        #expect(try decoder.decode(SourceTransportPolicy.self, from: Data(#""strictHTTPS""#.utf8)) == .strictHTTPS)
        #expect(try decoder.decode(SourceTransportPolicy.self, from: Data(#""localHTTP""#.utf8)) == .localHTTP)
        #expect(try decoder.decode(SourceTransportPolicy.self, from: JSONEncoder().encode(SourceTransportPolicy.localHTTP)) == .localHTTP)
        #expect(throws: (any Error).self) {
            try decoder.decode(SourceTransportPolicy.self, from: Data(#""allowEverything""#.utf8))
        }
    }

    // A global HTTP relaxation would break strict defaults; ignoring task consent breaks the local request.
    @Test(.timeLimit(.minutes(1)))
    func realHTTPRequestsRequireLocalConsent() async throws {
        try await withTransportServer { server in
            let url = try await server.url("/bytes")
            let session = URLSession(configuration: .ephemeral)
            defer { session.invalidateAndCancel() }
            await #expect(throws: (any Error).self) {
                try await URLSessionHTTPClient(session: session).data(for: URLRequest(url: url))
            }
            let client = URLSessionHTTPClient(session: session, transportPolicy: .localHTTP)
            let (data, response) = try await client.data(for: URLRequest(url: url))
            #expect(data == Data("archive payload".utf8))
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func realHTTPRedirectsRejectPublicAndCredentialEndpoints() async throws {
        try await withTransportServer { server in
            let session = URLSession(configuration: .ephemeral)
            defer { session.invalidateAndCancel() }
            let client = URLSessionHTTPClient(session: session, transportPolicy: .localHTTP)
            let (data, _) = try await client.data(for: URLRequest(url: server.url("/redirect-local")))
            #expect(data == Data("archive payload".utf8))
            for path in ["/redirect-public", "/redirect-credentials"] {
                await #expect(throws: (any Error).self) {
                    try await client.data(for: URLRequest(url: server.url(path)))
                }
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func downloadsScopeConsentToEachTaskAndKeepTheOldTrailingClosureAPI() async throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try await withTransportServer { server in
            let client: any DownloadClient = URLSessionDownloadClient(configuration: .ephemeral)
            let url = try await server.url("/bytes")
            let rejected = root.appending(path: "rejected.tgz")
            await #expect(throws: (any Error).self) {
                try await client.download(from: url, to: rejected) { _, _ in }
            }
            let destination = root.appending(path: "allowed.tgz")
            try await client.download(from: url, to: destination, progress: { _, _ in }, transportPolicy: .localHTTP)
            #expect(try Data(contentsOf: destination) == Data("archive payload".utf8))
            await #expect(throws: (any Error).self) {
                try await client.download(from: url, to: rejected) { _, _ in }
            }
            #expect(!FileManager.default.fileExists(atPath: rejected.path))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func realCatalogDefaultClientHonorsSourceConsent() async throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try await withTransportServer { server in
            let provider = try await CatalogProvider(catalogURL: server.url("/catalog"), downloadRootURL: server.url("/d"))
            let strict = RemoteCatalogClient(provider: provider, cacheDirectory: root)
            await #expect(throws: (any Error).self) { try await strict.fetch(forceRefresh: true) }
            let allowed = RemoteCatalogClient(provider: provider, cacheDirectory: root, transportPolicy: .localHTTP)
            let snapshot = try await allowed.fetch(forceRefresh: true)
            #expect(snapshot.entries.map(\.name) == ["Local"])
            #expect(snapshot.entries.first?.downloadURL.absoluteString == provider.downloadRootURL.absoluteString + "/com.kapeli/Local/latest")
            #expect(await strict.cachedSnapshot() == nil)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func realFeedDefaultClientHonorsSourceConsentWithoutGenericUpgrading() async throws {
        try await withTransportServer { server in
            let feedURL = try await server.url("/feed")
            await #expect(throws: (any Error).self) { try await DashFeedClient().fetch(feedURL: feedURL) }
            let client = DashFeedClient(transportPolicy: .localHTTP)
            let feed = try await client.fetch(feedURL: feedURL)
            #expect(feed.version == "1.2")
            #expect(feed.downloadURL == (try await server.url("/bytes")))
            await #expect(throws: (any Error).self) {
                try await client.fetch(feedURL: server.url("/feed-public"))
            }
        }
    }

    // A transport double bypasses URLSession, so these clients must validate its final URL themselves.
    @Test(arguments: ["http://localhost/catalog", "https://user:password@example.invalid/catalog"])
    func catalogRejectsUntrustedFinalResponseURLs(_ address: String) async throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = RemoteCatalogClient(httpClient: TransportHTTPResponse(
            data: Data(#"[{"name":"Local"}]"#.utf8), finalURL: try #require(URL(string: address))), cacheDirectory: root)
        await #expect(throws: (any Error).self) { try await client.fetch(forceRefresh: true) }
        #expect(await client.cachedSnapshot() == nil)
    }

    @Test(arguments: ["http://localhost/feed", "https://user:password@example.invalid/feed"])
    func feedRejectsUntrustedFinalResponseURLs(_ address: String) async throws {
        let client = DashFeedClient(httpClient: TransportHTTPResponse(
            data: Data("<entry><version>1</version><url>https://example.invalid/a.tgz</url></entry>".utf8),
            finalURL: try #require(URL(string: address))))
        await #expect(throws: (any Error).self) {
            try await client.fetch(feedURL: #require(URL(string: "https://example.invalid/feed")))
        }
    }

    @Test
    func catalogCacheDoesNotCrossTransportConsent() async throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let response = TransportHTTPResponse(data: Data(#"[{"name":"Local"}]"#.utf8), finalURL: CatalogProvider.zeal.catalogURL)
        let local = RemoteCatalogClient(httpClient: response, cacheDirectory: root, transportPolicy: .localHTTP)
        _ = try await local.fetch(forceRefresh: true)
        #expect(await local.cachedSnapshot()?.entries.first?.name == "Local")
        let strict = RemoteCatalogClient(httpClient: response, cacheDirectory: root)
        #expect(await strict.cachedSnapshot() == nil)
    }

    @Test
    func strictDefaultsReadPrePolicyCachesWhileLocalConsentDoesNot() async throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // Literal identity produced by the pre-policy Zeal cache format, independent of current helpers.
        let data = Data(#"{"schemaVersion":3,"providerIdentity":"58b086838e141dc5802d234a422e7ab4ff3fc7a4367dde57a2f31df722fa14be","entries":[{"name":"Legacy","title":"Legacy","sourceId":"com.kapeli","downloadURL":"https://go.zealdocs.org/d/com.kapeli/Legacy/latest","keywords":[]}],"fetchedAt":0}"#.utf8)
        try data.write(to: root.appending(path: "catalog.json"))
        let strict = RemoteCatalogClient(cacheDirectory: root)
        #expect(await strict.cachedSnapshot()?.entries.first?.name == "Legacy")
        let local = RemoteCatalogClient(cacheDirectory: root, transportPolicy: .localHTTP)
        #expect(await local.cachedSnapshot() == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func downloadRedirectFailuresPreserveExistingDestination() async throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try await withTransportServer { server in
            let configuration = URLSessionConfiguration.background(withIdentifier: "CruxCoreTests.transport.\(UUID())")
            let client = URLSessionDownloadClient(configuration: configuration, transportPolicy: .localHTTP)
            let destination = root.appending(path: "existing.tgz")
            try Data("previous archive".utf8).write(to: destination)
            for path in ["/redirect-public", "/redirect-credentials"] {
                await #expect(throws: SourceTransportError.self) {
                    try await client.download(from: server.url(path), to: destination) { _, _ in }
                }
                #expect(try Data(contentsOf: destination) == Data("previous archive".utf8))
            }
            try await client.download(from: server.url("/redirect-local"), to: destination) { _, _ in }
            #expect(try Data(contentsOf: destination) == Data("archive payload".utf8))
        }
    }

    @Test
    func legacyDownloadConformersValidateBeforeDelegating() async throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let client: any DownloadClient = LegacyTransportDownload()
        let destination = root.appending(path: "legacy.tgz")
        try await client.download(from: #require(URL(string: "http://localhost/a")), to: destination,
                                  progress: { _, _ in }, transportPolicy: .localHTTP)
        #expect(try Data(contentsOf: destination) == Data("legacy archive".utf8))
        let rejected = root.appending(path: "rejected.tgz")
        await #expect(throws: SourceTransportError.httpsRequired) {
            try await client.download(from: #require(URL(string: "http://localhost/a")), to: rejected,
                                      progress: { _, _ in }, transportPolicy: .strictHTTPS)
        }
        await #expect(throws: SourceTransportError.localHTTPRequired) {
            try await client.download(from: #require(URL(string: "http://example.invalid/a")), to: rejected,
                                      progress: { _, _ in }, transportPolicy: .localHTTP)
        }
        #expect(!FileManager.default.fileExists(atPath: rejected.path))
    }

    @Test(.timeLimit(.minutes(1)))
    func URLSessionClientsRejectCredentialsAndValidateFinalEndpoints() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TransportFinalURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let http = URLSessionHTTPClient(session: session, transportPolicy: .localHTTP)
        await #expect(throws: SourceTransportError.credentialsNotAllowed) {
            try await http.data(for: URLRequest(url: #require(URL(string: "https://user:password@example.invalid/a"))))
        }
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let download = URLSessionDownloadClient(configuration: configuration, transportPolicy: .localHTTP)
        for path in ["downgrade", "credentials"] {
            let url = try #require(URL(string: "https://example.invalid/\(path)"))
            let expected: SourceTransportError = path == "downgrade" ? .httpsDowngrade : .credentialsNotAllowed
            await #expect(throws: expected) { try await http.data(for: URLRequest(url: url)) }
            let destination = root.appending(path: path + ".tgz")
            await #expect(throws: expected) {
                try await download.download(from: url, to: destination) { _, _ in }
            }
            #expect(!FileManager.default.fileExists(atPath: destination.path))
        }
    }

    // Removing credential validation must make this fail, even for an otherwise secure URL.
    @Test(arguments: [
        "https://user:password@example.invalid/archive.tgz",
        "https://user@example.invalid/archive.tgz",
        "http://user:password@london.kapeli.com/archive.tgz",
    ])
    func feedArchiveURLsRejectCredentials(_ address: String) throws {
        let url = try #require(URL(string: address))
        #expect(throws: (any Error).self) {
            try DashFeedParser.requireHTTPS(url)
        }
    }
}

private func withTransportServer(_ body: (TransportFixtureServer) async throws -> Void) async throws {
    let server = TransportFixtureServer()
    try await server.start()
    do {
        try await body(server)
        await server.stop()
    } catch {
        await server.stop()
        throw error
    }
}

/// A real loopback listener with literal payloads and controlled HTTP redirects.
private actor TransportFixtureServer {
    private var listenerTask: Task<Void, Never>?
    private var startContinuation: CheckedContinuation<UInt16, any Error>?
    private var port: UInt16?

    func start() async throws {
        let listener = try NetworkListener(using: NWParametersBuilder { TCP() }
            .localEndpoint(.hostPort(host: .init("127.0.0.1"), port: .any)))
        port = try await withCheckedThrowingContinuation { continuation in
            startContinuation = continuation
            listenerTask = Task {
                do {
                    try await listener.onStateUpdate { listener, state in
                        Task { self.handle(state, listener: listener) }
                    }.run { connection in
                        await self.serve(connection)
                    }
                } catch {
                    self.failStart(error)
                }
            }
        }
    }

    func url(_ path: String) throws -> URL {
        let port = try #require(port)
        return try #require(URL(string: "http://127.0.0.1:\(port)\(path)"))
    }

    func stop() async {
        listenerTask?.cancel()
        await listenerTask?.value
        listenerTask = nil
    }

    private func handle(_ state: NetworkListener<TCP>.State, listener: NetworkListener<TCP>) {
        switch state {
        case .ready:
            guard let continuation = startContinuation, let port = listener.port else { return }
            startContinuation = nil
            continuation.resume(returning: port.rawValue)
        case let .failed(error): failStart(error)
        default: break
        }
    }

    private func failStart(_ error: any Error) {
        startContinuation?.resume(throwing: error)
        startContinuation = nil
    }

    private func serve(_ connection: NetworkConnection<TCP>) async {
        do {
            var request = Data()
            while !request.contains(Data("\r\n\r\n".utf8)) {
                let message = try await connection.receive(atLeast: 1, atMost: 8192)
                guard !message.content.isEmpty, request.count < 16_384 else { return }
                request.append(message.content)
            }
            let path = String(decoding: request, as: UTF8.self).split(separator: " ").dropFirst().first ?? ""
            let location: String?
            switch path {
            case "/redirect-local": location = try url("/bytes").absoluteString
            case "/redirect-public": location = "http://8.8.8.8/archive.tgz"
            case "/redirect-credentials": location = try url("/bytes").absoluteString
                .replacingOccurrences(of: "http://", with: "http://user:password@")
            default: location = nil
            }
            let payload: String
            switch path {
            case "/catalog": payload = #"[{"name":"Local","title":"Local docset","versions":["1.2"]}]"#
            case "/feed": payload = "<entry><version>1.2</version><url>\(try url("/bytes").absoluteString)</url></entry>"
            case "/feed-public": payload = "<entry><version>1.2</version><url>http://mirror.invalid/a.tgz</url></entry>"
            default: payload = "archive payload"
            }
            let response: String
            if let location {
                response = "HTTP/1.1 302 Found\r\nLocation: \(location)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            } else {
                response = "HTTP/1.1 200 OK\r\nContent-Length: \(payload.utf8.count)\r\nConnection: close\r\n\r\n\(payload)"
            }
            try await connection.send(Data(response.utf8))
            try await connection.send(Data(), endOfStream: true)
        } catch {
            // Connection cancellation is expected when the client refuses a redirect.
        }
    }
}

private struct TransportHTTPResponse: HTTPClient {
    let data: Data
    let finalURL: URL

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        (data, HTTPURLResponse(url: finalURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!)
    }
}

private struct LegacyTransportDownload: DownloadClient {
    func download(from url: URL, to destinationURL: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws {
        try Data("legacy archive".utf8).write(to: destinationURL)
    }
}

/// Only fabricates response metadata; real loopback fixtures above cover sockets and redirects.
private final class TransportFinalURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let finalURL = URL(string: request.url?.lastPathComponent == "downgrade"
            ? "http://localhost/archive.tgz" : "https://user:password@example.invalid/archive.tgz")!
        let response = HTTPURLResponse(url: finalURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("untrusted archive".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
