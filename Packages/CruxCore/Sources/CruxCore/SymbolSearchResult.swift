import Foundation

public struct SearchResult: Equatable, Hashable, Sendable {
    public let name: String
    public let type: String
    public let relativePath: String
    public let fragment: String?
    public let documentURL: URL
    public let docsetIdentifier: String
    public let docsetName: String
    /// A class/container name when the index provides one, otherwise a stable
    /// document-path context such as `webstreams` or `globals`.
    public let contextName: String?
    public let matchKind: SymbolMatchKind
    public let matchPositions: [Int]
}

/// A normalized symbol category and the number of entries it contains.
public struct SymbolTypeSummary: Equatable, Hashable, Sendable {
    public let type: String
    public let count: Int

    public init(type: String, count: Int) {
        self.type = type
        self.count = count
    }
}

/// Clarifies that the current v1 result source is the docset symbol index.
public typealias SymbolSearchResult = SearchResult

/// Stable identity for Dash-style "similar results" expansion.
///
/// The docset and type deliberately participate in the key. A method and a
/// class with the same spelling are different documentation concepts, as are
/// equal names supplied by two independently installed docsets.
public struct SymbolSearchGroupKey: Equatable, Hashable, Sendable {
    public let docsetIdentifier: String
    public let normalizedType: String
    public let normalizedName: String

    public init(docsetIdentifier: String, normalizedType: String, normalizedName: String) {
        self.docsetIdentifier = docsetIdentifier
        self.normalizedType = normalizedType
        self.normalizedName = normalizedName
    }
}

public struct SymbolSearchResultGroup: Equatable, Hashable, Identifiable, Sendable {
    public let key: SymbolSearchGroupKey
    public let results: [SymbolSearchResult]

    public var id: SymbolSearchGroupKey { key }
    public var representative: SymbolSearchResult { results[0] }
    public var similarResultCount: Int { results.count }
    public var hasSimilarResults: Bool { results.count > 1 }
}

public extension Collection where Element == SymbolSearchResult {
    /// Coalesces only genuinely different destinations while preserving the
    /// service's relevance order for both groups and their nested leaves.
    func nestedResultGroups() -> [SymbolSearchResultGroup] {
        var order: [SymbolSearchGroupKey] = []
        var buckets: [SymbolSearchGroupKey: [SymbolSearchResult]] = [:]
        var locations: [SymbolSearchGroupKey: Set<ResultLocationKey>] = [:]

        for result in self {
            let key = SymbolSearchGroupKey(
                docsetIdentifier: result.docsetIdentifier,
                normalizedType: Self.normalizeGroupComponent(result.type),
                normalizedName: Self.normalizeGroupComponent(result.name)
            )
            if buckets[key] == nil { order.append(key) }

            let location = ResultLocationKey(
                relativePath: result.relativePath,
                fragment: result.fragment
            )
            guard locations[key, default: []].insert(location).inserted else { continue }
            buckets[key, default: []].append(result)
        }

        return order.compactMap { key in
            guard let results = buckets[key], !results.isEmpty else { return nil }
            return SymbolSearchResultGroup(key: key, results: results)
        }
    }

    private static func normalizeGroupComponent(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

private struct ResultLocationKey: Hashable {
    let relativePath: String
    let fragment: String?
}

public enum SymbolMatchKind: Int, Codable, Equatable, Hashable, Sendable {
    case exact
    case prefix
    case substring
    case fuzzy
    case browse
}
