import CryptoKit
import Foundation
import ImageIO

/// Where a catalog is fetched from, and how a download URL is built.
///
/// Wrapping the Zeal endpoints in a provider keeps URL, redirect and cache
/// policy out of the rest of the library so a future mirror can be substituted
/// without touching install or search.
public struct CatalogProvider: Equatable, Sendable {
    public enum Format: Equatable, Sendable {
        case zeal
        case versioned(sourceId: String)
    }
    public let catalogURL: URL
    public let downloadRootURL: URL
    public let format: Format

    public static let zeal = CatalogProvider(
        catalogURL: URL(string: "https://api.zealdocs.org/v1/docsets")!,
        downloadRootURL: URL(string: "https://go.zealdocs.org/d")!
    )

    public init(catalogURL: URL, downloadRootURL: URL, format: Format = .zeal) {
        self.catalogURL = catalogURL
        self.downloadRootURL = downloadRootURL
        self.format = format
    }

    public static func versioned(catalogURL: URL, sourceId: String) -> CatalogProvider {
        CatalogProvider(catalogURL: catalogURL, downloadRootURL: catalogURL.deletingLastPathComponent(), format: .versioned(sourceId: sourceId))
    }

    var cacheIdentity: String {
        cacheIdentity(transportPolicy: .strictHTTPS)
    }

    func cacheIdentity(transportPolicy: SourceTransportPolicy) -> String {
        let source: String
        switch format {
        case .zeal: source = "zeal"
        case let .versioned(sourceId): source = "versioned:\(sourceId)"
        }
        // Strict defaults retain the identity written by earlier Crux versions.
        let policySuffix = transportPolicy == .strictHTTPS ? "" : "\ntransportPolicy:\(transportPolicy.rawValue)"
        let data = Data("\(source)\n\(catalogURL.absoluteString)\n\(downloadRootURL.absoluteString)\(policySuffix)".utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public func downloadURL(sourceId: String, name: String, version: String = "latest") -> URL? {
        var root = downloadRootURL
        for component in [sourceId, name, version] {
            root.append(path: component, directoryHint: .notDirectory)
        }
        return root
    }
}

/// A docset the official catalog currently offers for download.
public struct CatalogEntry: Codable, Equatable, Hashable, Identifiable, Sendable {
    public static let maximumIconBytes = 2 * 1_024 * 1_024
    /// 16 MiB for a decoded 32-bit raster, large enough for high-resolution
    /// docset artwork while rejecting compressed image bombs.
    static let maximumDecodedIconPixels: Int64 = 4 * 1_024 * 1_024

    public var id: String { "\(sourceId)/\(name)" }
    public let name: String
    public let title: String
    public let sourceId: String
    public let version: String?
    public let revision: Int?
    public let downloadURL: URL
    public let keywords: [String]
    public let iconData: Data?
    public let releaseFamily: DocsetReleaseFamily?

    public init(
        name: String,
        title: String,
        sourceId: String,
        version: String?,
        revision: Int?,
        downloadURL: URL,
        keywords: [String],
        iconData: Data? = nil,
        releaseFamily: DocsetReleaseFamily? = nil
    ) {
        self.name = name
        self.title = title
        self.sourceId = sourceId
        self.version = version
        self.revision = revision
        self.downloadURL = downloadURL
        self.keywords = keywords
        self.iconData = iconData
        self.releaseFamily = releaseFamily
    }

    public var releases: [DocsetRelease] { releaseFamily?.releases ?? [] }
    public var supportsVersionSelection: Bool { releaseFamily != nil }

    public func resolve(_ policy: DocsetSelectionPolicy) throws -> DocsetRelease {
        guard let family = releaseFamily else { throw CatalogError.versionSelectionUnavailable }
        try family.validate()
        guard sourceId == family.sourceId, name == family.familyId else { throw CatalogError.invalidResponse }
        let releaseId: String
        switch policy {
        case .latest: releaseId = family.latestReleaseId
        case let .pinnedRelease(id): releaseId = id
        }
        guard let release = family.releases.first(where: { $0.id == releaseId }) else {
            throw CatalogError.releaseUnavailable(releaseId)
        }
        return release
    }

    public var advertisedVersion: DocsetVersion {
        DocsetVersion(version: version, revision: revision)
    }
}

public enum CatalogError: Error, Equatable, LocalizedError, Sendable {
    case notHTTPS(URL)
    case invalidResponse
    case emptyCatalog
    case unavailable(String)
    case versionSelectionUnavailable
    case releaseUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case let .notHTTPS(url):
            "The catalog URL must be HTTPS: \(url.absoluteString)"
        case .invalidResponse:
            "The catalog response could not be parsed."
        case .emptyCatalog:
            "The catalog contained no docsets."
        case let .unavailable(message):
            "The catalog could not be refreshed: \(message)"
        case .versionSelectionUnavailable:
            "This catalog does not provide verified version-specific downloads."
        case let .releaseUnavailable(id):
            "The selected docset release is no longer available: \(id)"
        }
    }
}

/// A catalog fetch together with whether it came from the network or disk.
public struct CatalogSnapshot: Equatable, Sendable {
    public let entries: [CatalogEntry]
    public let fetchedAt: Date
    public let isFromCache: Bool
    /// True only when the cache format predates persisted catalog artwork.
    public let requiresArtworkRefresh: Bool

    public init(
        entries: [CatalogEntry],
        fetchedAt: Date,
        isFromCache: Bool,
        requiresArtworkRefresh: Bool = false
    ) {
        self.entries = entries
        self.fetchedAt = fetchedAt
        self.isFromCache = isFromCache
        self.requiresArtworkRefresh = requiresArtworkRefresh
    }
}

public protocol CatalogClient: Sendable {
    func fetch(forceRefresh: Bool) async throws -> CatalogSnapshot
    func cachedSnapshot() async -> CatalogSnapshot?
}

/// Fetches the Zeal-compatible catalog and keeps the last successful copy.
///
/// A failed refresh never deletes a good cache: offline browsing of Available
/// is more useful than an empty list, and a transient error must not wipe it.
public actor RemoteCatalogClient: CatalogClient {
    private let provider: CatalogProvider
    private let httpClient: any HTTPClient
    private let cacheURL: URL
    private let transportPolicy: SourceTransportPolicy

    public init(
        provider: CatalogProvider = .zeal,
        httpClient: (any HTTPClient)? = nil,
        cacheDirectory: URL,
        transportPolicy: SourceTransportPolicy = .strictHTTPS
    ) {
        self.provider = provider
        self.transportPolicy = transportPolicy
        self.httpClient = httpClient ?? URLSessionHTTPClient(transportPolicy: transportPolicy)
        cacheURL = cacheDirectory.appending(path: "catalog.json", directoryHint: .notDirectory)
    }

    public func fetch(forceRefresh: Bool = false) async throws -> CatalogSnapshot {
        if !forceRefresh, let cached = cachedSnapshot() {
            return cached
        }
        do {
            do {
                try transportPolicy.validate(provider.catalogURL)
            } catch SourceTransportError.httpsRequired {
                throw CatalogError.notHTTPS(provider.catalogURL)
            }
            var request = URLRequest(url: provider.catalogURL)
            request.httpMethod = "GET"
            request.timeoutInterval = 30
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await httpClient.data(for: request)
            guard let finalURL = response.url else { throw CatalogError.invalidResponse }
            try transportPolicy.validateRedirect(from: provider.catalogURL, to: finalURL)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                throw CatalogError.unavailable("HTTP \(status)")
            }
            let entries = try CatalogEntry.parseList(data, provider: provider, transportPolicy: transportPolicy)
            if provider.format == .zeal, entries.isEmpty { throw CatalogError.emptyCatalog }
            let snapshot = CatalogSnapshot(entries: entries, fetchedAt: Date(), isFromCache: false)
            try persist(snapshot)
            return snapshot
        } catch {
            if let cached = cachedSnapshot() {
                return CatalogSnapshot(
                    entries: cached.entries,
                    fetchedAt: cached.fetchedAt,
                    isFromCache: true,
                    requiresArtworkRefresh: cached.requiresArtworkRefresh
                )
            }
            if let error = error as? CatalogError { throw error }
            throw CatalogError.unavailable(error.localizedDescription)
        }
    }

    public func cachedSnapshot() -> CatalogSnapshot? {
        guard (try? transportPolicy.validate(provider.catalogURL)) != nil,
              let data = try? Data(contentsOf: cacheURL),
              let stored = try? JSONDecoder().decode(StoredCatalog.self, from: data) else {
            return nil
        }
        if let identity = stored.providerIdentity {
            guard identity == provider.cacheIdentity(transportPolicy: transportPolicy) else { return nil }
        } else if provider != .zeal || transportPolicy != .strictHTTPS { return nil }
        guard stored.schemaVersion == nil || (1...StoredCatalog.currentSchemaVersion).contains(stored.schemaVersion!) else { return nil }
        for entry in stored.entries {
            guard (try? transportPolicy.validate(entry.downloadURL)) != nil else { return nil }
            switch provider.format {
            case .zeal:
                guard entry.releaseFamily == nil else { return nil }
            case let .versioned(sourceId):
                guard entry.sourceId == sourceId, (try? entry.resolve(.latest)) != nil else { return nil }
            }
        }
        return CatalogSnapshot(
            entries: stored.entries,
            fetchedAt: stored.fetchedAt,
            isFromCache: true,
            requiresArtworkRefresh: (stored.schemaVersion ?? 0) < 2
        )
    }

    private func persist(_ snapshot: CatalogSnapshot) throws {
        try FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let stored = StoredCatalog(
            schemaVersion: StoredCatalog.currentSchemaVersion,
            providerIdentity: provider.cacheIdentity(transportPolicy: transportPolicy),
            entries: snapshot.entries,
            fetchedAt: snapshot.fetchedAt
        )
        try JSONEncoder().encode(stored).write(to: cacheURL, options: .atomic)
    }
}

private struct StoredCatalog: Codable {
    static let currentSchemaVersion = 3

    var schemaVersion: Int?
    var providerIdentity: String?
    var entries: [CatalogEntry]
    var fetchedAt: Date
}

extension CatalogEntry {
    /// Parses the Zeal catalog JSON, ignoring unknown fields and dropping
    /// entries that lack a usable name or a download URL allowed by the source.
    public static func parseList(
        _ data: Data,
        provider: CatalogProvider,
        transportPolicy: SourceTransportPolicy = .strictHTTPS
    ) throws -> [CatalogEntry] {
        if case let .versioned(sourceId) = provider.format {
            let entries = try VersionedCatalog.parse(data, trustedSourceId: sourceId)
            for entry in entries {
                try transportPolicy.validate(entry.downloadURL)
                for release in entry.releases { try transportPolicy.validate(release.downloadURL) }
            }
            return entries
        }
        let items: [RawItem]
        do {
            items = try JSONDecoder().decode([RawItem].self, from: data)
        } catch {
            throw CatalogError.invalidResponse
        }

        return items.compactMap { item in
            let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            let sourceId = (item.sourceId?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
                $0.isEmpty ? nil : $0
            } ?? "com.kapeli"
            guard let downloadURL = provider.downloadURL(sourceId: sourceId, name: name) else {
                return nil
            }
            guard (try? transportPolicy.validate(downloadURL)) != nil else { return nil }
            return CatalogEntry(
                name: name,
                title: item.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? name,
                sourceId: sourceId,
                version: item.versions?.compactMap { $0 }.first,
                revision: item.revision?.intValue,
                downloadURL: downloadURL,
                keywords: item.extra?.keywords ?? [],
                iconData: decodeIcon(item.icon2x) ?? decodeIcon(item.icon)
            )
        }
    }

    private static func decodeIcon(_ encoded: String?) -> Data? {
        guard var encoded else { return nil }
        if let comma = encoded.firstIndex(of: ","), encoded[..<comma].contains("base64") {
            encoded = String(encoded[encoded.index(after: comma)...])
        }
        // Base64 expands data by roughly four thirds. Reject oversized input
        // before allocating its decoded representation.
        guard encoded.utf8.count <= ((maximumIconBytes + 2) / 3) * 4,
              let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters),
              let data = validatedIconData(data) else {
            return nil
        }
        return data
    }

    /// Returns the original raster only after bounding both compressed and
    /// decoded size and proving ImageIO can decode its first frame.
    public static func validatedIconData(_ data: Data) -> Data? {
        guard data.count <= maximumIconBytes else { return nil }
        let bytes = [UInt8](data.prefix(8))
        let hasSupportedSignature =
            bytes == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
            || bytes.starts(with: [0xFF, 0xD8, 0xFF])
            || (String(data: data.prefix(6), encoding: .ascii).map {
            $0 == "GIF87a" || $0 == "GIF89a"
            } ?? false)
        guard hasSupportedSignature,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.int64Value > 0,
              height.int64Value > 0,
              width.int64Value <= maximumDecodedIconPixels / height.int64Value,
              width.int64Value * height.int64Value <= maximumDecodedIconPixels,
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else {
            return nil
        }
        return data
    }

    private struct RawItem: Decodable {
        var name: String
        var title: String?
        var sourceId: String?
        var revision: FlexibleInt?
        // Zeal's live catalog contains null placeholders between contributed
        // versions. Decode the wire shape losslessly, then select the first
        // real version instead of rejecting the entire 900+ item response.
        var versions: [String?]?
        var icon: String?
        var icon2x: String?
        var extra: Extra?

        struct Extra: Decodable {
            var keywords: [String]?
        }
    }
}

/// Accepts either a JSON number or a numeric string for revision.
struct FlexibleInt: Decodable {
    let intValue: Int?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            intValue = nil
        } else if let value = try? container.decode(Int.self) {
            intValue = value
        } else if let value = try? container.decode(String.self) {
            intValue = Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            intValue = nil
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
