import Foundation

struct VersionedCatalog: Decodable {
    let schemaVersion: Int
    let families: [DocsetReleaseFamily]

    static func parse(_ data: Data, trustedSourceId: String) throws -> [CatalogEntry] {
        do {
            guard data.count <= 8 * 1024 * 1024,
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CatalogError.invalidResponse
            }
            try checkKeys(object, allowed: ["schemaVersion", "families"])
            guard let rawFamilies = object["families"] as? [[String: Any]] else { throw CatalogError.invalidResponse }
            for family in rawFamilies {
                try checkKeys(family, allowed: ["sourceId", "familyId", "title", "identifier", "bundleName", "defaultVariantId", "latestReleaseId", "releases"])
                guard let releases = family["releases"] as? [[String: Any]] else { throw CatalogError.invalidResponse }
                for release in releases {
                    // In particular, never silently ignore a withdrawn/status field.
                    try checkKeys(release, allowed: ["releaseId", "variantId", "versionLine", "language", "version", "revision", "identifier", "artifact", "publishedAt", "channel", "support"])
                    guard let artifact = release["artifact"] as? [String: Any] else { throw CatalogError.invalidResponse }
                    try checkKeys(artifact, allowed: ["url", "sha256", "bytes"])
                }
            }
            let catalog = try JSONDecoder().decode(Self.self, from: data)
            guard catalog.schemaVersion == 1 else { throw CatalogError.invalidResponse }
            var families = Set<String>(), identifiers = Set<String>(), releaseIds = Set<String>()
            return try catalog.families.map { family in
                try family.validate()
                guard family.sourceId == trustedSourceId,
                      families.insert(family.familyId).inserted,
                      identifiers.insert(family.identifier).inserted,
                      family.releases.allSatisfy({ releaseIds.insert($0.id).inserted }),
                      let latest = family.releases.first(where: { $0.id == family.latestReleaseId }) else {
                    throw CatalogError.invalidResponse
                }
                return CatalogEntry(name: family.familyId, title: family.title, sourceId: family.sourceId,
                                    version: latest.version, revision: latest.revision, downloadURL: latest.downloadURL,
                                    keywords: [family.familyId], releaseFamily: family)
            }
        } catch { throw CatalogError.invalidResponse }
    }

    private static func checkKeys(_ object: [String: Any], allowed: Set<String>) throws {
        guard Set(object.keys) == allowed else { throw CatalogError.invalidResponse }
    }
}
