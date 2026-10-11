import Foundation

public enum StorageMigrationError: Error, Equatable, LocalizedError, Sendable {
    case destinationNotWritable(URL)
    case sourceOutsideRoot(URL)
    case verificationFailed(String)
    case interrupted

    public var errorDescription: String? {
        switch self {
        case let .destinationNotWritable(url):
            "Crux cannot write to \(url.path)."
        case let .sourceOutsideRoot(url):
            "The registered docset is outside the selected storage folder: \(url.path)."
        case let .verificationFailed(name):
            "\(name) did not verify after being copied."
        case .interrupted:
            "The storage move was interrupted. The previous location is still in use."
        }
    }
}

public struct StorageMigrationReport: Equatable, Sendable {
    public let copied: [String]
    public let destination: URL
    public let trashedSource: Bool
    /// Exact source bundles that were copied and verified successfully.
    ///
    /// The UI may offer to move these items to Trash after the registry switch.
    /// The source root itself is intentionally never included because a custom
    /// storage folder can also contain files that do not belong to Crux.
    public let sourceItemsEligibleForTrash: [URL]
}

/// Copies installed docsets to a new root, verifies each copy, then switches.
///
/// The previous location stays authoritative until every copy parses. An
/// interrupted or failed move therefore never leaves the registry pointing at
/// a half-copied tree.
public actor StorageMigrator {
    private let parser: DocsetParser

    public init(parser: DocsetParser = DocsetParser()) {
        self.parser = parser
    }

    public func migrate(
        records: [InstalledDocset],
        from sourceRoot: URL,
        to destinationRoot: URL,
        trashSourceAfterSwitch: Bool
    ) async throws -> (records: [InstalledDocset], report: StorageMigrationReport) {
        let sourceRoot = sourceRoot.resolvingSymlinksInPath().standardizedFileURL
        let destinationRoot = destinationRoot.resolvingSymlinksInPath().standardizedFileURL
        if sourceRoot == destinationRoot {
            return (records, StorageMigrationReport(
                copied: [],
                destination: destinationRoot,
                trashedSource: false,
                sourceItemsEligibleForTrash: []
            ))
        }

        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        guard FileManager.default.isWritableFile(atPath: destinationRoot.path) else {
            throw StorageMigrationError.destinationNotWritable(destinationRoot)
        }

        var copiedNames: [String] = []
        var copiedSourceURLs: [URL] = []
        var relocated: [InstalledDocset] = []
        do {
            for record in records {
                try Task.checkCancellation()
                let sourceURL = record.descriptor.bundleURL
                guard let relative = relativePath(of: sourceURL.resolvingSymlinksInPath(), under: sourceRoot) else {
                    throw StorageMigrationError.sourceOutsideRoot(sourceURL.standardizedFileURL)
                }
                let destinationURL = destinationRoot.appending(path: relative, directoryHint: .isDirectory)
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.removeItem(at: destinationURL)
                }
                try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
                let parsed = try parser.parse(bundleAt: destinationURL)
                guard parsed.bundleIdentifier == record.descriptor.bundleIdentifier else {
                    throw StorageMigrationError.verificationFailed(record.descriptor.displayName)
                }
                copiedNames.append(relative)
                copiedSourceURLs.append(sourceURL.standardizedFileURL)
                relocated.append(InstalledDocset(
                    descriptor: parsed.identified(as: record.identifier),
                    source: record.source,
                    advertisedVersion: record.advertisedVersion,
                    selectionPolicy: record.selectionPolicy,
                    installTarget: record.installTarget,
                    sourceConfigurationID: record.sourceConfigurationID, sourceName: record.sourceName
                ))
            }
        } catch is CancellationError {
            throw StorageMigrationError.interrupted
        }

        var trashed = false
        if trashSourceAfterSwitch {
            for name in copiedNames {
                let leftover = sourceRoot.appending(path: name, directoryHint: .isDirectory)
                _ = try? FileManager.default.trashItem(at: leftover, resultingItemURL: nil)
            }
            trashed = true
        }

        return (
            relocated,
            StorageMigrationReport(
                copied: copiedNames,
                destination: destinationRoot,
                trashedSource: trashed,
                sourceItemsEligibleForTrash: copiedSourceURLs
            )
        )
    }

    private func relativePath(of url: URL, under root: URL) -> String? {
        let path = url.standardizedFileURL.path
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }
}

public enum DocsetUpdateChecker {
    public static func availableUpdate(
        for record: InstalledDocset,
        catalog: [CatalogEntry],
        feeds: [DashFeed]
    ) -> TransferRequest? {
        guard record.selectionPolicy == .latest else { return nil }
        switch record.source {
        case let .catalog(name, sourceId):
            guard let entry = catalog.first(where: { $0.name == name && $0.sourceId == sourceId }) else {
                return nil
            }
            if let installedTarget = record.installTarget {
                guard let request = try? TransferRequest.catalog(entry), let target = request.target,
                      target.slotKey == installedTarget.slotKey, target.release.identifier == record.identifier,
                      target.release.id != installedTarget.release.id,
                      target.release.advertisedVersion > record.advertisedVersion else { return nil }
                return request
            }
            return entry.advertisedVersion > record.advertisedVersion ? try? .catalog(entry) : nil
        case let .feed(feedURL):
            guard let feed = feeds.first(where: { $0.feedURL == feedURL }) else { return nil }
            return feed.advertisedVersion > record.advertisedVersion ? .feed(feed) : nil
        case .localImport:
            return nil
        }
    }
}
