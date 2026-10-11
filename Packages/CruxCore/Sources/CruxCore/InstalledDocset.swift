import Foundation

/// How an installed docset entered the library.
public enum DocsetSource: Codable, Equatable, Sendable {
    case catalog(name: String, sourceId: String)
    case feed(feedURL: URL)
    case localImport

    public var isUpdatable: Bool {
        switch self {
        case .catalog, .feed: true
        case .localImport: false
        }
    }
}

/// A registry row: the parsed bundle plus the origin used for updates.
public struct InstalledDocset: Codable, Equatable, Sendable {
    public var descriptor: DocsetDescriptor
    public var source: DocsetSource
    /// The version advertised by the catalog or feed at install time.
    ///
    /// Bundle metadata is sometimes incomplete, so update checks compare against
    /// this stored advertisement rather than trusting the plist alone.
    public var advertisedVersion: DocsetVersion
    public var selectionPolicy: DocsetSelectionPolicy
    /// Trusted only after the exact archive and its metadata have been verified.
    public var installTarget: DocsetInstallTarget?
    public var sourceConfigurationID: UUID?
    public var sourceName: String?

    public init(
        descriptor: DocsetDescriptor, source: DocsetSource, advertisedVersion: DocsetVersion,
        selectionPolicy: DocsetSelectionPolicy = .latest, installTarget: DocsetInstallTarget? = nil,
        sourceConfigurationID: UUID? = nil, sourceName: String? = nil
    ) {
        self.descriptor = descriptor
        self.source = source
        self.advertisedVersion = advertisedVersion
        self.selectionPolicy = selectionPolicy
        self.installTarget = installTarget
        self.sourceConfigurationID = sourceConfigurationID
        self.sourceName = sourceName
    }

    private enum CodingKeys: String, CodingKey {
        case descriptor, source, advertisedVersion, selectionPolicy, installTarget, sourceConfigurationID, sourceName
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        descriptor = try container.decode(DocsetDescriptor.self, forKey: .descriptor)
        source = try container.decode(DocsetSource.self, forKey: .source)
        advertisedVersion = try container.decode(DocsetVersion.self, forKey: .advertisedVersion)
        selectionPolicy = try container.decodeIfPresent(DocsetSelectionPolicy.self, forKey: .selectionPolicy) ?? .latest
        installTarget = try container.decodeIfPresent(DocsetInstallTarget.self, forKey: .installTarget)
        sourceConfigurationID = try container.decodeIfPresent(UUID.self, forKey: .sourceConfigurationID)
        sourceName = try container.decodeIfPresent(String.self, forKey: .sourceName)
    }

    public var identifier: String { descriptor.identifier }
    public var isReachable: Bool {
        FileManager.default.fileExists(atPath: descriptor.bundleURL.path)
    }
}

/// User-chosen storage location. The bookmark is what the sandbox needs to
/// reopen a folder the user picked in a previous launch.
public struct LibrarySettings: Codable, Equatable, Sendable {
    public var customDocsetsPath: String?
    public var bookmarkData: Data?

    public static let `default` = LibrarySettings(customDocsetsPath: nil, bookmarkData: nil)

    public init(customDocsetsPath: String? = nil, bookmarkData: Data? = nil) {
        self.customDocsetsPath = customDocsetsPath
        self.bookmarkData = bookmarkData
    }

    public func resolvedDocsetsDirectory(layout: AppDirectoryLayout) -> URL {
        layout.docsetsDirectory(customPath: customDocsetsPath)
    }
}
