import Foundation

/// An immutable, selectable artifact advertised by a trusted versioned catalog.
public struct DocsetRelease: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let releaseId: String
    public let variantId: String
    public let versionLine: String
    public let language: String
    public let version: String
    public let revision: Int
    public let identifier: String
    public let artifact: DocsetReleaseArtifact
    public let publishedAt: String
    public let channel: String
    public let support: String

    public var id: String { releaseId }
    public var downloadURL: URL { artifact.url }
    public var sha256: String { artifact.sha256 }
    public var bytes: Int64 { artifact.bytes }
    public var advertisedVersion: DocsetVersion { DocsetVersion(version: version, revision: revision) }

    func validate(family: DocsetReleaseFamily) throws {
        let date = ISO8601DateFormatter()
        date.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard ReleaseValidation.matches(releaseId, "[0-9a-f]{64}"),
              ReleaseValidation.matches(variantId, "[a-z0-9]+(?:-[a-z0-9]+)*"),
              variantId.hasPrefix(family.familyId + "-"), variantId.count <= 200,
              language == "en", identifier == family.identifier,
              ReleaseValidation.stableVersion(version), ReleaseValidation.stableVersion(versionLine),
              version == versionLine || version.hasPrefix(versionLine + "."),
              revision > 0, revision <= 9_007_199_254_740_991,
              channel == "stable", ["supported", "archived"].contains(support),
              let published = date.date(from: publishedAt), date.string(from: published) == publishedAt else {
            throw CatalogError.invalidResponse
        }
    }
}

public struct DocsetReleaseArtifact: Codable, Equatable, Hashable, Sendable {
    public let url: URL
    public let sha256: String
    public let bytes: Int64

    private enum CodingKeys: String, CodingKey { case url, sha256, bytes }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawURL = try container.decode(String.self, forKey: .url)
        let hash = try container.decode(String.self, forKey: .sha256)
        let size = try container.decode(Int64.self, forKey: .bytes)
        guard rawURL.utf8.count <= 4096, let url = URL(string: rawURL),
              url.absoluteString == rawURL, url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              ReleaseValidation.matches(hash, "[0-9a-f]{64}"), size > 0, size <= 9_007_199_254_740_991 else {
            throw CatalogError.invalidResponse
        }
        self.url = url
        sha256 = hash
        bytes = size
    }
}

/// Family identity is stable across releases; it does not imply multiple installs.
public struct DocsetReleaseFamily: Codable, Equatable, Hashable, Sendable {
    public let sourceId: String
    public let familyId: String
    public let title: String
    public let identifier: String
    public let bundleName: String
    public let defaultVariantId: String
    public let latestReleaseId: String
    public let releases: [DocsetRelease]

    func validate() throws {
        guard ReleaseValidation.matches(sourceId, "[a-z0-9]+(?:[.-][a-z0-9]+)*"),
              ReleaseValidation.matches(familyId, "[a-z0-9]+(?:-[a-z0-9]+)*"),
              ReleaseValidation.matches(identifier, "[A-Za-z0-9]+(?:[._-][A-Za-z0-9]+)*"),
              ReleaseValidation.matches(bundleName, "[A-Za-z0-9_-]+"),
              [sourceId, familyId, title, identifier, bundleName].allSatisfy(ReleaseValidation.boundedText),
              !releases.isEmpty, releases.count <= 10_000 else { throw CatalogError.invalidResponse }
        var identities = Set<String>(), revisions = Set<String>()
        for release in releases {
            try release.validate(family: self)
            guard identities.insert(release.id).inserted,
                  revisions.insert("\(release.variantId)/\(release.version)/\(release.revision)").inserted else {
                throw CatalogError.invalidResponse
            }
        }
        guard let latest = releases.first(where: { $0.id == latestReleaseId }),
              latest.variantId == defaultVariantId, latest.support == "supported" else {
            throw CatalogError.invalidResponse
        }
    }
}

enum ReleaseValidation {
    static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: "\\A(?:\(pattern))\\z", options: .regularExpression) != nil
    }

    static func boundedText(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.count <= 200 && !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
    }

    static func stableVersion(_ value: String) -> Bool {
        matches(value, "(?:0|[1-9][0-9]*)(?:\\.(?:0|[1-9][0-9]*)){0,3}")
            && value.split(separator: ".").allSatisfy { Int64($0).map { $0 <= 9_007_199_254_740_991 } ?? false }
    }
}
