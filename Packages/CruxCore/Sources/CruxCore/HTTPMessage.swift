import Foundation

/// A parsed request head from the loopback document server.
///
/// Only the pieces Crux actually needs are modelled. Everything else in the
/// head is ignored so that unusual but harmless client behaviour cannot change
/// how a document is resolved.
public struct HTTPRequestHead: Equatable, Sendable {
    public let method: String
    public let target: String
    public let version: String
    /// Header names are lowercased because HTTP field names are case-insensitive.
    public let headers: [String: String]

    public init(method: String, target: String, version: String, headers: [String: String]) {
        self.method = method
        self.target = target
        self.version = version
        self.headers = headers
    }

    public var wantsKeepAlive: Bool {
        let connection = headers["connection"]?.lowercased()
        if version == "HTTP/1.0" {
            return connection == "keep-alive"
        }
        return connection != "close"
    }
}

public enum HTTPRequestParseError: Error, Equatable, Sendable {
    /// The buffer does not yet contain a complete head; the caller should read more bytes.
    case incomplete
    case malformed
    /// The head exceeded the size Crux is willing to buffer for a local request.
    case headTooLarge
}

public enum HTTPRequestParser {
    /// The largest request head Crux buffers. Real docset requests are far below
    /// this, so a larger head means a broken or hostile client.
    public static let maximumHeadSize = 16 * 1024

    private static let terminator = Data("\r\n\r\n".utf8)

    /// Parses one request head and reports how many bytes it consumed.
    public static func parse(_ buffer: Data) throws -> (head: HTTPRequestHead, consumed: Int) {
        guard let terminatorRange = buffer.firstRange(of: terminator) else {
            if buffer.count > maximumHeadSize { throw HTTPRequestParseError.headTooLarge }
            throw HTTPRequestParseError.incomplete
        }

        let headEnd = terminatorRange.lowerBound
        let consumed = buffer.distance(from: buffer.startIndex, to: terminatorRange.upperBound)
        guard consumed <= maximumHeadSize else { throw HTTPRequestParseError.headTooLarge }
        guard let text = String(data: buffer[buffer.startIndex..<headEnd], encoding: .utf8) else {
            throw HTTPRequestParseError.malformed
        }

        var lines = text.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { throw HTTPRequestParseError.malformed }
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count == 3 else { throw HTTPRequestParseError.malformed }

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let separator = line.firstIndex(of: ":") else { throw HTTPRequestParseError.malformed }
            let name = line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { throw HTTPRequestParseError.malformed }
            // Repeated headers are joined the way HTTP defines list folding.
            headers[name] = headers[name].map { "\($0), \(value)" } ?? value
        }

        let head = HTTPRequestHead(
            method: String(requestLine[0]),
            target: String(requestLine[1]),
            version: String(requestLine[2]),
            headers: headers
        )
        return (head, consumed)
    }
}

public enum HTTPStatus: Int, Sendable {
    case ok = 200
    case partialContent = 206
    case badRequest = 400
    case notFound = 404
    case methodNotAllowed = 405
    case rangeNotSatisfiable = 416
    case internalServerError = 500

    public var reasonPhrase: String {
        switch self {
        case .ok: "OK"
        case .partialContent: "Partial Content"
        case .badRequest: "Bad Request"
        case .notFound: "Not Found"
        case .methodNotAllowed: "Method Not Allowed"
        case .rangeNotSatisfiable: "Range Not Satisfiable"
        case .internalServerError: "Internal Server Error"
        }
    }
}

/// A response the router resolved but has not read from disk yet.
///
/// Keeping the body as a description instead of bytes lets the server stream
/// large files and lets tests assert on routing decisions without any IO.
public struct HTTPResponseHead: Equatable, Sendable {
    public enum Body: Equatable, Sendable {
        case empty
        case text(String)
        /// A byte range of a file that the router already proved is in bounds.
        case file(url: URL, range: ClosedRange<Int>)
    }

    public let status: HTTPStatus
    public let headers: [String: String]
    public let body: Body

    public init(status: HTTPStatus, headers: [String: String] = [:], body: Body = .empty) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public var contentLength: Int {
        switch body {
        case .empty: 0
        case let .text(text): text.utf8.count
        case let .file(_, range): range.count
        }
    }

    /// Serializes the status line and headers, including the framing headers the
    /// server always controls.
    ///
    /// `Content-Length` always describes the entity, even for `HEAD`, so that a
    /// client can size a later `GET` from the same metadata.
    public func serializedHead() -> Data {
        var lines = ["HTTP/1.1 \(status.rawValue) \(status.reasonPhrase)"]
        var allHeaders = headers
        allHeaders["Content-Length"] = String(contentLength)
        if allHeaders["Content-Type"] == nil, case .text = body {
            allHeaders["Content-Type"] = "text/plain; charset=utf-8"
        }
        for name in allHeaders.keys.sorted() {
            lines.append("\(name): \(allHeaders[name]!)")
        }
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }
}
