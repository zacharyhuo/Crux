import CruxCore
import Foundation

struct SourceDocsetGroup<Item>: Identifiable {
    let id: UUID
    let name: String
    let items: [Item]
}

enum SourcePresentation {
    static func distinctOriginName(_ name: String, id: UUID, collidingIDs: Set<UUID>, deleted: Bool) -> String {
        guard collidingIDs.count > 1 else { return name }
        let suffixes = Set(collidingIDs.map { String($0.uuidString.suffix(8)).lowercased() })
        let identity = suffixes.count == collidingIDs.count
            ? String(id.uuidString.suffix(8)).lowercased() : id.uuidString.lowercased()
        let state = deleted ? " · \(String(localized: "library.sources.origin.removed"))" : ""
        return "\(name)\(state) · \(identity)"
    }
    static func title(_ title: String, sourceName: String, enabledSourceCount: Int) -> String {
        enabledSourceCount > 1 ? "\(title)（\(sourceName)）" : title
    }

    static func accessibilityID(_ action: String, sourceID: UUID) -> String {
        "\(action)-\(sourceID.uuidString.lowercased())"
    }

    static func availableGroups(sources: [DocsetSourceConfiguration], entries: [SourcedCatalogEntry]) -> [SourceDocsetGroup<SourcedCatalogEntry>] {
        let grouped = Dictionary(grouping: entries, by: \.sourceConfigurationID)
        return sources.filter(\.canFetch).map {
            SourceDocsetGroup(id: $0.id, name: $0.name, items: grouped[$0.id] ?? [])
        }
    }

    static func installedGroups(_ records: [InstalledDocset], sources: [DocsetSourceConfiguration],
                                sourceName: (InstalledDocset) -> String) -> [SourceDocsetGroup<InstalledDocset>] {
        let grouped = Dictionary(grouping: records, by: originID)
        let order = Dictionary(uniqueKeysWithValues: sources.enumerated().map { ($0.element.id, $0.offset) })
        return grouped.compactMap { id, items in
            items.first.map { SourceDocsetGroup(id: id, name: sourceName($0), items: items) }
        }.sorted {
            let first = order[$0.id] ?? Int.max, second = order[$1.id] ?? Int.max
            if first != second { return first < second }
            if $0.name != $1.name { return $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    static func originID(_ record: InstalledDocset) -> UUID {
        if let id = record.sourceConfigurationID ?? record.installTarget?.sourceConfigurationID { return id }
        if case .localImport = record.source { return DocsetSourceConfiguration.localID }
        return DocsetSourceConfiguration.legacyID
    }

    static func showsInstalledSections(enabledSourceCount: Int, groupCount: Int) -> Bool {
        enabledSourceCount > 1 || groupCount > 1
    }
    static func canDelete(_ source: DocsetSourceConfiguration) -> Bool { !source.isBuiltIn && !source.isDeleted }

    static func kindKey(_ source: DocsetSourceConfiguration) -> String {
        switch source.kind {
        case .zeal: "library.sources.type.zeal"
        case .versioned: "library.sources.type.versioned"
        case .feed: "library.sources.type.feed"
        case .unavailable: "library.sources.type.unavailable"
        }
    }
}

enum SourceDraftError: Error { case invalidName, invalidURL }

struct SourceDraft: Identifiable {
    enum Kind: String, CaseIterable { case zeal, feed }
    let id: UUID
    let original: DocsetSourceConfiguration?
    var name = ""
    var kind: Kind = .zeal
    var catalogURL = ""
    var downloadRootURL = ""
    var isEnabled = true
    var allowsLocalHTTP = false

    init() { id = UUID(); original = nil }
    init(editing source: DocsetSourceConfiguration) {
        id = source.id; original = source
        name = source.name; isEnabled = source.isEnabled
        allowsLocalHTTP = source.transportPolicy == .localHTTP
        catalogURL = source.endpointURL?.absoluteString ?? ""
        switch source.kind {
        case let .zeal(_, root): downloadRootURL = root.absoluteString
        case .feed: kind = .feed
        case .versioned, .unavailable: break
        }
    }

    /// Edits can change only the name and enabled state; endpoint identity is immutable.
    func configuration() throws -> DocsetSourceConfiguration {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 120, !trimmed.contains(where: \.isNewline) else {
            throw SourceDraftError.invalidName
        }
        if var original {
            original.name = trimmed
            original.isEnabled = isEnabled
            try original.validate()
            return original
        }
        let endpoint = try url(catalogURL)
        let sourceKind: DocsetSourceConfiguration.Kind = switch kind {
        case .feed: .feed(url: endpoint)
        case .zeal: .zeal(catalogURL: endpoint, downloadRootURL: try url(downloadRootURL))
        }
        let config = DocsetSourceConfiguration(id: id, name: trimmed, kind: sourceKind, isEnabled: isEnabled,
                                               transportPolicy: allowsLocalHTTP ? .localHTTP : .strictHTTPS)
        try config.validate()
        return config
    }

    private func url(_ value: String) throws -> URL {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, let url = URL(string: value) else { throw SourceDraftError.invalidURL }
        return url
    }

    var validationKey: String? {
        do { _ = try configuration(); return nil }
        catch SourceDraftError.invalidName { return "library.sources.validation.name" }
        catch SourceDraftError.invalidURL { return "library.sources.validation.url" }
        catch SourceTransportError.httpsRequired { return "library.sources.validation.https" }
        catch SourceTransportError.localHTTPRequired { return "library.sources.validation.local" }
        catch SourceTransportError.credentialsNotAllowed { return "library.sources.validation.credentials" }
        catch SourceTransportError.invalidURL { return "library.sources.validation.url" }
        catch { return "library.sources.validation.configuration" }
    }
}
