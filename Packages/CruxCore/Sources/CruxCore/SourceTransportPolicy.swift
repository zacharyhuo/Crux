import Darwin
import Foundation

/// Transport permission belonging to a single configured source or transfer.
public enum SourceTransportPolicy: String, Codable, Equatable, Hashable, Sendable {
    case strictHTTPS
    case localHTTP

    public func validate(_ url: URL) throws {
        guard url.user == nil, url.password == nil else {
            throw SourceTransportError.credentialsNotAllowed
        }
        guard url.baseURL == nil,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.percentEncodedHost, !host.isEmpty,
              !host.contains("%"),
              Self.isValidHost(host),
              components.port.map({ (1...65_535).contains($0) }) ?? true else {
            throw SourceTransportError.invalidURL
        }
        let scheme = components.scheme?.lowercased()
        guard scheme == "https" || scheme == "http" else {
            throw SourceTransportError.invalidURL
        }
        let authority = url.absoluteString.dropFirst((components.scheme?.count ?? 0) + 3)
            .prefix(while: { $0 != "/" && $0 != "?" && $0 != "#" })
        guard !authority.hasSuffix(":") else { throw SourceTransportError.invalidURL }
        if scheme == "https" { return }
        guard self == .localHTTP else {
            throw SourceTransportError.httpsRequired
        }
        guard Self.isLocalHost(host) else { throw SourceTransportError.localHTTPRequired }
    }

    public func validateRedirect(from originalURL: URL, to destinationURL: URL) throws {
        try validate(originalURL)
        guard originalURL.scheme?.lowercased() != "https" || destinationURL.scheme?.lowercased() != "http" else {
            throw SourceTransportError.httpsDowngrade
        }
        try validate(destinationURL)
    }

    private static func isLocalHost(_ host: String) -> Bool {
        if host.lowercased() == "localhost" { return true }
        if let bytes = ipv4Bytes(host) { return isLocalIPv4(bytes) }
        guard let bytes = ipv6Bytes(host) else { return false }
        if bytes.prefix(15).allSatisfy({ $0 == 0 }), bytes[15] == 1 { return true }
        if bytes[0] & 0xfe == 0xfc { return true } // fc00::/7 (ULA)
        if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff {
            return isLocalIPv4(Array(bytes.suffix(4)))
        }
        return false
    }

    private static func isValidHost(_ host: String) -> Bool {
        if ipv4Bytes(host) != nil || ipv6Bytes(host) != nil { return true }
        let dns = host.hasSuffix(".") ? String(host.dropLast()) : host
        let labels = dns.split(separator: ".", omittingEmptySubsequences: false)
        guard dns.utf8.count <= 253, let last = labels.last, !last.isEmpty else { return false }
        // Numeric final labels may be interpreted as legacy IPv4 by URLSession's resolver.
        if last.utf8.allSatisfy({ (48...57).contains($0) }) { return false }
        if last.lowercased().hasPrefix("0x"), last.dropFirst(2).allSatisfy(\.isHexDigit) { return false }
        return labels.allSatisfy { label in
            !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-"
                && label.utf8.allSatisfy { byte in
                    (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || byte == 45
                }
        }
    }

    private static func ipv6Bytes(_ host: String) -> [UInt8]? {
        guard host.hasPrefix("["), host.hasSuffix("]") else { return nil }
        let literal = String(host.dropFirst().dropLast())
        // inet_pton parses IPv6, never resolves DNS or accepts legacy numeric IPv4 syntax.
        if literal.contains("."), ipv4Bytes(String(literal.split(separator: ":").last ?? "")) == nil {
            return nil
        }
        var address = in6_addr()
        guard literal.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else { return nil }
        return withUnsafeBytes(of: address) { Array($0) }
    }

    private static func ipv4Bytes(_ host: String) -> [UInt8]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var bytes: [UInt8] = []
        for part in parts {
            guard !part.isEmpty, part.utf8.allSatisfy({ (48...57).contains($0) }),
                  let value = UInt8(part), String(value) == part else { return nil }
            bytes.append(value)
        }
        return bytes
    }

    private static func isLocalIPv4(_ bytes: [UInt8]) -> Bool {
        bytes[0] == 127 || bytes[0] == 10
            || (bytes[0] == 172 && (16...31).contains(bytes[1]))
            || (bytes[0] == 192 && bytes[1] == 168)
    }
}

/// Deliberately excludes the URL so rejected embedded credentials cannot appear in diagnostics.
public enum SourceTransportError: Error, Equatable, LocalizedError, Sendable {
    case invalidURL
    case credentialsNotAllowed
    case httpsRequired
    case localHTTPRequired
    case httpsDowngrade

    public var errorDescription: String? {
        switch self {
        case .invalidURL: "The source URL is not a valid absolute HTTP or HTTPS address."
        case .credentialsNotAllowed: "Source URLs must not contain a username or password."
        case .httpsRequired: "This source requires HTTPS."
        case .localHTTPRequired: "HTTP requires localhost or an explicit private or loopback IP address."
        case .httpsDowngrade: "An HTTPS request cannot redirect to HTTP."
        }
    }
}
