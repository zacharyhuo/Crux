import Foundation

/// Describes the application-owned locations used by Crux.
///
/// Keeping these paths in `CruxCore` gives the app, command-line tools, and
/// tests one source of truth for cache, session, database, and docset storage.
public struct AppDirectoryLayout: Equatable, Sendable {
    /// The `.../Application Support/Crux` directory supplied by the app layer.
    public let applicationSupportDirectory: URL

    public init(applicationSupportDirectory: URL) {
        self.applicationSupportDirectory = applicationSupportDirectory.standardizedFileURL
    }

    /// The SQLite database that will hold Crux-owned metadata.
    public var databaseURL: URL {
        applicationSupportDirectory.appendingPathComponent("Crux.sqlite", isDirectory: false)
    }

    /// Rebuildable HTML body index kept separate from lifecycle metadata.
    public var fullTextIndexURL: URL {
        applicationSupportDirectory.appendingPathComponent("FullText.sqlite", isDirectory: false)
    }

    /// Rebuildable data such as downloaded catalog responses.
    public var cacheDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("Cache", isDirectory: true)
    }

    /// Restorable window, navigation, and tab state.
    public var sessionDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("Session", isDirectory: true)
    }

    /// The default installation root for downloaded and imported docsets.
    public var defaultDocsetsDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("Docsets", isDirectory: true)
    }

    /// Transient download files. They stay in Application Support even when
    /// docsets live on a custom volume, so a disappearing disk cannot leave a
    /// half-written download as the only copy of a transfer.
    public var downloadsDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("Downloads", isDirectory: true)
    }

    /// Resolves the active docset root, falling back to the default when the
    /// user has not chosen a custom location.
    public func docsetsDirectory(customPath: String?) -> URL {
        guard let customPath, !customPath.isEmpty else { return defaultDocsetsDirectory }
        return URL(fileURLWithPath: customPath, isDirectory: true).standardizedFileURL
    }
}
