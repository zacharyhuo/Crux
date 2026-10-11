import CruxCore
import Foundation
import Security
import Testing
import WebKit

@testable import Crux

private final class PythonSupplyBundleMarker: NSObject {}

/// Opt-in real TLS + real Python archives. Fixture CA trust exists only in this
/// ephemeral URLSession; test data stays in a new Beta/XCTest library.
@MainActor
@Suite(.serialized)
struct PythonSupplyHTTPSAcceptanceTests {
    nonisolated private static var configurationURL: URL? {
        Bundle(for: PythonSupplyBundleMarker.self).url(forResource: "PythonSupplyAcceptance", withExtension: "json")
    }

    @Test(.enabled(if: configurationURL != nil), .timeLimit(.minutes(3)))
    func actualTLSDownloadsUpdateOneSlotAndPreservePinnedOrFailedInstalls() async throws {
        try #require(AppIdentity.current.isBeta)
        try #require(CruxAppRuntimeConfiguration.resolve().isUITesting)
        let configuration = try JSONDecoder().decode(PythonSupplyConfiguration.self, from: Data(contentsOf: #require(Self.configurationURL)))
        let url = try #require(URL(string: configuration.catalogURL))
        try #require(url.scheme == "https" && url.host == "127.0.0.1" && url.port != nil)
        let trust = try PythonFixtureTrust(caDER: configuration.caDER, host: #require(url.host), port: #require(url.port))
        let session = URLSession(configuration: .ephemeral, delegate: trust, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let http = URLSessionHTTPClient(session: session)
        _ = try await http.data(for: URLRequest(url: url.deletingLastPathComponent().appending(path: "control/old")))
        let downloads = PythonHTTPSDownloads(http: http)
        let root = FileManager.default.temporaryDirectory.appending(path: "PythonSupplyTLS-\(UUID())")
        let defaults = try #require(UserDefaults(suiteName: root.lastPathComponent))
        defer {
            defaults.removePersistentDomain(forName: root.lastPathComponent)
            try? FileManager.default.removeItem(at: root)
        }
        let preferences = ReaderPreferences(defaults: defaults)
        preferences.allowsRemoteResources = false
        preferences.restoresLastSession = false
        let client = RemoteCatalogClient(provider: .versioned(catalogURL: url, sourceId: "dev.crux"),
                                         httpClient: http, cacheDirectory: root.appending(path: "CatalogCache"))
        let model = AppModel(preferences: preferences, layout: AppDirectoryLayout(applicationSupportDirectory: root),
                             catalogClient: client, downloadClient: downloads, usesBackgroundDownloads: false, releaseChecker: nil)
        await model.bootstrap()
        do {
            try #require(model.startupError == nil, "Startup: \(String(describing: model.startupError))")
            await model.refreshCatalog()
            try #require(model.libraryError == nil, "Catalog: \(String(describing: model.libraryError)); TLS: \(trust.diagnostics)")
            let entry = try #require(model.catalog.first)
            let old = try entry.resolve(.latest)
            try #require(old.version.hasPrefix("3.13."))
            await model.installCatalogEntry(entry)
            try await wait(model, "initial HTTPS installation") { model.installed.first?.installTarget?.release.id == old.id }
            let first = try #require(model.installed.first)
            try #require(first.selectionPolicy == .latest)
            try verifyFiles(first)

            _ = try await http.data(for: URLRequest(url: url.deletingLastPathComponent().appending(path: "control/new")))
            await model.refreshCatalog()
            let updatedEntry = try #require(model.catalog.first)
            let latest = try updatedEntry.resolve(.latest)
            try #require(latest.version.hasPrefix("3.14.") && latest.id != old.id)
            try #require(model.availableUpdates.count == 1)
            await model.updateAllDocsets()
            try await wait(model, "automatic latest replacement") { model.installed.first?.installTarget?.release.id == latest.id }
            let updated = try #require(model.installed.first)
            try #require(updated.descriptor.bundleURL == first.descriptor.bundleURL && model.installed.count == 1)
            try verifyFiles(updated)

            let location = ReaderLocation(docsetIdentifier: updated.identifier, relativePath: "library/os.html")
            model.open(location)
            let tab = try #require(model.selectedTab)
            try await wait(model, "offline Python reader") { !tab.webView.isLoading && tab.webView.title?.contains("os") == true }
            let results = try await SymbolSearchService().search("list", in: model.docsets, limit: 1000)
            try #require(results.contains { $0.name == "list" })

            await model.installCatalogEntry(updatedEntry, selection: .pinnedRelease(old.id))
            try await wait(model, "pinned version over HTTPS") { model.installed.first?.installTarget?.release.id == old.id }
            let pinned = try #require(model.installed.first)
            try #require(pinned.selectionPolicy == .pinnedRelease(old.id) && model.availableUpdates.isEmpty)
            let jobCount = model.transferJobs.count
            await model.updateAllDocsets()
            try #require(model.transferJobs.count == jobCount)

            await downloads.setCorrupt(true)
            await model.installCatalogEntry(updatedEntry)
            try await wait(model, "damaged HTTPS archive rejected", allowFailedTransfer: true) {
                model.transferJobs.contains { if case .failed = $0.status { true } else { false } }
            }
            try #require(model.installed == [pinned])
            try #require(model.selectedTab?.id == tab.id && tab.currentLocation?.isSamePage(as: location) == true)
            let registry = try DocsetRegistry(databaseURL: model.layout.databaseURL)
            try #require(try await registry.allInstalled() == [pinned])
            let expectedFailures = Set(model.transferJobs.compactMap { job -> UUID? in
                if case .failed = job.status { job.id } else { nil }
            })
            await downloads.setCorrupt(false)
            await model.installCatalogEntry(updatedEntry)
            try await wait(model, "retry after damaged transfer", ignoringFailures: expectedFailures) { model.installed.first?.installTarget?.release.id == latest.id }
            try #require(model.installed.count == 1 && model.installed.first?.descriptor.bundleURL == first.descriptor.bundleURL)

            _ = try await http.data(for: URLRequest(url: url.deletingLastPathComponent().appending(path: "control/broken")))
            await model.refreshCatalog()
            try #require(model.catalogIsFromCache)
            try #require(try model.catalog.first?.resolve(.latest).id == latest.id)
            let snapshot = try #require(await client.cachedSnapshot())
            try #require(snapshot.entries.count == 1)
            let feed = try await DashFeedClient(httpClient: http).fetch(feedURL: url.deletingLastPathComponent().appending(path: "feed.xml"))
            try #require(feed.version == latest.version && feed.revision == latest.revision)
            let slots = try FileManager.default.contentsOfDirectory(at: model.currentDocsetsDirectory, includingPropertiesForKeys: nil)
            try #require(slots.filter { $0.pathExtension == "docset" }.count == 1)
            await model.shutdown()
        } catch {
            await model.shutdown()
            throw error
        }
    }

    private func verifyFiles(_ installed: InstalledDocset) throws {
        let root = installed.descriptor.bundleURL
        for file in ["icon.png", "icon@2x.png", "Contents/Resources/Documents/license.html", "Contents/Resources/Documents/copyright.html"] {
            try #require(!Data(contentsOf: root.appending(path: file)).isEmpty)
        }
        try #require(DocsetIconResolver.image(for: installed.descriptor) != nil)
        try #require(DocsetParser().parse(bundleAt: root).supplyMetadata?.releaseId == installed.installTarget?.release.id)
    }

    private func wait(_ model: AppModel, _ label: String, allowFailedTransfer: Bool = false, ignoringFailures: Set<UUID> = [], until condition: () throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(40))
        while ContinuousClock.now < deadline {
            if try condition() { return }
            if !allowFailedTransfer {
                try #require(model.libraryError == nil, "\(label): \(String(describing: model.libraryError))")
                for job in model.transferJobs where !ignoringFailures.contains(job.id) {
                    if case let .failed(message) = job.status { throw PythonSupplyFailure(message: "\(label): \(message)") }
                }
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw PythonSupplyFailure(message: "Timed out: \(label)")
    }
}

private struct PythonSupplyConfiguration: Decodable { let catalogURL, caDER: String }
private struct PythonSupplyFailure: Error { let message: String }

private final class PythonFixtureTrust: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let certificate: SecCertificate
    private let host: String
    private let port: Int
    private let lock = NSLock()
    private var events: [String] = []
    var diagnostics: [String] { lock.withLock { events } }

    init(caDER: String, host: String, port: Int) throws {
        guard let data = Data(base64Encoded: caDER), let certificate = SecCertificateCreateWithData(nil, data as CFData) else {
            throw PythonSupplyFailure(message: "Invalid ephemeral fixture certificate")
        }
        self.certificate = certificate
        self.host = host
        self.port = port
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        lock.withLock { events.append("\(space.host):\(space.port) \(space.authenticationMethod)") }
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              space.host == host, space.port == port, let trust = space.serverTrust else {
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString))
        SecTrustSetAnchorCertificates(trust, [certificate] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        var error: CFError?
        guard SecTrustEvaluateWithError(trust, &error) else {
            lock.withLock { events.append(String(describing: error)) }
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

private actor PythonHTTPSDownloads: DownloadClient {
    let http: URLSessionHTTPClient
    private var corrupt = false
    init(http: URLSessionHTTPClient) { self.http = http }
    func setCorrupt(_ value: Bool) { corrupt = value }
    func download(from url: URL, to destinationURL: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws {
        var target = url
        if corrupt {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            components.path = components.path.replacingOccurrences(of: "/download/", with: "/corrupt/")
            target = components.url!
        }
        let (data, response) = try await http.data(for: URLRequest(url: target))
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 64 * 1024 * 1024 else {
            throw PythonSupplyFailure(message: "Invalid HTTPS fixture download")
        }
        try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: destinationURL)
        progress(Int64(data.count), Int64(data.count))
    }
}
