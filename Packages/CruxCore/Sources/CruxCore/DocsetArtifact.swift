import Foundation

/// An input that can enter Crux's installation pipeline.
public enum DocsetArtifact: Equatable, Sendable {
    case bundle(URL)
    case archive(URL, format: DocsetArchiveFormat)

    public static func detect(
        at url: URL,
        fileManager: FileManager = .default
    ) throws -> DocsetArtifact {
        let standardizedURL = url.standardizedFileURL
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: standardizedURL.path, isDirectory: &isDirectory) else {
            throw DocsetArtifactError.notFound(standardizedURL)
        }

        if isDirectory.boolValue, standardizedURL.pathExtension.lowercased() == "docset" {
            return .bundle(standardizedURL)
        }

        guard !isDirectory.boolValue else {
            throw DocsetArtifactError.unsupportedFormat(standardizedURL)
        }

        let filename = standardizedURL.lastPathComponent.lowercased()
        if filename.hasSuffix(".tgz") || filename.hasSuffix(".tar.gz") {
            return .archive(standardizedURL, format: .tarGzip)
        }

        throw DocsetArtifactError.unsupportedFormat(standardizedURL)
    }
}

public enum DocsetArchiveFormat: String, Codable, Equatable, Sendable {
    case tarGzip
}

public enum DocsetArtifactError: Error, Equatable, LocalizedError, Sendable {
    case notFound(URL)
    case unsupportedFormat(URL)

    public var errorDescription: String? {
        switch self {
        case let .notFound(url):
            "No file or directory exists at \(url.path)."
        case let .unsupportedFormat(url):
            "\(url.lastPathComponent) is not a supported docset bundle or archive."
        }
    }
}
