import Foundation
import Testing

@testable import CruxCore

@Suite
struct DocumentRouterTests {
    private static let token = "test-token"

    private func makeRouter(
        root: URL,
        isJavaScriptEnabled: Bool = false,
        allowsRemoteResources: Bool = true
    ) throws -> (DocumentRouter, DocsetDescriptor) {
        let bundleURL = try TestDocsetFixture.create(in: root)
        let descriptor = try DocsetParser().parse(bundleAt: bundleURL)
        let documentRoot = DocumentRoot(
            identifier: descriptor.identifier,
            documentsURL: descriptor.documentsURL,
            isJavaScriptEnabled: isJavaScriptEnabled,
            allowsRemoteResources: allowsRemoteResources
        )
        return (DocumentRouter(token: Self.token, roots: [documentRoot]), descriptor)
    }

    private func request(_ target: String, method: String = "GET", headers: [String: String] = [:]) -> HTTPRequestHead {
        HTTPRequestHead(method: method, target: target, version: "HTTP/1.1", headers: headers)
    }

    @Test
    func servesAnInBoundsDocumentWithATypedResponse() throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (router, descriptor) = try makeRouter(root: root)

        let response = router.response(
            for: request("/\(Self.token)/\(descriptor.identifier)/library/pprint.html")
        )

        #expect(response.status == .ok)
        #expect(response.headers["Content-Type"] == "text/html; charset=utf-8")
        #expect(response.headers["Accept-Ranges"] == "bytes")
        #expect(response.headers["Referrer-Policy"] == "no-referrer")
        if case let .file(url, range) = response.body {
            #expect(url.lastPathComponent == "pprint.html")
            #expect(range.lowerBound == 0)
        } else {
            Issue.record("Expected a file body, got \(response.body).")
        }
    }

    @Test
    func mapsADocsetRootRequestToItsLandingPage() throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (router, descriptor) = try makeRouter(root: root)

        let response = router.response(for: request("/\(Self.token)/\(descriptor.identifier)/"))

        #expect(response.status == .ok)
        if case let .file(url, _) = response.body {
            #expect(url.lastPathComponent == "index.html")
        } else {
            Issue.record("Expected the landing page, got \(response.body).")
        }
    }

    @Test
    func rejectsRequestsThatDoNotCarryTheRunToken() throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (router, descriptor) = try makeRouter(root: root)

        let missing = router.response(for: request("/\(descriptor.identifier)/index.html"))
        let wrong = router.response(for: request("/not-the-token/\(descriptor.identifier)/index.html"))

        #expect(missing.status == .notFound)
        #expect(wrong.status == .notFound)
    }

    @Test
    func rejectsTraversalInPlainAndPercentEncodedForm() throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (router, descriptor) = try makeRouter(root: root)

        let targets = [
            "/\(Self.token)/\(descriptor.identifier)/../../Info.plist",
            "/\(Self.token)/\(descriptor.identifier)/%2e%2e/%2e%2e/Info.plist",
            "/\(Self.token)/\(descriptor.identifier)/..%2f..%2fInfo.plist",
            "/\(Self.token)/\(descriptor.identifier)//etc/passwd",
        ]
        for target in targets {
            #expect(router.response(for: request(target)).status == .notFound, "\(target) should not resolve.")
        }
    }

    @Test
    func rejectsAnotherDocsetsFilesAndSymlinkEscapes() throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let servedBundle = try TestDocsetFixture.create(in: root)
        let hiddenBundle = try TestDocsetFixture.create(in: root, name: "Hidden", identifier: "dev.crux.hidden")
        let served = try DocsetParser().parse(bundleAt: servedBundle)
        let hidden = try DocsetParser().parse(bundleAt: hiddenBundle)

        let secretURL = root.appending(path: "secret.txt", directoryHint: .notDirectory)
        try Data("secret".utf8).write(to: secretURL)
        try FileManager.default.createSymbolicLink(
            at: served.documentsURL.appending(path: "escape.html", directoryHint: .notDirectory),
            withDestinationURL: secretURL
        )

        let router = DocumentRouter(
            token: Self.token,
            roots: [DocumentRoot(
                identifier: served.identifier,
                documentsURL: served.documentsURL,
                isJavaScriptEnabled: false,
                allowsRemoteResources: false
            )]
        )

        #expect(router.response(for: request("/\(Self.token)/\(served.identifier)/escape.html")).status == .notFound)
        #expect(router.response(for: request("/\(Self.token)/\(hidden.identifier)/index.html")).status == .notFound)
    }

    @Test
    func allowsOnlyReadMethods() throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (router, descriptor) = try makeRouter(root: root)
        let target = "/\(Self.token)/\(descriptor.identifier)/index.html"

        #expect(router.response(for: request(target, method: "HEAD")).status == .ok)
        let rejected = router.response(for: request(target, method: "POST"))
        #expect(rejected.status == .methodNotAllowed)
        #expect(rejected.headers["Allow"] == "GET, HEAD")
    }

    @Test
    func answersByteRangesAndRefusesUnsatisfiableOnes() throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (router, descriptor) = try makeRouter(root: root)
        let target = "/\(Self.token)/\(descriptor.identifier)/index.html"
        let size = "<html>index</html>".utf8.count

        let partial = router.response(for: request(target, headers: ["range": "bytes=2-5"]))
        #expect(partial.status == .partialContent)
        #expect(partial.headers["Content-Range"] == "bytes 2-5/\(size)")
        #expect(partial.contentLength == 4)

        let suffix = router.response(for: request(target, headers: ["range": "bytes=-4"]))
        #expect(suffix.status == .partialContent)
        #expect(suffix.headers["Content-Range"] == "bytes \(size - 4)-\(size - 1)/\(size)")

        let unsatisfiable = router.response(for: request(target, headers: ["range": "bytes=\(size)-"]))
        #expect(unsatisfiable.status == .rangeNotSatisfiable)
        #expect(unsatisfiable.headers["Content-Range"] == "bytes */\(size)")

        // Multi-range is legal to answer with the whole entity.
        let multi = router.response(for: request(target, headers: ["range": "bytes=0-1,4-5"]))
        #expect(multi.status == .ok)
    }

    @Test
    func contentSecurityPolicyFollowsRemoteAndJavaScriptSettings() throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let (permissive, descriptor) = try makeRouter(
            root: root,
            isJavaScriptEnabled: true,
            allowsRemoteResources: true
        )
        let target = "/\(Self.token)/\(descriptor.identifier)/index.html"
        let allowed = try #require(permissive.response(for: request(target)).headers["Content-Security-Policy"])
        #expect(allowed.contains("default-src 'self' https: data:"))
        #expect(allowed.contains("script-src 'self' https:"))
        // Plain HTTP is never in a source list, so mixed content cannot load.
        #expect(!allowed.contains("http:"))

        let restrictedRoot = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: restrictedRoot) }
        let (restricted, other) = try makeRouter(
            root: restrictedRoot,
            isJavaScriptEnabled: false,
            allowsRemoteResources: false
        )
        let blocked = try #require(
            restricted
                .response(for: request("/\(Self.token)/\(other.identifier)/index.html"))
                .headers["Content-Security-Policy"]
        )
        #expect(blocked.contains("default-src 'self' data:"))
        #expect(blocked.contains("script-src 'none'"))
        #expect(!blocked.contains("https:"))
    }

    /// Offline does not mean scriptless: Javadoc search and Dokka navigation
    /// need same-origin scripts/fetch while remote resources remain forbidden.
    @Test
    func offlinePolicyKeepsLocalScriptsAndFetchWithoutAllowingRemoteResources() throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (router, descriptor) = try makeRouter(
            root: root,
            isJavaScriptEnabled: true,
            allowsRemoteResources: false
        )
        let response = router.response(for: request("/\(Self.token)/\(descriptor.identifier)/index.html"))
        #expect(response.status == .ok)
        let policy = try #require(response.headers["Content-Security-Policy"])
        let directives = policy.split(separator: ";").map {
            $0.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        }
        let scripts = try #require(directives.first { $0.first == "script-src" })
        #expect(scripts.contains("'self'"))
        #expect(scripts.contains("'unsafe-inline'"))
        #expect(!scripts.contains("'none'"))
        #expect(directives.first { $0.first == "connect-src" } == ["connect-src", "'self'"])
        #expect(!policy.contains("https:"))
        #expect(!policy.contains("http:"))
        #expect(!policy.contains("*"))
    }

    @Test
    func buildsLoopbackURLsOnlyForServedAndSafePaths() throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (router, descriptor) = try makeRouter(root: root)

        let url = router.url(
            host: "127.0.0.1",
            port: 51234,
            docsetIdentifier: descriptor.identifier,
            relativePath: "library/pprint.html",
            fragment: "toc"
        )
        #expect(url?.absoluteString ==
            "http://127.0.0.1:51234/\(Self.token)/\(descriptor.identifier)/library/pprint.html#toc")

        #expect(router.url(
            host: "127.0.0.1",
            port: 51234,
            docsetIdentifier: descriptor.identifier,
            relativePath: "../escape.html"
        ) == nil)
        #expect(router.url(
            host: "127.0.0.1",
            port: 51234,
            docsetIdentifier: "dev.crux.unknown",
            relativePath: "index.html"
        ) == nil)
    }

    @Test
    func parsesRequestHeadsAndRejectsMalformedOnes() throws {
        let raw = Data("GET /a/b HTTP/1.1\r\nHost: 127.0.0.1\r\nRange: bytes=0-1\r\n\r\nleftover".utf8)
        let (head, consumed) = try HTTPRequestParser.parse(raw)

        #expect(head.method == "GET")
        #expect(head.target == "/a/b")
        #expect(head.headers["host"] == "127.0.0.1")
        #expect(head.headers["range"] == "bytes=0-1")
        #expect(head.wantsKeepAlive)
        #expect(raw.count - consumed == "leftover".utf8.count)

        #expect(throws: HTTPRequestParseError.incomplete) {
            try HTTPRequestParser.parse(Data("GET / HTTP/1.1\r\n".utf8))
        }
        #expect(throws: HTTPRequestParseError.malformed) {
            try HTTPRequestParser.parse(Data("NONSENSE\r\n\r\n".utf8))
        }
    }
}
