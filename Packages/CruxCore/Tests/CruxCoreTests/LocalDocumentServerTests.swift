import Foundation
import Network
import Testing

@testable import CruxCore

@Suite(.serialized)
struct LocalDocumentServerTests {
    /// Drives the real listener over a real socket so framing, ranges and the
    /// loopback binding are covered, not just the routing rules.
    private func withRunningServer(
        allowsRemoteResources: Bool = true,
        connectionIdleTimeout: Duration = .seconds(15),
        maximumRequestsPerConnection: Int = 256,
        _ body: (LocalDocumentServer, DocumentServerEndpoint, DocsetDescriptor) async throws -> Void
    ) async throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let descriptor = try DocsetParser().parse(bundleAt: TestDocsetFixture.create(in: root))
        let server = LocalDocumentServer(
            connectionIdleTimeout: connectionIdleTimeout,
            maximumRequestsPerConnection: maximumRequestsPerConnection
        )
        await server.update(roots: [DocumentRoot(
            identifier: descriptor.identifier,
            documentsURL: descriptor.documentsURL,
            isJavaScriptEnabled: descriptor.isJavaScriptEnabled,
            allowsRemoteResources: allowsRemoteResources
        )])

        let endpoint = try await server.start()
        do {
            try await body(server, endpoint, descriptor)
            await server.shutdownAndWait()
        } catch {
            await server.shutdownAndWait()
            throw error
        }
    }

    private func fetch(
        _ url: URL,
        method: String = "GET",
        headers: [String: String] = [:]
    ) async throws -> (HTTPURLResponse, Data) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let (data, response) = try await URLSession(configuration: configuration).data(for: request)
        return (try #require(response as? HTTPURLResponse), data)
    }

    @Test(.timeLimit(.minutes(1)))
    func servesDocsetFilesOverLoopbackWithTheRunToken() async throws {
        try await withRunningServer { server, endpoint, descriptor in
            #expect(endpoint.host == "127.0.0.1")
            #expect(endpoint.port > 0)

            let url = try #require(await server.url(
                forDocset: descriptor.identifier,
                relativePath: "library/pprint.html",
                fragment: nil
            ))
            let (response, data) = try await fetch(url)

            #expect(response.statusCode == 200)
            #expect(String(data: data, encoding: .utf8) == "<html>pprint</html>")
            #expect(response.value(forHTTPHeaderField: "Content-Type") == "text/html; charset=utf-8")
            #expect(response.value(forHTTPHeaderField: "Content-Security-Policy")?.contains("https:") == true)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func refusesRequestsWithoutAValidTokenOrInsideAnotherDirectory() async throws {
        try await withRunningServer { _, endpoint, descriptor in
            let base = "http://\(endpoint.host):\(endpoint.port)"
            let unauthorized = try #require(URL(string: "\(base)/\(descriptor.identifier)/index.html"))
            let traversal = try #require(URL(
                string: "\(base)/\(endpoint.token)/\(descriptor.identifier)/..%2f..%2fInfo.plist"
            ))

            #expect(try await fetch(unauthorized).0.statusCode == 404)
            #expect(try await fetch(traversal).0.statusCode == 404)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func answersHeadAndRangeRequestsTheWayWebKitExpects() async throws {
        try await withRunningServer { server, _, descriptor in
            let url = try #require(await server.url(
                forDocset: descriptor.identifier,
                relativePath: "index.html",
                fragment: nil
            ))
            let size = "<html>index</html>".utf8.count

            let (headResponse, headBody) = try await fetch(url, method: "HEAD")
            #expect(headResponse.statusCode == 200)
            #expect(headBody.isEmpty)
            #expect(headResponse.value(forHTTPHeaderField: "Content-Length") == String(size))

            let (rangeResponse, rangeBody) = try await fetch(url, headers: ["Range": "bytes=6-10"])
            #expect(rangeResponse.statusCode == 206)
            #expect(String(data: rangeBody, encoding: .utf8) == "index")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func blocksRemoteResourcesWhenTheDocsetOptsOut() async throws {
        try await withRunningServer(allowsRemoteResources: false) { server, _, descriptor in
            let url = try #require(await server.url(
                forDocset: descriptor.identifier,
                relativePath: "index.html",
                fragment: nil
            ))
            let policy = try #require(
                await fetch(url).0.value(forHTTPHeaderField: "Content-Security-Policy")
            )
            #expect(!policy.contains("https:"))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func closesAnIdleKeepAliveConnectionInsteadOfLeakingItsListenerSlot() async throws {
        try await withRunningServer(connectionIdleTimeout: .milliseconds(50)) { _, endpoint, descriptor in
            let request = """
            HEAD /\(endpoint.token)/\(descriptor.identifier)/index.html HTTP/1.1\r
            Host: \(endpoint.host):\(endpoint.port)\r
            Connection: keep-alive\r
            \r

            """

            try await withNetworkConnection(
                to: .hostPort(
                    host: .init(endpoint.host),
                    port: .init(rawValue: endpoint.port)!
                ),
                using: NWParametersBuilder { TCP() }
            ) { connection in
                try await connection.send(Data(request.utf8))

                var response = Data()
                while !response.contains(Data("\r\n\r\n".utf8)) {
                    let message = try await connection.receive(atLeast: 1, atMost: 4 * 1_024)
                    response.append(message.content)
                }
                #expect(String(decoding: response, as: UTF8.self).contains("200 OK"))

                // The first request deliberately asks for keep-alive. The next
                // receive must still finish once the server's idle budget expires.
                let end = try await connection.receive(atLeast: 1, atMost: 1)
                #expect(end.content.isEmpty)
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func closesAConnectionAfterItsBoundedRequestBudget() async throws {
        try await withRunningServer(maximumRequestsPerConnection: 2) { _, endpoint, descriptor in
            let request = Data("""
            HEAD /\(endpoint.token)/\(descriptor.identifier)/index.html HTTP/1.1\r
            Host: \(endpoint.host):\(endpoint.port)\r
            Connection: keep-alive\r
            \r

            """.utf8)

            try await withNetworkConnection(
                to: .hostPort(host: .init(endpoint.host), port: .init(rawValue: endpoint.port)!),
                using: NWParametersBuilder { TCP() }
            ) { connection in
                for _ in 0..<2 {
                    try await connection.send(request)
                    var response = Data()
                    while !response.contains(Data("\r\n\r\n".utf8)) {
                        response.append(
                            try await connection.receive(atLeast: 1, atMost: 4 * 1_024).content
                        )
                    }
                    #expect(String(decoding: response, as: UTF8.self).contains("200 OK"))
                }

                let end = try await connection.receive(atLeast: 1, atMost: 1)
                #expect(end.content.isEmpty)
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func stoppingTheServerDrainsAnIdleKeepAliveHandler() async throws {
        try await withRunningServer { server, endpoint, descriptor in
            let request = Data("""
            HEAD /\(endpoint.token)/\(descriptor.identifier)/index.html HTTP/1.1\r
            Host: \(endpoint.host):\(endpoint.port)\r
            Connection: keep-alive\r
            \r

            """.utf8)

            try await withNetworkConnection(
                to: .hostPort(host: .init(endpoint.host), port: .init(rawValue: endpoint.port)!),
                using: NWParametersBuilder { TCP() }
            ) { connection in
                try await connection.send(request)
                var response = Data()
                while !response.contains(Data("\r\n\r\n".utf8)) {
                    response.append(
                        try await connection.receive(atLeast: 1, atMost: 4 * 1_024).content
                    )
                }

                await server.shutdownAndWait()
                let trailing = try? await connection.receive(atLeast: 1, atMost: 1).content
                #expect(trailing == nil || trailing?.isEmpty == true)
            }
        }
    }
}
