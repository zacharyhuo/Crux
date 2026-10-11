import Foundation

/// Immutable information Crux needs to identify, search, and open a docset.
public struct DocsetDescriptor: Codable, Equatable, Hashable, Sendable {
    public let identifier: String
    /// Original CFBundleIdentifier; runtime identifiers can be installation UUIDs.
    public let bundleIdentifier: String
    public let name: String
    public let displayName: String
    public let version: String?
    public let revision: Int?
    public let keywords: [String]
    public let bundleURL: URL
    public let documentsURL: URL
    public let indexURL: URL
    public let indexSchema: DocsetIndexSchema
    public let indexPagePath: String?
    public let isJavaScriptEnabled: Bool
    public let supplyMetadata: DocsetSupplyMetadata?

    init(
        identifier: String, name: String, displayName: String, version: String?, revision: Int?,
        keywords: [String], bundleURL: URL, documentsURL: URL, indexURL: URL,
        indexSchema: DocsetIndexSchema, indexPagePath: String?, isJavaScriptEnabled: Bool,
        supplyMetadata: DocsetSupplyMetadata? = nil, bundleIdentifier: String? = nil
    ) {
        self.identifier = identifier
        self.bundleIdentifier = bundleIdentifier ?? identifier
        self.name = name
        self.displayName = displayName
        self.version = version
        self.revision = revision
        self.keywords = keywords
        self.bundleURL = bundleURL
        self.documentsURL = documentsURL
        self.indexURL = indexURL
        self.indexSchema = indexSchema
        self.indexPagePath = indexPagePath
        self.isJavaScriptEnabled = isJavaScriptEnabled
        self.supplyMetadata = supplyMetadata
    }

    /// All accepted query prefixes, normalized for case-insensitive matching.
    public var searchFilters: Set<String> {
        Set(([name, bundleIdentifier] + keywords).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        })
    }

    func identified(as identifier: String) -> Self {
        Self(identifier: identifier, name: name, displayName: displayName, version: version, revision: revision,
             keywords: keywords, bundleURL: bundleURL, documentsURL: documentsURL, indexURL: indexURL,
             indexSchema: indexSchema, indexPagePath: indexPagePath, isJavaScriptEnabled: isJavaScriptEnabled,
             supplyMetadata: supplyMetadata, bundleIdentifier: bundleIdentifier)
    }

    private enum CodingKeys: String, CodingKey {
        case identifier, bundleIdentifier, name, displayName, version, revision, keywords, bundleURL,
             documentsURL, indexURL, indexSchema, indexPagePath, isJavaScriptEnabled, supplyMetadata
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        identifier = try c.decode(String.self, forKey: .identifier)
        bundleIdentifier = try c.decodeIfPresent(String.self, forKey: .bundleIdentifier) ?? identifier
        name = try c.decode(String.self, forKey: .name)
        displayName = try c.decode(String.self, forKey: .displayName)
        version = try c.decodeIfPresent(String.self, forKey: .version)
        revision = try c.decodeIfPresent(Int.self, forKey: .revision)
        keywords = try c.decode([String].self, forKey: .keywords)
        bundleURL = try c.decode(URL.self, forKey: .bundleURL)
        documentsURL = try c.decode(URL.self, forKey: .documentsURL)
        indexURL = try c.decode(URL.self, forKey: .indexURL)
        indexSchema = try c.decode(DocsetIndexSchema.self, forKey: .indexSchema)
        indexPagePath = try c.decodeIfPresent(String.self, forKey: .indexPagePath)
        isJavaScriptEnabled = try c.decode(Bool.self, forKey: .isJavaScriptEnabled)
        supplyMetadata = try c.decodeIfPresent(DocsetSupplyMetadata.self, forKey: .supplyMetadata)
    }
}

public enum DocsetIndexSchema: String, Codable, Equatable, Hashable, Sendable {
    case dash
    case zDash
}
