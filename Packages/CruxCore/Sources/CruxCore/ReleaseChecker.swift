import Foundation

public struct AvailableRelease: Equatable, Sendable {
    public let version: String
    public let pageURL: URL

    public init(version: String, pageURL: URL) {
        self.version = version
        self.pageURL = pageURL
    }
}

/// Checks GitHub's release metadata without downloading or replacing the app.
///
/// Crux v1 deliberately stops at a user-visible link. Installation remains a
/// normal macOS download, so there is no hidden privileged updater surface.
public actor GitHubReleaseChecker {
    public static let releasesPage = URL(string: "https://github.com/zacharyhuo/Crux/releases")!

    private let endpoint: URL
    private let httpClient: any HTTPClient

    public init(
        endpoint: URL = URL(string: "https://api.github.com/repos/zacharyhuo/Crux/releases/latest")!,
        httpClient: any HTTPClient = URLSessionHTTPClient()
    ) {
        self.endpoint = endpoint
        self.httpClient = httpClient
    }

    public func newerRelease(than currentVersion: String) async throws -> AvailableRelease? {
        guard endpoint.scheme?.lowercased() == "https" else { return nil }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Crux", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await httpClient.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return nil
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard !payload.draft,
              !payload.prerelease,
              payload.htmlURL.scheme?.lowercased() == "https",
              let latest = ReleaseVersion(payload.tagName),
              let current = ReleaseVersion(currentVersion),
              latest > current else {
            return nil
        }
        return AvailableRelease(version: latest.description, pageURL: payload.htmlURL)
    }

    private struct Payload: Decodable {
        let tagName: String
        let htmlURL: URL
        let draft: Bool
        let prerelease: Bool

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case draft
            case prerelease
        }
    }
}

private struct ReleaseVersion: Comparable, CustomStringConvertible {
    let components: [Int]

    init?(_ rawValue: String) {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingPrefix("v")
        let parts = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else {
            return nil
        }
        components = parts.compactMap { Int($0) }
    }

    var description: String { components.map(String.init).joined(separator: ".") }

    static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }
}
