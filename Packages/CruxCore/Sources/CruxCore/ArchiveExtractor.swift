import ArchiveBridge
import Foundation

/// Bounds Crux places on any archive it expands.
///
/// The defaults are generous for real docsets — the largest published ones are
/// a few hundred megabytes — while still refusing archives that would exhaust
/// the disk if fully expanded.
public struct ArchiveLimits: Equatable, Sendable {
    public var maximumEntryCount: Int
    public var maximumFileSize: Int64
    public var maximumTotalSize: Int64
    /// Uncompressed bytes allowed per compressed byte.
    public var maximumCompressionRatio: Double
    /// The ratio is only enforced after this much output, because tiny archives
    /// have misleadingly high ratios from headers and padding alone.
    public var compressionRatioGracePeriod: Int64

    public static let `default` = ArchiveLimits(
        maximumEntryCount: 300_000,
        maximumFileSize: 2 * 1_024 * 1_024 * 1_024,
        maximumTotalSize: 8 * 1_024 * 1_024 * 1_024,
        maximumCompressionRatio: 200,
        compressionRatioGracePeriod: 16 * 1_024 * 1_024
    )

    public init(
        maximumEntryCount: Int,
        maximumFileSize: Int64,
        maximumTotalSize: Int64,
        maximumCompressionRatio: Double,
        compressionRatioGracePeriod: Int64
    ) {
        self.maximumEntryCount = maximumEntryCount
        self.maximumFileSize = maximumFileSize
        self.maximumTotalSize = maximumTotalSize
        self.maximumCompressionRatio = maximumCompressionRatio
        self.compressionRatioGracePeriod = compressionRatioGracePeriod
    }
}

public enum ArchiveExtractionError: Error, Equatable, LocalizedError, Sendable {
    case unsafeEntryPath(String)
    case unsupportedEntryKind(String)
    case entryCountLimitExceeded(limit: Int)
    case fileSizeLimitExceeded(path: String, limit: Int64)
    case totalSizeLimitExceeded(limit: Int64)
    case compressionRatioLimitExceeded(limit: Double)
    case emptyArchive

    public var errorDescription: String? {
        switch self {
        case let .unsafeEntryPath(path):
            "The archive contains an entry that would be written outside the staging directory: \(path)"
        case let .unsupportedEntryKind(path):
            "The archive contains an unsupported entry type: \(path)"
        case let .entryCountLimitExceeded(limit):
            "The archive contains more than \(limit) entries."
        case let .fileSizeLimitExceeded(path, limit):
            "\(path) is larger than the \(limit) byte per-file limit."
        case let .totalSizeLimitExceeded(limit):
            "The archive expands to more than \(limit) bytes."
        case let .compressionRatioLimitExceeded(limit):
            "The archive expands more than \(Int(limit)) times its compressed size."
        case .emptyArchive:
            "The archive does not contain any files."
        }
    }
}

/// What an extraction produced, for progress reporting and auditing.
public struct ArchiveExtractionReport: Equatable, Sendable {
    public let entryCount: Int
    public let totalBytesWritten: Int64
}

public protocol ArchiveExtractor: Sendable {
    /// Expands `archiveURL` into `destinationURL`, which must already exist and
    /// be owned by the caller.
    func extract(
        archiveURL: URL,
        into destinationURL: URL,
        limits: ArchiveLimits,
        progress: (@Sendable (Int64) -> Void)?
    ) async throws -> ArchiveExtractionReport
}

/// Expands archives one entry at a time, enforcing Crux's safety policy.
///
/// Crux never asks libarchive to write files. It reads entry metadata and bytes
/// and does every filesystem operation itself, so path handling, permitted
/// entry types and size limits are decided by Swift code that can be tested
/// against hostile fixtures.
public struct StreamingArchiveExtractor: ArchiveExtractor {
    /// libarchive and FileHandle expose synchronous, blocking APIs. A dedicated
    /// utility queue keeps that work off Swift's cooperative executors, whose
    /// threads must remain available for actors, cancellation and UI updates.
    private static let workQueue = DispatchQueue(
        label: "com.zacharyhuo.Crux.archive-extraction",
        qos: .utility,
        attributes: .concurrent
    )

    public init() {}

    public func extract(
        archiveURL: URL,
        into destinationURL: URL,
        limits: ArchiveLimits = .default,
        progress: (@Sendable (Int64) -> Void)? = nil
    ) async throws -> ArchiveExtractionReport {
        let cancellation = ArchiveExtractionCancellation()

        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                Self.workQueue.async {
                    continuation.resume(with: Result {
                        try extractSynchronously(
                            archiveURL: archiveURL,
                            into: destinationURL,
                            limits: limits,
                            cancellation: cancellation,
                            progress: progress
                        )
                    })
                }
            }
        } onCancel: {
            // Dispatch work items do not inherit Swift Task cancellation. The
            // shared flag bridges that signal into the streaming read loop.
            cancellation.cancel()
        }
    }

    private func extractSynchronously(
        archiveURL: URL,
        into destinationURL: URL,
        limits: ArchiveLimits,
        cancellation: ArchiveExtractionCancellation,
        progress: (@Sendable (Int64) -> Void)?
    ) throws -> ArchiveExtractionReport {
        let destinationRoot = destinationURL.resolvingSymlinksInPath().standardizedFileURL
        let reader = try LibArchiveReader(fileURL: archiveURL)
        defer { reader.close() }

        var entryCount = 0
        var totalBytesWritten: Int64 = 0
        // Directories are created as needed; deferred symlinks are applied last
        // so a link can point at a sibling that appears later in the archive.
        var pendingSymbolicLinks: [(url: URL, target: String)] = []

        while let entry = try reader.nextEntry() {
            try cancellation.check()

            entryCount += 1
            guard entryCount <= limits.maximumEntryCount else {
                throw ArchiveExtractionError.entryCountLimitExceeded(limit: limits.maximumEntryCount)
            }

            guard let relativePath = Self.sanitizedRelativePath(entry.path) else {
                throw ArchiveExtractionError.unsafeEntryPath(entry.path)
            }
            let targetURL = destinationRoot.appending(path: relativePath, directoryHint: .notDirectory)
            guard Self.isContained(targetURL, in: destinationRoot) else {
                throw ArchiveExtractionError.unsafeEntryPath(entry.path)
            }

            switch entry.kind {
            case .directory:
                try FileManager.default.createDirectory(at: targetURL, withIntermediateDirectories: true)
                try reader.skipEntryData()

            case .symbolicLink:
                guard let target = entry.symbolicLinkTarget,
                      Self.isSafeSymbolicLink(target, at: relativePath) else {
                    throw ArchiveExtractionError.unsafeEntryPath(entry.path)
                }
                pendingSymbolicLinks.append((targetURL, target))
                try reader.skipEntryData()

            case .regularFile:
                guard entry.hardLinkTarget == nil else {
                    // Hard links can alias a file the policy already vetted, so
                    // they are refused rather than resolved.
                    throw ArchiveExtractionError.unsupportedEntryKind(entry.path)
                }
                let written = try writeFile(
                    from: reader,
                    to: targetURL,
                    entryPath: entry.path,
                    limits: limits,
                    cancellation: cancellation,
                    totalBytesWritten: &totalBytesWritten
                )
                progress?(totalBytesWritten)
                _ = written

            case .other:
                // Device nodes, sockets and FIFOs have no place in a docset.
                throw ArchiveExtractionError.unsupportedEntryKind(entry.path)
            }
        }

        guard entryCount > 0 else { throw ArchiveExtractionError.emptyArchive }

        for link in pendingSymbolicLinks {
            try FileManager.default.createDirectory(
                at: link.url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? FileManager.default.removeItem(at: link.url)
            try FileManager.default.createSymbolicLink(atPath: link.url.path, withDestinationPath: link.target)
        }

        return ArchiveExtractionReport(entryCount: entryCount, totalBytesWritten: totalBytesWritten)
    }

    // MARK: - Writing

    private func writeFile(
        from reader: LibArchiveReader,
        to targetURL: URL,
        entryPath: String,
        limits: ArchiveLimits,
        cancellation: ArchiveExtractionCancellation,
        totalBytesWritten: inout Int64
    ) throws -> Int64 {
        try FileManager.default.createDirectory(
            at: targetURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard FileManager.default.createFile(atPath: targetURL.path, contents: nil) else {
            throw ArchiveExtractionError.unsafeEntryPath(entryPath)
        }
        let handle = try FileHandle(forWritingTo: targetURL)
        defer { try? handle.close() }

        var entryBytes: Int64 = 0
        while let chunk = try reader.readChunk() {
            try cancellation.check()
            entryBytes += Int64(chunk.count)
            totalBytesWritten += Int64(chunk.count)

            // Limits are checked against bytes actually produced, not against
            // the sizes the archive declares, because those can be forged.
            guard entryBytes <= limits.maximumFileSize else {
                throw ArchiveExtractionError.fileSizeLimitExceeded(
                    path: entryPath,
                    limit: limits.maximumFileSize
                )
            }
            guard totalBytesWritten <= limits.maximumTotalSize else {
                throw ArchiveExtractionError.totalSizeLimitExceeded(limit: limits.maximumTotalSize)
            }
            try checkCompressionRatio(reader: reader, produced: totalBytesWritten, limits: limits)

            try handle.write(contentsOf: chunk)
        }
        return entryBytes
    }

    private func checkCompressionRatio(
        reader: LibArchiveReader,
        produced: Int64,
        limits: ArchiveLimits
    ) throws {
        guard produced > limits.compressionRatioGracePeriod else { return }
        let consumed = max(reader.compressedBytesRead, 1)
        guard Double(produced) / Double(consumed) <= limits.maximumCompressionRatio else {
            throw ArchiveExtractionError.compressionRatioLimitExceeded(
                limit: limits.maximumCompressionRatio
            )
        }
    }

    // MARK: - Path policy

    /// Rejects absolute paths, drive-style prefixes, `..`, and NUL bytes.
    ///
    /// A leading `./` is normalized away because tar archives routinely use it.
    static func sanitizedRelativePath(_ rawPath: String) -> String? {
        guard !rawPath.isEmpty,
              !rawPath.hasPrefix("/"),
              !rawPath.hasPrefix("~"),
              !rawPath.contains("\0"),
              !rawPath.contains("\\") else {
            return nil
        }

        var components: [String] = []
        for component in rawPath.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." { continue }
            guard component != ".." else { return nil }
            components.append(String(component))
        }
        return components.isEmpty ? nil : components.joined(separator: "/")
    }

    /// Allows only links that stay inside the archive's own tree.
    ///
    /// The check is textual and done before anything is created on disk, so an
    /// escaping link never exists even momentarily.
    static func isSafeSymbolicLink(_ target: String, at entryPath: String) -> Bool {
        guard !target.isEmpty, !target.hasPrefix("/"), !target.contains("\0") else { return false }

        var depth = entryPath.split(separator: "/", omittingEmptySubsequences: true).count - 1
        for component in target.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." { continue }
            if component == ".." {
                depth -= 1
                guard depth >= 0 else { return false }
            } else {
                depth += 1
            }
        }
        return true
    }

    private static func isContained(_ url: URL, in root: URL) -> Bool {
        let standardized = url.standardizedFileURL
        return standardized.path.hasPrefix(root.path + "/")
    }
}

/// Thread-safe cancellation token shared by the structured Swift task and the
/// blocking libarchive worker. It is intentionally private to the bridge.
private final class ArchiveExtractionCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var isCancelled = false

    func cancel() {
        lock.withLock { isCancelled = true }
    }

    func check() throws {
        if lock.withLock({ isCancelled }) {
            throw CancellationError()
        }
    }
}
