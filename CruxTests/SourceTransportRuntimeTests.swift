import CruxCore
import Foundation
import Testing

@MainActor
struct SourceTransportRuntimeTests {
    @Test(.timeLimit(.minutes(1)))
    func consentedLoopbackRequestsAndDownloadsWorkInTheBetaHost() async throws {
        try #require(Bundle.main.bundleIdentifier == "com.zacharyhuo.Crux.Beta")
        let root = FileManager.default.temporaryDirectory.appending(path: "CruxSourceTransport-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let documents = root.appending(path: "Documents")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        let content = Data("<html><body>Consented source</body></html>".utf8)
        try content.write(to: documents.appending(path: "index.html"))
        let server = LocalDocumentServer()
        await server.update(roots: [DocumentRoot(identifier: "source-transport", documentsURL: documents,
            isJavaScriptEnabled: false, allowsRemoteResources: false)])
        _ = try await server.start()
        do {
            let url = try #require(await server.url(forDocset: "source-transport", relativePath: "index.html", fragment: nil))
            #expect(url.scheme == "http")
            #expect(url.host == "127.0.0.1")
            let session = URLSession(configuration: .ephemeral)
            defer { session.invalidateAndCancel() }
            let strict = URLSessionHTTPClient(session: session)
            await #expect(throws: SourceTransportError.httpsRequired) {
                try await strict.data(for: URLRequest(url: url))
            }
            let consented = URLSessionHTTPClient(session: session, transportPolicy: .localHTTP)
            let (data, response) = try await consented.data(for: URLRequest(url: url))
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            #expect(data == content)
            let destination = root.appending(path: "download.html")
            let downloader = URLSessionDownloadClient(configuration: .ephemeral)
            try await downloader.download(from: url, to: destination, progress: { _, _ in }, transportPolicy: .localHTTP)
            #expect(try Data(contentsOf: destination) == content)
            let unconsentedDestination = root.appending(path: "unconsented.html")
            await #expect(throws: SourceTransportError.httpsRequired) {
                try await downloader.download(from: url, to: unconsentedDestination, progress: { _, _ in })
            }
            #expect(!FileManager.default.fileExists(atPath: unconsentedDestination.path))
            await server.shutdownAndWait()
        } catch {
            await server.shutdownAndWait()
            throw error
        }
    }
}
