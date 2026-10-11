import Foundation

/// Progress reported while an artifact becomes an installed docset.
public enum InstallationPhase: Equatable, Sendable {
    case staging
    case expanding(bytesWritten: Int64)
    case validating
    case activating
}

public enum DocsetInstallError: Error, Equatable, LocalizedError, Sendable {
    case noDocsetInArchive
    case multipleDocsetsInArchive(count: Int)
    case identityMismatch(expected: String, found: String)
    case notInstalled(identifier: String)
    case activationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noDocsetInArchive:
            "The archive does not contain a .docset bundle."
        case let .multipleDocsetsInArchive(count):
            "The archive contains \(count) docset bundles; Crux installs one per archive."
        case let .identityMismatch(expected, found):
            "This archive contains \(found), but \(expected) was being updated."
        case let .notInstalled(identifier):
            "\(identifier) is not installed."
        case let .activationFailed(message):
            "The docset could not be moved into place: \(message)"
        }
    }
}

/// Turns a downloaded or user-supplied artifact into an installed docset.
///
/// Every install follows the same route regardless of where the artifact came
/// from: expand into an isolated staging directory on the destination volume,
/// validate the result, then swap it into place with a single atomic operation.
/// Nothing under the docsets directory is modified until validation passed.
public actor DocsetInstaller {
    /// Staging lives beside the installed docsets so the final move is a
    /// same-volume rename rather than a copy that could fail halfway.
    private static let stagingDirectoryName = ".staging"

    private let extractor: any ArchiveExtractor
    private let parser: DocsetParser
    private let limits: ArchiveLimits

    public init(
        extractor: any ArchiveExtractor = StreamingArchiveExtractor(),
        parser: DocsetParser = DocsetParser(),
        limits: ArchiveLimits = .default
    ) {
        self.extractor = extractor
        self.parser = parser
        self.limits = limits
    }

    /// Installs an artifact, replacing an existing docset with the same
    /// identifier if one is present.
    ///
    /// `expectedIdentifier` is supplied when updating, so an archive that turns
    /// out to contain a different docset is rejected instead of silently
    /// replacing the wrong entry.
    @discardableResult
    public func install(
        artifactAt sourceURL: URL,
        into docsetsDirectory: URL,
        replacing existing: DocsetDescriptor? = nil,
        expectedIdentifier: String? = nil,
        fallbackIconData: Data? = nil,
        destinationFileName: String? = nil,
        resolveExisting: (@Sendable (DocsetDescriptor) async throws -> DocsetDescriptor?)? = nil,
        validateCandidate: (@Sendable (DocsetDescriptor, URL) async throws -> Void)? = nil,
        progress: (@Sendable (InstallationPhase) -> Void)? = nil
    ) async throws -> DocsetDescriptor {
        let artifact = try DocsetArtifact.detect(at: sourceURL)
        try FileManager.default.createDirectory(at: docsetsDirectory, withIntermediateDirectories: true)

        progress?(.staging)
        let stagingURL = try makeStagingDirectory(in: docsetsDirectory)
        defer { try? FileManager.default.removeItem(at: stagingURL) }

        switch artifact {
        case let .bundle(bundleURL):
            // A local import must leave the user's file untouched, so the
            // bundle is copied rather than moved.
            let copyURL = stagingURL.appending(
                path: bundleURL.lastPathComponent,
                directoryHint: .isDirectory
            )
            try FileManager.default.copyItem(at: bundleURL, to: copyURL)
        case let .archive(archiveURL, _):
            _ = try await extractor.extract(
                archiveURL: archiveURL,
                into: stagingURL,
                limits: limits,
                progress: { bytes in progress?(.expanding(bytesWritten: bytes)) }
            )
        }

        // Extractors are protocol values and a custom implementation may not
        // cooperate with task cancellation. This explicit boundary guarantees
        // cancellation is observed before validation or installed state changes.
        try Task.checkCancellation()

        progress?(.validating)
        let stagedBundleURL = try locateDocsetBundle(in: stagingURL)
        let stagedDescriptor = try parser.parse(bundleAt: stagedBundleURL)
        let resolvedExisting = try await resolveExisting?(stagedDescriptor) ?? existing
        if let resolvedExisting {
            guard resolvedExisting.bundleIdentifier == stagedDescriptor.bundleIdentifier,
                  resolvedExisting.bundleURL.standardizedFileURL.deletingLastPathComponent() == docsetsDirectory.standardizedFileURL else {
                throw DocsetReplacementError.conflictingInstall
            }
        }

        if let expectedIdentifier, stagedDescriptor.identifier != expectedIdentifier {
            throw DocsetInstallError.identityMismatch(
                expected: expectedIdentifier,
                found: stagedDescriptor.identifier
            )
        }

        if let fallbackIconData = fallbackIconData.flatMap(CatalogEntry.validatedIconData),
           !hasBundleIcon(at: stagedBundleURL) {
            try fallbackIconData.write(
                to: stagedBundleURL.appending(path: "icon.png", directoryHint: .notDirectory),
                options: .atomic
            )
        }

        let destinationURL = installationURL(
            for: stagedDescriptor,
            in: docsetsDirectory,
            replacing: resolvedExisting
        )
        let finalURL: URL
        if resolvedExisting == nil, let destinationFileName {
            guard destinationFileName.hasSuffix(".docset"),
                  !destinationFileName.contains("/"), !destinationFileName.contains("\\"),
                  !destinationFileName.hasPrefix(".") else { throw DocsetReplacementError.unsafeState }
            finalURL = docsetsDirectory.appending(path: destinationFileName, directoryHint: .isDirectory)
        } else { finalURL = destinationURL }
        try await validateCandidate?(stagedDescriptor, finalURL)
        try Task.checkCancellation()
        progress?(.activating)
        try activate(stagedBundleURL: stagedBundleURL, at: finalURL)

        // Re-parse from the final location so the descriptor stored in the
        // registry carries the installed paths, not the staging ones.
        let parsed = try parser.parse(bundleAt: finalURL)
        return resolvedExisting.map { parsed.identified(as: $0.identifier) } ?? parsed
    }

    public func uninstall(_ descriptor: DocsetDescriptor) throws {
        guard FileManager.default.fileExists(atPath: descriptor.bundleURL.path) else {
            throw DocsetInstallError.notInstalled(identifier: descriptor.identifier)
        }
        try FileManager.default.removeItem(at: descriptor.bundleURL)
    }

    /// Removes staging left behind by a crash or forced quit.
    public func removeOrphanedStaging(in docsetsDirectory: URL) {
        let stagingRoot = docsetsDirectory.appending(
            path: Self.stagingDirectoryName,
            directoryHint: .isDirectory
        )
        try? FileManager.default.removeItem(at: stagingRoot)
    }

    // MARK: - Steps

    private func makeStagingDirectory(in docsetsDirectory: URL) throws -> URL {
        let stagingURL = docsetsDirectory
            .appending(path: Self.stagingDirectoryName, directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: stagingURL, withIntermediateDirectories: true)
        return stagingURL
    }

    /// Finds the single `.docset` bundle an archive is expected to contain.
    ///
    /// Publishers wrap the bundle inconsistently: sometimes at the archive root,
    /// sometimes inside one wrapper directory. Both layouts are accepted, but an
    /// archive with several bundles is refused rather than guessed at.
    private func locateDocsetBundle(in stagingURL: URL) throws -> URL {
        var candidates = docsetBundles(directlyIn: stagingURL)
        if candidates.isEmpty {
            for directory in subdirectories(of: stagingURL) {
                candidates.append(contentsOf: docsetBundles(directlyIn: directory))
            }
        }

        guard let bundleURL = candidates.first else { throw DocsetInstallError.noDocsetInArchive }
        guard candidates.count == 1 else {
            throw DocsetInstallError.multipleDocsetsInArchive(count: candidates.count)
        }
        return bundleURL
    }

    private func docsetBundles(directlyIn directory: URL) -> [URL] {
        subdirectories(of: directory).filter { $0.pathExtension.lowercased() == "docset" }
    }

    private func subdirectories(of directory: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func installationURL(
        for descriptor: DocsetDescriptor,
        in docsetsDirectory: URL,
        replacing existing: DocsetDescriptor?
    ) -> URL {
        // Updating in place keeps the existing folder name, so a rename upstream
        // cannot leave two copies of the same docset behind.
        if let existing, existing.bundleIdentifier == descriptor.bundleIdentifier {
            return existing.bundleURL
        }
        // The parser validates supply bundleName as a bounded filesystem-safe
        // component. Display names may contain spaces and must not change the
        // canonical name checked by the versioned replacement transaction.
        // This naming claim is not ownership: target/registry checks still apply.
        let folderName = descriptor.supplyMetadata?.bundleName
            ?? descriptor.name.replacingOccurrences(of: "/", with: "_")
        return docsetsDirectory.appending(path: "\(folderName).docset", directoryHint: .isDirectory)
    }

    private func hasBundleIcon(at bundleURL: URL) -> Bool {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: bundleURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return entries.contains { url in
            let basename = url.deletingPathExtension().lastPathComponent.lowercased()
            let supported = ["png", "jpg", "jpeg", "gif"].contains(url.pathExtension.lowercased())
            guard supported && (basename == "icon" || basename == "icon@2x"),
                  let values = try? url.resourceValues(forKeys: [
                      .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
                  ]),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  (values.fileSize ?? 0) <= CatalogEntry.maximumIconBytes,
                  let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
                return false
            }
            return CatalogEntry.validatedIconData(data) != nil
        }
    }

    /// Moves the validated bundle into place without ever leaving the
    /// destination in a half-written state.
    private func activate(stagedBundleURL: URL, at destinationURL: URL) throws {
        do {
            guard FileManager.default.fileExists(atPath: destinationURL.path) else {
                try FileManager.default.moveItem(at: stagedBundleURL, to: destinationURL)
                return
            }
            // replaceItemAt swaps directories atomically and puts the previous
            // version back itself if the swap cannot be completed.
            _ = try FileManager.default.replaceItemAt(
                destinationURL,
                withItemAt: stagedBundleURL,
                backupItemName: destinationURL.lastPathComponent + ".previous",
                options: []
            )
        } catch {
            throw DocsetInstallError.activationFailed(error.localizedDescription)
        }
    }
}
