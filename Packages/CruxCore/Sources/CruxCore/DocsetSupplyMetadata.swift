import Foundation

/// Claims inside meta.json. These are not proof of origin or ownership of an
/// installation slot; the installer must compare them with a verified target.
public struct DocsetSupplyMetadata: Codable, Equatable, Hashable, Sendable {
    public let sourceId: String
    public let familyId: String
    public let variantId: String
    public let versionLine: String
    public let language: String
    public let identifier: String
    public let bundleName: String
    public let releaseId: String

    func validate() throws {
        guard ReleaseValidation.matches(sourceId, "[a-z0-9]+(?:[.-][a-z0-9]+)*"),
              ReleaseValidation.matches(familyId, "[a-z0-9]+(?:-[a-z0-9]+)*"),
              ReleaseValidation.matches(variantId, "[a-z0-9]+(?:-[a-z0-9]+)*"),
              variantId.hasPrefix(familyId + "-"),
              ReleaseValidation.stableVersion(versionLine), language == "en",
              ReleaseValidation.matches(identifier, "[A-Za-z0-9]+(?:[._-][A-Za-z0-9]+)*"),
              ReleaseValidation.matches(bundleName, "[A-Za-z0-9_-]+"),
              ReleaseValidation.matches(releaseId, "[0-9a-f]{64}"),
              [sourceId, familyId, variantId, identifier, bundleName].allSatisfy(ReleaseValidation.boundedText) else {
            throw CatalogError.invalidResponse
        }
    }
}
