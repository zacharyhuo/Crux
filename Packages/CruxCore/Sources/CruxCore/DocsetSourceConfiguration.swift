import Foundation

/// User-configured endpoint identity, deliberately separate from a publisher's sourceId.
public struct DocsetSourceConfiguration: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: Codable, Equatable, Sendable {
        case zeal(catalogURL: URL, downloadRootURL: URL)
        case versioned(catalogURL: URL, sourceId: String)
        case feed(url: URL)
        case unavailable
    }
    public static let cruxID = UUID(uuidString: "C6E34573-1B71-41B4-8BE7-6FE0ED483001")!
    public static let zealID = UUID(uuidString: "C6E34573-1B71-41B4-8BE7-6FE0ED483002")!
    public static let localID = UUID(uuidString: "C6E34573-1B71-41B4-8BE7-6FE0ED483003")!
    public static let legacyID = UUID(uuidString: "C6E34573-1B71-41B4-8BE7-6FE0ED483004")!
    public let id: UUID
    public var name: String
    public let kind: Kind
    public var isEnabled: Bool
    public var isDeleted: Bool
    public let transportPolicy: SourceTransportPolicy

    public init(id: UUID = UUID(), name: String, kind: Kind, isEnabled: Bool = true,
                isDeleted: Bool = false, transportPolicy: SourceTransportPolicy = .strictHTTPS) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.kind = kind
        self.isEnabled = isEnabled
        self.isDeleted = isDeleted
        self.transportPolicy = transportPolicy
    }
    public var isBuiltIn: Bool { id == Self.cruxID || id == Self.zealID || id == Self.legacyID }
    public var canFetch: Bool { isEnabled && !isDeleted && kind != .unavailable }
    public var catalogProvider: CatalogProvider? {
        switch kind {
        case let .zeal(url, root): CatalogProvider(catalogURL: url, downloadRootURL: root)
        case let .versioned(url, id): .versioned(catalogURL: url, sourceId: id)
        case .feed, .unavailable: nil
        }
    }
    public var endpointURL: URL? {
        switch kind {
        case let .zeal(url, _), let .versioned(url, _), let .feed(url): url
        case .unavailable: nil
        }
    }
    public func validate() throws {
        guard !name.isEmpty, name.count <= 120, !name.contains(where: \.isNewline),
              !isDeleted || !isEnabled else { throw DocsetSourceError.invalidConfiguration }
        switch kind {
        case let .zeal(url, root):
            try transportPolicy.validate(url)
            try transportPolicy.validate(root)
            guard root.query == nil, root.fragment == nil else { throw DocsetSourceError.invalidConfiguration }
        case let .versioned(url, publisher):
            // Versioned artifacts currently require HTTPS in their signed publication contract.
            guard transportPolicy == .strictHTTPS else { throw DocsetSourceError.invalidConfiguration }
            try transportPolicy.validate(url)
            guard !publisher.isEmpty else { throw DocsetSourceError.invalidConfiguration }
        case let .feed(url): try transportPolicy.validate(url)
        case .unavailable:
            guard !isEnabled else { throw DocsetSourceError.invalidConfiguration }
        }
    }
    public static var defaults: [Self] {
        [Self(id: cruxID, name: "Crux Docset", kind: .versioned(catalogURL: URL(string:
            "https://raw.githubusercontent.com/zacharyhuo/crux-docset/docset-publication/catalog.json")!, sourceId: "dev.crux")),
         Self(id: zealID, name: "Zeal", kind: .zeal(catalogURL: CatalogProvider.zeal.catalogURL,
             downloadRootURL: CatalogProvider.zeal.downloadRootURL), isEnabled: false)]
    }
}

public enum DocsetSourceError: Error, Equatable, LocalizedError, Sendable {
    case invalidConfiguration, duplicateSource, sourceUnavailable, endpointChanged, builtInSource
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "The source configuration is invalid."
        case .duplicateSource: "A source with this name or endpoint already exists."
        case .sourceUnavailable: "This source is disabled, deleted or unavailable."
        case .endpointChanged: "Add a new source to change its endpoint or transport policy."
        case .builtInSource: "Built-in sources can be disabled, but cannot be deleted."
        }
    }
}

public struct SourcedCatalogEntry: Identifiable, Equatable, Hashable, Sendable {
    public let sourceConfigurationID: UUID
    public let sourceName: String
    public let transportPolicy: SourceTransportPolicy
    public let entry: CatalogEntry
    public var id: String { "\(sourceConfigurationID.uuidString)/\(entry.id)" }
    public init(source: DocsetSourceConfiguration, entry: CatalogEntry) {
        sourceConfigurationID = source.id
        sourceName = source.name
        transportPolicy = source.transportPolicy
        self.entry = entry
    }
}
