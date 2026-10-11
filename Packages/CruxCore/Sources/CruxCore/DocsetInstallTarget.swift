import CryptoKit
import Foundation

/// A frozen download decision, made from an explicitly trusted catalog provider.
/// Never create an installation target from unverified bundle metadata.
public struct DocsetInstallTarget: Codable, Equatable, Sendable {
    public let sourceId: String
    public let familyId: String
    public let bundleName: String
    public let release: DocsetRelease
    public let selectionPolicy: DocsetSelectionPolicy
    public let sourceConfigurationID: UUID?

    public init(entry: CatalogEntry, selection: DocsetSelectionPolicy = .latest, sourceConfigurationID: UUID? = nil) throws {
        release = try entry.resolve(selection)
        guard let family = entry.releaseFamily else { throw CatalogError.versionSelectionUnavailable }
        sourceId = family.sourceId
        familyId = family.familyId
        bundleName = family.bundleName
        selectionPolicy = selection
        self.sourceConfigurationID = sourceConfigurationID
    }

    public var slotKey: String { sourceConfigurationID.map { "\($0.uuidString)/\(sourceId)/\(familyId)" } ?? "\(sourceId)/\(familyId)" }
    func scoped(to source: UUID) -> Self {
        Self(sourceId: sourceId, familyId: familyId, bundleName: bundleName, release: release,
             selectionPolicy: selectionPolicy, sourceConfigurationID: source)
    }
    private init(sourceId: String, familyId: String, bundleName: String, release: DocsetRelease,
                 selectionPolicy: DocsetSelectionPolicy, sourceConfigurationID: UUID?) {
        self.sourceId = sourceId; self.familyId = familyId; self.bundleName = bundleName
        self.release = release; self.selectionPolicy = selectionPolicy; self.sourceConfigurationID = sourceConfigurationID
    }
    var slotFileName: String {
        SHA256.hash(data: Data(slotKey.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    var metadata: DocsetSupplyMetadata {
        DocsetSupplyMetadata(sourceId: sourceId, familyId: familyId, variantId: release.variantId,
                             versionLine: release.versionLine, language: release.language, identifier: release.identifier,
                             bundleName: bundleName, releaseId: release.id)
    }

    func validate() throws {
        try metadata.validate()
        let family = DocsetReleaseFamily(sourceId: sourceId, familyId: familyId, title: bundleName,
                                        identifier: release.identifier, bundleName: bundleName,
                                        defaultVariantId: release.variantId, latestReleaseId: release.id, releases: [release])
        try release.validate(family: family)
        if case let .pinnedRelease(id) = selectionPolicy, id != release.id { throw CatalogError.invalidResponse }
    }

    func validate(_ descriptor: DocsetDescriptor) throws {
        try validate()
        guard descriptor.bundleIdentifier == release.identifier, descriptor.version == release.version,
              descriptor.revision == release.revision, descriptor.supplyMetadata == metadata else {
            throw DocsetReplacementError.targetMismatch
        }
    }
}

public enum DocsetReplacementError: Error, Equatable, LocalizedError, Sendable {
    case targetMismatch
    case conflictingInstall
    case slotBusy
    case artifactMismatch
    case unsafeState
    case recoveryRequired

    public var errorDescription: String? {
        switch self {
        case .targetMismatch: "The downloaded docset does not match the selected release."
        case .conflictingInstall: "An unrelated or changed installation occupies this docset slot."
        case .slotBusy: "This docset already has a version change in progress."
        case .artifactMismatch: "The download size or SHA-256 does not match the selected release."
        case .unsafeState: "The version replacement state is unsafe or unrecognized; no files were removed."
        case .recoveryRequired: "A previous version replacement needs recovery before continuing."
        }
    }
}
