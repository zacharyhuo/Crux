import CruxCore
import Foundation

/// A value snapshot held while the user reviews a replacement. Menu edits do
/// not touch the queue or registry; a refreshed catalog cannot retarget it.
struct DocsetInstallChoice: Identifiable {
    let entry: CatalogEntry
    let policy: DocsetSelectionPolicy
    let installed: InstalledDocset?
    let release: DocsetRelease?
    let sourcedEntry: SourcedCatalogEntry?
    let target: DocsetInstallTarget?
    var sourceConfigurationID: UUID? { sourcedEntry?.sourceConfigurationID }

    var id: String { sourcedEntry?.id ?? entry.id }
    var requiresReplacement: Bool { installed != nil }

    init?(entry: CatalogEntry, policy: DocsetSelectionPolicy, installed: InstalledDocset?, isBusy: Bool) {
        guard !isBusy, let request = try? TransferRequest.catalog(entry, selection: policy) else { return nil }
        if let target = request.target {
            guard installed?.installTarget != target else { return nil }
        } else if installed != nil { return nil }
        self.entry = entry
        self.policy = policy
        self.installed = installed
        release = request.target?.release
        target = request.target
        sourcedEntry = nil
    }

    init?(entry: SourcedCatalogEntry, policy: DocsetSelectionPolicy, installed: InstalledDocset?, isBusy: Bool) {
        guard !isBusy else { return nil }
        let matching = installed.flatMap { record -> InstalledDocset? in
            guard (record.sourceConfigurationID ?? record.installTarget?.sourceConfigurationID) == entry.sourceConfigurationID else { return nil }
            if let family = entry.entry.releaseFamily {
                guard record.installTarget?.sourceId == family.sourceId, record.installTarget?.familyId == family.familyId else { return nil }
            } else {
                switch record.source {
                case let .catalog(name, publisher):
                    guard name == entry.entry.name, publisher == entry.entry.sourceId else { return nil }
                case .feed: break
                case .localImport: return nil
                }
            }
            return record
        }
        guard let request = try? TransferRequest.catalog(entry, selection: policy, replacing: matching) else { return nil }
        if let target = request.target {
            guard matching?.installTarget != target else { return nil }
        } else if matching != nil { return nil }
        self.entry = entry.entry
        self.policy = policy
        self.installed = matching
        release = request.target?.release
        target = request.target
        sourcedEntry = entry
    }

    var summary: String {
        let next = release.map { "\($0.version) · r\($0.revision)" } ?? entry.version ?? "—"
        let title = sourcedEntry.map { "\(entry.title)（\($0.sourceName)）" } ?? entry.title
        guard let installed else { return "\(title): \(next)" }
        let previous = installed.descriptor.version ?? "—"
        return "\(title): \(previous) → \(next)"
    }
}
