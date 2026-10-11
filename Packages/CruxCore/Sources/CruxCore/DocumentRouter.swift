import Foundation
import UniformTypeIdentifiers

/// One docset the loopback server is currently allowed to serve.
public struct DocumentRoot: Equatable, Sendable {
    public let identifier: String
    /// The symlink-resolved `Contents/Resources/Documents` directory.
    public let documentsURL: URL
    public let isJavaScriptEnabled: Bool
    public let allowsRemoteResources: Bool

    public init(
        identifier: String,
        documentsURL: URL,
        isJavaScriptEnabled: Bool,
        allowsRemoteResources: Bool
    ) {
        self.identifier = identifier
        self.documentsURL = documentsURL.resolvingSymlinksInPath().standardizedFileURL
        self.isJavaScriptEnabled = isJavaScriptEnabled
        self.allowsRemoteResources = allowsRemoteResources
    }
}

/// Resolves loopback URLs to docset files and decides the response policy.
///
/// The router performs no socket work, so every rule below — token checking,
/// traversal rejection, MIME typing, range handling and the content security
/// policy — is directly testable.
public struct DocumentRouter: Sendable {
    /// A per-run secret. It is the first path component rather than a query item
    /// so that relative links inside a document stay inside the authorized path.
    public let token: String
    private let rootsByIdentifier: [String: DocumentRoot]

    public init(token: String, roots: [DocumentRoot]) {
        self.token = token
        rootsByIdentifier = Dictionary(roots.map { ($0.identifier, $0) }, uniquingKeysWith: { _, last in last })
    }

    /// Builds the loopback URL for a document, or `nil` when the path is unsafe
    /// or the docset is not currently served.
    public func url(
        host: String,
        port: UInt16,
        docsetIdentifier: String,
        relativePath: String,
        fragment: String? = nil
    ) -> URL? {
        guard let root = rootsByIdentifier[docsetIdentifier],
              Self.sanitize(relativePath: relativePath) != nil else {
            return nil
        }
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = Int(port)
        components.path = "/" + ([token, root.identifier] + relativePath.split(separator: "/").map(String.init))
            .joined(separator: "/")
        components.fragment = fragment
        return components.url
    }

    /// The inverse of `url(host:port:docsetIdentifier:relativePath:fragment:)`.
    ///
    /// The reader uses this to turn a navigation the web view performed back
    /// into a history entry it can persist and restore.
    public func location(for url: URL) -> ReaderLocation? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "http" else {
            return nil
        }

        var pathComponents = components.percentEncodedPath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard pathComponents.count >= 2, pathComponents.removeFirst() == token else { return nil }

        let identifier = pathComponents.removeFirst()
        guard rootsByIdentifier[identifier] != nil else { return nil }

        var decoded: [String] = []
        for component in pathComponents {
            guard let value = component.removingPercentEncoding else { return nil }
            decoded.append(value)
        }
        let relativePath = decoded.isEmpty ? "index.html" : decoded.joined(separator: "/")
        guard let sanitized = Self.sanitize(relativePath: relativePath) else { return nil }

        return ReaderLocation(
            docsetIdentifier: identifier,
            relativePath: sanitized,
            fragment: components.fragment
        )
    }

    public func response(for head: HTTPRequestHead) -> HTTPResponseHead {
        guard head.method == "GET" || head.method == "HEAD" else {
            return HTTPResponseHead(
                status: .methodNotAllowed,
                headers: ["Allow": "GET, HEAD"],
                body: .text("Only GET and HEAD are supported.\n")
            )
        }

        guard let resolved = resolve(target: head.target) else {
            // Unknown tokens, unknown docsets and traversal attempts share one
            // response so the server never confirms which part was wrong.
            return HTTPResponseHead(status: .notFound, body: .text("Not found.\n"))
        }

        guard let fileSize = regularFileSize(at: resolved.fileURL) else {
            return HTTPResponseHead(status: .notFound, body: .text("Not found.\n"))
        }

        let contentType = Self.contentType(for: resolved.fileURL)
        var headers = [
            "Content-Type": contentType,
            "Accept-Ranges": "bytes",
            "Cache-Control": "no-store",
            // Never disclose the per-launch access token in a Referer header
            // when an allowed HTTPS resource is requested.
            "Referrer-Policy": "no-referrer",
            "X-Content-Type-Options": "nosniff",
        ]
        if contentType.hasPrefix("text/html") {
            headers["Content-Security-Policy"] = Self.contentSecurityPolicy(for: resolved.root)
        }

        guard let rangeHeader = head.headers["range"] else {
            let fullRange = fileSize == 0 ? nil : 0...(fileSize - 1)
            return HTTPResponseHead(
                status: .ok,
                headers: headers,
                body: fullRange.map { .file(url: resolved.fileURL, range: $0) } ?? .empty
            )
        }

        switch Self.parseRange(rangeHeader, fileSize: fileSize) {
        case .unsupported:
            let fullRange = fileSize == 0 ? nil : 0...(fileSize - 1)
            return HTTPResponseHead(
                status: .ok,
                headers: headers,
                body: fullRange.map { .file(url: resolved.fileURL, range: $0) } ?? .empty
            )
        case .unsatisfiable:
            headers["Content-Range"] = "bytes */\(fileSize)"
            return HTTPResponseHead(
                status: .rangeNotSatisfiable,
                headers: headers,
                body: .text("Requested range not satisfiable.\n")
            )
        case let .satisfiable(range):
            headers["Content-Range"] = "bytes \(range.lowerBound)-\(range.upperBound)/\(fileSize)"
            return HTTPResponseHead(
                status: .partialContent,
                headers: headers,
                body: .file(url: resolved.fileURL, range: range)
            )
        }
    }

    // MARK: - Path resolution

    private struct ResolvedTarget {
        let root: DocumentRoot
        let fileURL: URL
    }

    private func resolve(target: String) -> ResolvedTarget? {
        // A query string or fragment never participates in file resolution.
        let path = URLComponents(string: target)?.percentEncodedPath
            ?? String(target.prefix(while: { $0 != "?" && $0 != "#" }))

        var components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        // A well-formed origin-form target starts with "/", producing a leading empty component.
        guard components.first == "" else { return nil }
        components.removeFirst()

        guard components.count >= 2 else { return nil }
        let requestToken = components.removeFirst()
        let identifier = components.removeFirst()
        // Constant-time-ish comparison is unnecessary here: the listener is bound
        // to loopback, so an attacker able to time it can already read the token.
        guard requestToken == token, let root = rootsByIdentifier[identifier] else { return nil }

        var decoded: [String] = []
        for component in components where !component.isEmpty {
            guard let value = component.removingPercentEncoding, !value.isEmpty else { return nil }
            decoded.append(value)
        }
        let relativePath = decoded.joined(separator: "/")
        // An empty tail means the docset root, which maps to its landing page.
        guard let sanitized = Self.sanitize(relativePath: relativePath.isEmpty ? "index.html" : relativePath) else {
            return nil
        }

        let fileURL = root.documentsURL
            .appending(path: sanitized, directoryHint: .notDirectory)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        // Symlinks are resolved first so a link inside the docset cannot point out of it.
        guard fileURL.path.hasPrefix(root.documentsURL.path + "/") else { return nil }
        return ResolvedTarget(root: root, fileURL: fileURL)
    }

    /// Rejects absolute paths, empty components, `.`, `..` and NUL bytes.
    static func sanitize(relativePath: String) -> String? {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.contains("\0"),
              !relativePath.contains("\\") else {
            return nil
        }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        return components.joined(separator: "/")
    }

    private func regularFileSize(at url: URL) -> Int? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let size = values.fileSize else {
            return nil
        }
        return size
    }

    // MARK: - Policy

    /// Builds the per-document content security policy.
    ///
    /// `'self'` is the loopback origin, so plain HTTP resources on any other host
    /// are refused whether or not remote content is allowed. Page-authored
    /// scripts follow the parsed docset policy, which defaults to enabled.
    static func contentSecurityPolicy(for root: DocumentRoot) -> String {
        let remote = root.allowsRemoteResources ? " https:" : ""
        let scriptSource = root.isJavaScriptEnabled
            ? "'self'\(remote) 'unsafe-inline' 'unsafe-eval'"
            : "'none'"
        return [
            "default-src 'self'\(remote) data:",
            "script-src \(scriptSource)",
            "style-src 'self'\(remote) 'unsafe-inline'",
            "img-src 'self'\(remote) data:",
            "font-src 'self'\(remote) data:",
            "media-src 'self'\(remote) data:",
            "connect-src 'self'\(remote)",
            "frame-src 'self'\(remote)",
            "object-src 'none'",
            "base-uri 'none'",
            "form-action 'none'",
        ].joined(separator: "; ")
    }

    static func contentType(for url: URL) -> String {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()),
              let mimeType = type.preferredMIMEType else {
            return "application/octet-stream"
        }
        guard type.conforms(to: .text) || type == .svg || type == .json else {
            return mimeType
        }
        return "\(mimeType); charset=utf-8"
    }

    // MARK: - Range

    enum RangeResolution: Equatable {
        /// Multi-range and non-byte units fall back to the full entity, which HTTP allows.
        case unsupported
        case unsatisfiable
        case satisfiable(ClosedRange<Int>)
    }

    static func parseRange(_ value: String, fileSize: Int) -> RangeResolution {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("bytes="), fileSize > 0 else { return .unsupported }
        let spec = trimmed.dropFirst("bytes=".count).trimmingCharacters(in: .whitespaces)
        guard !spec.contains(",") else { return .unsupported }

        let parts = spec.split(separator: "-", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard parts.count == 2 else { return .unsupported }

        if parts[0].isEmpty {
            // A suffix range asks for the final N bytes.
            guard let suffixLength = Int(parts[1]), suffixLength > 0 else { return .unsatisfiable }
            let start = max(0, fileSize - suffixLength)
            return .satisfiable(start...(fileSize - 1))
        }

        guard let start = Int(parts[0]), start >= 0 else { return .unsupported }
        guard start < fileSize else { return .unsatisfiable }
        guard !parts[1].isEmpty else { return .satisfiable(start...(fileSize - 1)) }
        guard let end = Int(parts[1]), end >= start else { return .unsatisfiable }
        return .satisfiable(start...min(end, fileSize - 1))
    }
}
