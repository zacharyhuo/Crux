import Foundation

/// One download or import that the transfer queue is responsible for.
public struct TransferJob: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case catalog
        case feed
        case localImport
    }

    public enum Status: Codable, Equatable, Sendable {
        case queued
        case downloading(bytesReceived: Int64, bytesExpected: Int64?)
        case installing
        case completed(identifier: String)
        case failed(message: String)
        case cancelled
    }

    public let id: UUID
    public var kind: Kind
    public var displayName: String
    /// Remote HTTPS URL, or a local file for imports.
    public var sourceURL: URL
    public var expectedIdentifier: String?
    public var catalogName: String?
    public var catalogSourceId: String?
    public var feedURL: URL?
    public var advertisedVersion: DocsetVersion?
    public var fallbackIconData: Data?
    public var target: DocsetInstallTarget?
    public var sourceConfigurationID: UUID?
    public var sourceName: String?
    public var transportPolicy: SourceTransportPolicy?
    public var installationIdentifier: String?
    public var status: Status
    public var downloadedFileURL: URL?
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        kind: Kind,
        displayName: String,
        sourceURL: URL,
        expectedIdentifier: String? = nil,
        catalogName: String? = nil,
        catalogSourceId: String? = nil,
        feedURL: URL? = nil,
        advertisedVersion: DocsetVersion? = nil,
        fallbackIconData: Data? = nil,
        target: DocsetInstallTarget? = nil,
        status: Status = .queued,
        downloadedFileURL: URL? = nil,
        createdAt: Date = Date(),
        sourceConfigurationID: UUID? = nil, sourceName: String? = nil,
        transportPolicy: SourceTransportPolicy? = nil, installationIdentifier: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.sourceURL = sourceURL
        self.expectedIdentifier = expectedIdentifier
        self.catalogName = catalogName
        self.catalogSourceId = catalogSourceId
        self.feedURL = feedURL
        self.advertisedVersion = advertisedVersion
        self.fallbackIconData = fallbackIconData
        self.target = target
        self.sourceConfigurationID = sourceConfigurationID
        self.sourceName = sourceName
        self.transportPolicy = transportPolicy
        self.installationIdentifier = installationIdentifier
        self.status = status
        self.downloadedFileURL = downloadedFileURL
        self.createdAt = createdAt
    }

    public var isActive: Bool {
        switch status {
        case .queued, .downloading, .installing: true
        case .completed, .failed, .cancelled: false
        }
    }

    public var isFinished: Bool {
        !isActive
    }
}

public enum TransferError: Error, Equatable, LocalizedError, Sendable {
    case insecureDownloadURL(URL)
    case notRestored
    case installFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .insecureDownloadURL(url):
            "Downloads must use HTTPS: \(url.absoluteString)"
        case .notRestored:
            "The download could not be restored after restart."
        case let .installFailed(message):
            message
        }
    }
}

public struct TransferRequest: Equatable, Sendable {
    public var kind: TransferJob.Kind
    public var displayName: String
    public var sourceURL: URL
    public var expectedIdentifier: String?
    public var catalogName: String?
    public var catalogSourceId: String?
    public var feedURL: URL?
    public var advertisedVersion: DocsetVersion?
    public var fallbackIconData: Data?
    public var target: DocsetInstallTarget?
    public var sourceConfigurationID: UUID?
    public var sourceName: String?
    public var transportPolicy: SourceTransportPolicy?
    public var installationIdentifier: String?

    public init(
        kind: TransferJob.Kind,
        displayName: String,
        sourceURL: URL,
        expectedIdentifier: String? = nil,
        catalogName: String? = nil,
        catalogSourceId: String? = nil,
        feedURL: URL? = nil,
        advertisedVersion: DocsetVersion? = nil,
        fallbackIconData: Data? = nil,
        target: DocsetInstallTarget? = nil,
        sourceConfigurationID: UUID? = nil, sourceName: String? = nil,
        transportPolicy: SourceTransportPolicy? = nil, installationIdentifier: String? = nil
    ) {
        self.kind = kind
        self.displayName = displayName
        self.sourceURL = sourceURL
        self.expectedIdentifier = expectedIdentifier
        self.catalogName = catalogName
        self.catalogSourceId = catalogSourceId
        self.feedURL = feedURL
        self.advertisedVersion = advertisedVersion
        self.fallbackIconData = fallbackIconData
        self.target = target
        self.sourceConfigurationID = sourceConfigurationID
        self.sourceName = sourceName
        self.transportPolicy = transportPolicy
        self.installationIdentifier = installationIdentifier
    }

    public static func catalog(_ entry: CatalogEntry, selection: DocsetSelectionPolicy = .latest) throws -> TransferRequest {
        let target: DocsetInstallTarget?
        if entry.supportsVersionSelection {
            target = try DocsetInstallTarget(entry: entry, selection: selection)
        } else {
            guard selection == .latest else { throw CatalogError.versionSelectionUnavailable }
            target = nil
        }
        return TransferRequest(
            kind: .catalog,
            displayName: entry.title,
            sourceURL: target?.release.downloadURL ?? entry.downloadURL,
            expectedIdentifier: target?.release.identifier,
            catalogName: entry.name,
            catalogSourceId: entry.sourceId,
            advertisedVersion: target?.release.advertisedVersion ?? entry.advertisedVersion,
            fallbackIconData: entry.iconData,
            target: target
        )
    }

    public static func feed(_ feed: DashFeed) -> TransferRequest {
        TransferRequest(
            kind: .feed,
            displayName: feed.name,
            sourceURL: feed.downloadURL,
            feedURL: feed.feedURL,
            advertisedVersion: feed.advertisedVersion
        )
    }

    public static func catalog(_ item: SourcedCatalogEntry, selection: DocsetSelectionPolicy = .latest,
                               replacing existing: InstalledDocset? = nil) throws -> TransferRequest {
        var request = try catalog(item.entry, selection: selection)
        request.sourceConfigurationID = item.sourceConfigurationID
        request.sourceName = item.sourceName
        request.transportPolicy = item.transportPolicy
        request.target = request.target?.scoped(to: item.sourceConfigurationID)
        request.installationIdentifier = existing?.identifier
        return request
    }

    public static func feed(_ feed: DashFeed, source: DocsetSourceConfiguration,
                            replacing existing: InstalledDocset? = nil) -> TransferRequest {
        var request = Self.feed(feed)
        request.sourceConfigurationID = source.id
        request.sourceName = source.name
        request.transportPolicy = source.transportPolicy
        request.installationIdentifier = existing?.identifier
        return request
    }

    public static func importing(fileURL: URL) -> TransferRequest {
        TransferRequest(
            kind: .localImport,
            displayName: fileURL.lastPathComponent,
            sourceURL: fileURL
        )
    }
}

extension TransferJob {
    var slotKey: String? {
        if let target { return target.slotKey }
        if let name = catalogName, let publisher = catalogSourceId {
            return "\(sourceConfigurationID?.uuidString ?? "legacy")/\(publisher)/\(name)"
        }
        if let feedURL { return "\(sourceConfigurationID?.uuidString ?? "legacy")/feed/\(feedURL.absoluteString)" }
        return nil
    }
}
