import CLibArchive
import Foundation

/// The kinds of archive members Crux distinguishes.
///
/// Everything that is not a regular file, directory or symbolic link is
/// reported as `other` so the policy layer can reject it without needing to
/// know about device nodes, sockets or FIFOs individually.
public enum ArchiveEntryKind: Equatable, Sendable {
    case regularFile
    case directory
    case symbolicLink
    case other
}

/// One archive member's metadata, already copied out of libarchive's storage.
public struct ArchiveEntryHeader: Equatable, Sendable {
    public let path: String
    public let kind: ArchiveEntryKind
    /// The declared uncompressed size. Archives may lie, so callers must also
    /// enforce limits against the bytes they actually read.
    public let declaredSize: Int64
    public let symbolicLinkTarget: String?
    public let hardLinkTarget: String?
}

public enum LibArchiveError: Error, Equatable, LocalizedError, Sendable {
    case couldNotAllocateReader
    case couldNotOpen(path: String, message: String)
    case readFailed(message: String)

    public var errorDescription: String? {
        switch self {
        case .couldNotAllocateReader:
            "The archive reader could not be created."
        case let .couldNotOpen(path, message):
            "\(URL(fileURLWithPath: path).lastPathComponent) could not be opened as an archive: \(message)"
        case let .readFailed(message):
            "The archive could not be read: \(message)"
        }
    }
}

/// A minimal, safe Swift surface over libarchive's streaming read API.
///
/// The libarchive handle and every unsafe pointer stay inside this type. The
/// reader is intentionally not `Sendable`: callers must confine one instance to
/// a single task, which is how Crux keeps the C library away from concurrent use.
public final class LibArchiveReader {
    /// libarchive reads the file in blocks of this size.
    public static let readBlockSize = 64 * 1024

    private let handle: OpaquePointer
    private var isClosed = false

    public init(fileURL: URL) throws {
        guard let handle = archive_read_new() else {
            throw LibArchiveError.couldNotAllocateReader
        }
        // The pinned build only includes the decompressors and formats Crux
        // needs, so enabling "all" here still yields a small attack surface.
        archive_read_support_filter_all(handle)
        archive_read_support_format_all(handle)

        let status = fileURL.path.withCString {
            archive_read_open_filename(handle, $0, Self.readBlockSize)
        }
        guard status == ARCHIVE_OK else {
            let message = Self.errorMessage(handle)
            archive_read_free(handle)
            throw LibArchiveError.couldNotOpen(path: fileURL.path, message: message)
        }
        self.handle = handle
    }

    deinit {
        if !isClosed {
            archive_read_free(handle)
        }
    }

    public func close() {
        guard !isClosed else { return }
        isClosed = true
        archive_read_free(handle)
    }

    /// Advances to the next member, or returns `nil` at the end of the archive.
    public func nextEntry() throws -> ArchiveEntryHeader? {
        var entry: OpaquePointer?
        let status = archive_read_next_header(handle, &entry)
        if status == ARCHIVE_EOF { return nil }
        guard status == ARCHIVE_OK, let entry else {
            throw LibArchiveError.readFailed(message: Self.errorMessage(handle))
        }

        return ArchiveEntryHeader(
            path: Self.pathname(of: entry),
            kind: Self.kind(of: entry),
            declaredSize: archive_entry_size(entry),
            symbolicLinkTarget: archive_entry_symlink(entry).map { String(cString: $0) },
            hardLinkTarget: archive_entry_hardlink(entry).map { String(cString: $0) }
        )
    }

    /// Reads the next chunk of the current entry, or `nil` once it is exhausted.
    public func readChunk(maximumSize: Int = LibArchiveReader.readBlockSize) throws -> Data? {
        var buffer = Data(count: maximumSize)
        let bytesRead: Int = try buffer.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else {
                throw LibArchiveError.readFailed(message: "The read buffer was unavailable.")
            }
            let result = archive_read_data(handle, base, maximumSize)
            guard result >= 0 else {
                throw LibArchiveError.readFailed(message: Self.errorMessage(handle))
            }
            return result
        }

        guard bytesRead > 0 else { return nil }
        buffer.removeSubrange(bytesRead...)
        return buffer
    }

    public func skipEntryData() throws {
        guard archive_read_data_skip(handle) == ARCHIVE_OK else {
            throw LibArchiveError.readFailed(message: Self.errorMessage(handle))
        }
    }

    /// Compressed bytes consumed so far, used to bound the compression ratio.
    public var compressedBytesRead: Int64 {
        archive_filter_bytes(handle, -1)
    }

    // MARK: - Pointer handling

    private static func pathname(of entry: OpaquePointer) -> String {
        // Prefer the UTF-8 accessor; some archives only populate the raw one.
        if let utf8 = archive_entry_pathname_utf8(entry) {
            return String(cString: utf8)
        }
        if let raw = archive_entry_pathname(entry) {
            return String(cString: raw)
        }
        return ""
    }

    /// libarchive declares `AE_IFMT` and friends as cast macros, which Swift
    /// cannot import. They are the standard POSIX file-type bits.
    private enum FileTypeMask {
        static let mask: mode_t = 0o170000
        static let regularFile: mode_t = 0o100000
        static let symbolicLink: mode_t = 0o120000
        static let directory: mode_t = 0o040000
    }

    private static func kind(of entry: OpaquePointer) -> ArchiveEntryKind {
        switch archive_entry_filetype(entry) & FileTypeMask.mask {
        case FileTypeMask.regularFile: .regularFile
        case FileTypeMask.directory: .directory
        case FileTypeMask.symbolicLink: .symbolicLink
        default: .other
        }
    }

    private static func errorMessage(_ handle: OpaquePointer) -> String {
        guard let message = archive_error_string(handle) else {
            return "unknown libarchive error"
        }
        return String(cString: message)
    }
}
