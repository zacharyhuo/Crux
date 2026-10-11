import Compression
import Foundation

/// A member to place in a synthetic tar archive.
///
/// Fixtures are built byte by byte rather than with the `tar` tool so tests can
/// express entries a well-behaved archiver refuses to produce, such as absolute
/// paths, `..` traversal and device nodes.
struct TestArchiveEntry {
    enum Kind {
        case regularFile(Data)
        case directory
        case symbolicLink(target: String)
        case hardLink(target: String)
        case characterDevice
    }

    let path: String
    let kind: Kind

    static func file(_ path: String, contents: String) -> TestArchiveEntry {
        TestArchiveEntry(path: path, kind: .regularFile(Data(contents.utf8)))
    }

    static func file(_ path: String, bytes: Data) -> TestArchiveEntry {
        TestArchiveEntry(path: path, kind: .regularFile(bytes))
    }

    static func directory(_ path: String) -> TestArchiveEntry {
        TestArchiveEntry(path: path, kind: .directory)
    }

    static func symbolicLink(_ path: String, to target: String) -> TestArchiveEntry {
        TestArchiveEntry(path: path, kind: .symbolicLink(target: target))
    }
}

enum TestArchiveFixture {
    /// Writes an uncompressed tar archive.
    @discardableResult
    static func writeTar(_ entries: [TestArchiveEntry], to url: URL) throws -> URL {
        try tarData(entries).write(to: url)
        return url
    }

    /// Writes a gzip-compressed tar archive, the format docsets ship in.
    @discardableResult
    static func writeTarGzip(_ entries: [TestArchiveEntry], to url: URL) throws -> URL {
        try gzip(tarData(entries)).write(to: url)
        return url
    }

    /// A well-formed docset packaged as `.tgz`, matching the common layout of a
    /// single `.docset` bundle at the archive root.
    @discardableResult
    static func writeDocsetArchive(
        to url: URL,
        bundleName: String = "Fixture",
        identifier: String = "dev.crux.fixture",
        indexData: Data
    ) throws -> URL {
        let root = "\(bundleName).docset"
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>CFBundleIdentifier</key><string>\(identifier)</string>
        <key>CFBundleName</key><string>\(bundleName)</string>
        <key>CFBundleShortVersionString</key><string>1.0</string>
        <key>dashIndexFilePath</key><string>index.html</string>
        </dict></plist>
        """
        return try writeTarGzip(
            [
                .directory(root),
                .file("\(root)/Contents/Info.plist", contents: plist),
                .file("\(root)/Contents/Resources/Documents/index.html", contents: "<html>fixture</html>"),
                TestArchiveEntry(
                    path: "\(root)/Contents/Resources/docSet.dsidx",
                    kind: .regularFile(indexData)
                ),
            ],
            to: url
        )
    }

    // MARK: - tar

    static func tarData(_ entries: [TestArchiveEntry]) -> Data {
        var output = Data()
        for entry in entries {
            switch entry.kind {
            case let .regularFile(contents):
                output.append(header(for: entry, typeFlag: "0", size: contents.count))
                output.append(contents)
                output.append(padding(for: contents.count))
            case .directory:
                output.append(header(for: entry, typeFlag: "5", size: 0))
            case let .symbolicLink(target):
                output.append(header(for: entry, typeFlag: "2", size: 0, linkName: target))
            case let .hardLink(target):
                output.append(header(for: entry, typeFlag: "1", size: 0, linkName: target))
            case .characterDevice:
                output.append(header(for: entry, typeFlag: "3", size: 0))
            }
        }
        // Two zero blocks terminate a tar stream.
        output.append(Data(count: 1_024))
        return output
    }

    private static func header(
        for entry: TestArchiveEntry,
        typeFlag: Character,
        size: Int,
        linkName: String = ""
    ) -> Data {
        var header = [UInt8](repeating: 0, count: 512)

        func write(_ string: String, at offset: Int, length: Int) {
            for (index, byte) in Array(string.utf8).prefix(length).enumerated() {
                header[offset + index] = byte
            }
        }
        func writeOctal(_ value: Int, at offset: Int, length: Int) {
            write(String(format: "%0\(length - 1)o", value), at: offset, length: length - 1)
        }

        write(entry.path, at: 0, length: 100)
        writeOctal(0o644, at: 100, length: 8)
        writeOctal(0, at: 108, length: 8)
        writeOctal(0, at: 116, length: 8)
        writeOctal(size, at: 124, length: 12)
        writeOctal(0, at: 136, length: 12)
        // The checksum is computed with its own field filled with spaces.
        for index in 148..<156 { header[index] = 0x20 }
        header[156] = Array(String(typeFlag).utf8)[0]
        write(linkName, at: 157, length: 100)
        write("ustar", at: 257, length: 6)
        write("00", at: 263, length: 2)

        let checksum = header.reduce(0) { $0 + Int($1) }
        write(String(format: "%06o", checksum), at: 148, length: 6)
        header[154] = 0
        header[155] = 0x20

        return Data(header)
    }

    private static func padding(for size: Int) -> Data {
        let remainder = size % 512
        return remainder == 0 ? Data() : Data(count: 512 - remainder)
    }

    // MARK: - gzip

    /// Wraps raw DEFLATE output in a gzip container.
    ///
    /// Apple's `.zlib` algorithm emits headerless DEFLATE, so only the gzip
    /// header, CRC-32 and length trailer have to be added by hand.
    static func gzip(_ data: Data) -> Data {
        var output = Data([0x1f, 0x8b, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0xff])
        output.append(deflate(data))
        var crc = crc32(data).littleEndian
        var size = UInt32(truncatingIfNeeded: data.count).littleEndian
        withUnsafeBytes(of: &crc) { output.append(contentsOf: $0) }
        withUnsafeBytes(of: &size) { output.append(contentsOf: $0) }
        return output
    }

    private static func deflate(_ data: Data) -> Data {
        guard !data.isEmpty else { return Data([0x03, 0x00]) }
        let destinationCapacity = data.count + 4_096
        var destination = Data(count: destinationCapacity)
        let written = destination.withUnsafeMutableBytes { destinationBuffer in
            data.withUnsafeBytes { sourceBuffer in
                compression_encode_buffer(
                    destinationBuffer.bindMemory(to: UInt8.self).baseAddress!,
                    destinationCapacity,
                    sourceBuffer.bindMemory(to: UInt8.self).baseAddress!,
                    data.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        destination.removeSubrange(written...)
        return destination
    }

    private static let crcTable: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) == 1 ? (0xedb8_8320 ^ (value >> 1)) : (value >> 1)
        }
        return value
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xff)] ^ (crc >> 8)
        }
        return crc ^ 0xffff_ffff
    }
}
