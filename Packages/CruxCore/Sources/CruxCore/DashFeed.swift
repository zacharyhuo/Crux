import Foundation

/// A Dash single-entry XML feed the user has added.
public struct DashFeed: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let feedURL: URL
    public var name: String
    public var version: String?
    public var revision: Int?
    public var downloadURL: URL

    public init(
        id: UUID = UUID(),
        feedURL: URL,
        name: String,
        version: String?,
        revision: Int?,
        downloadURL: URL
    ) {
        self.id = id
        self.feedURL = feedURL
        self.name = name
        self.version = version
        self.revision = revision
        self.downloadURL = downloadURL
    }

    public var advertisedVersion: DocsetVersion {
        DocsetVersion(version: version, revision: revision)
    }
}

public enum DashFeedError: Error, Equatable, LocalizedError, Sendable {
    case notHTTPS(URL)
    case invalidXML
    case missingField(String)
    case insecureDownloadURL(URL)
    case duplicateFeed
    case duplicateDownload(URL)

    public var errorDescription: String? {
        switch self {
        case let .notHTTPS(url):
            "Feed URLs must use HTTPS: \(url.absoluteString)"
        case .invalidXML:
            "The feed is not valid Dash XML."
        case let .missingField(name):
            "The feed is missing \(name)."
        case let .insecureDownloadURL(url):
            "The feed's download address is not HTTPS: \(url.absoluteString)"
        case .duplicateFeed:
            "This feed has already been added."
        case let .duplicateDownload(url):
            "A feed for \(url.lastPathComponent) already exists."
        }
    }
}

public enum DashFeedParser {
    /// Parses a Dash `<entry>` document into a feed record.
    ///
    /// Official Kapeli feeds still advertise `http://` CDN URLs. Those hosts
    /// speak HTTPS, so Crux rewrites them rather than refusing a well-known
    /// publisher. Other plaintext URLs require explicit local transport consent.
    public static func parse(
        xml data: Data,
        feedURL: URL,
        id: UUID = UUID(),
        transportPolicy: SourceTransportPolicy = .strictHTTPS
    ) throws -> DashFeed {
        do {
            try transportPolicy.validate(feedURL)
        } catch SourceTransportError.httpsRequired {
            throw DashFeedError.notHTTPS(feedURL)
        }

        let extracted = FeedExtractor()
        let parser = XMLParser(data: data)
        parser.delegate = extracted
        guard parser.parse() else { throw DashFeedError.invalidXML }

        let version = extracted.version?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let version, !version.isEmpty else {
            throw DashFeedError.missingField("version")
        }

        var firstDownloadError: (any Error)?
        let downloadCandidates = extracted.urls.compactMap { raw -> URL? in
            guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                return nil
            }
            do {
                return try requireHTTPS(url, transportPolicy: transportPolicy)
            } catch {
                if firstDownloadError == nil { firstDownloadError = error }
                return nil
            }
        }
        guard let downloadURL = downloadCandidates.first else {
            if let firstDownloadError { throw firstDownloadError }
            throw DashFeedError.missingField("url")
        }

        let revision = extracted.revision.flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let name = nameFromDownloadURL(downloadURL) ?? feedURL.deletingPathExtension().lastPathComponent
        return DashFeed(
            id: id,
            feedURL: feedURL,
            name: name,
            version: version,
            revision: revision,
            downloadURL: downloadURL
        )
    }

    public static func requireHTTPS(
        _ url: URL,
        transportPolicy: SourceTransportPolicy = .strictHTTPS
    ) throws -> URL {
        let scheme = url.scheme?.lowercased()
        if scheme == "http", let host = url.host?.lowercased(), host.hasSuffix(".kapeli.com") || host == "kapeli.com" {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.scheme = "https"
            if let rewritten = components?.url {
                try SourceTransportPolicy.strictHTTPS.validate(rewritten)
                return rewritten
            }
        }
        do {
            try transportPolicy.validate(url)
            return url
        } catch SourceTransportError.httpsRequired {
            throw DashFeedError.insecureDownloadURL(url)
        } catch SourceTransportError.localHTTPRequired {
            throw DashFeedError.insecureDownloadURL(url)
        }
    }

    public static func nameFromDownloadURL(_ url: URL) -> String? {
        var name = url.lastPathComponent
        for suffix in [".tar.gz", ".tgz", ".tar"] where name.lowercased().hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
            break
        }
        return name.isEmpty ? nil : name
    }
}

public actor DashFeedClient {
    private let httpClient: any HTTPClient
    private let transportPolicy: SourceTransportPolicy

    public init(httpClient: (any HTTPClient)? = nil, transportPolicy: SourceTransportPolicy = .strictHTTPS) {
        self.transportPolicy = transportPolicy
        self.httpClient = httpClient ?? URLSessionHTTPClient(transportPolicy: transportPolicy)
    }

    public func refresh(_ feed: DashFeed) async throws -> DashFeed {
        do {
            try transportPolicy.validate(feed.feedURL)
        } catch SourceTransportError.httpsRequired {
            throw DashFeedError.notHTTPS(feed.feedURL)
        }
        var request = URLRequest(url: feed.feedURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        let (data, response) = try await httpClient.data(for: request)
        guard let finalURL = response.url else { throw DashFeedError.invalidXML }
        try transportPolicy.validateRedirect(from: feed.feedURL, to: finalURL)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw DashFeedError.invalidXML
        }
        return try DashFeedParser.parse(xml: data, feedURL: feed.feedURL, id: feed.id, transportPolicy: transportPolicy)
    }

    public func fetch(feedURL: URL) async throws -> DashFeed {
        try await refresh(DashFeed(
            feedURL: feedURL,
            name: feedURL.lastPathComponent,
            version: "0",
            revision: nil,
            downloadURL: feedURL
        ))
    }
}

/// Collects the handful of fields Dash puts in a feed.
private final class FeedExtractor: NSObject, XMLParserDelegate {
    var version: String?
    var revision: String?
    var urls: [String] = []
    private var current: String?
    private var text = ""

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        current = elementName.lowercased()
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName.lowercased() {
        case "version":
            if version == nil { version = value }
        case "revision":
            revision = value
        case "url":
            if !value.isEmpty { urls.append(value) }
        default:
            break
        }
        current = nil
        text = ""
    }
}
