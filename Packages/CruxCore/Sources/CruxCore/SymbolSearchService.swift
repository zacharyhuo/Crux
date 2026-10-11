import Foundation

public protocol SearchService: Sendable {
    func search(
        _ rawQuery: String,
        in docsets: [DocsetDescriptor],
        limit: Int
    ) async throws -> [SymbolSearchResult]
}

/// Coordinates read-only searches across all selected docset indexes.
public actor SymbolSearchService: SearchService {
    private var indexes: [String: DocsetSymbolIndex] = [:]
    private var symbolTypesByIndexKey: [String: Set<String>] = [:]

    public init() {}

    public func search(
        _ rawQuery: String,
        in docsets: [DocsetDescriptor],
        limit: Int = 1_000
    ) async throws -> [SymbolSearchResult] {
        guard limit > 0, !docsets.isEmpty else { return [] }
        try Task.checkCancellation()

        let availableIndexes = try docsets.map { try index(for: $0) }
        let knownTypes = try await collectSymbolTypes(from: availableIndexes)
        let knownDocsetFilters = Set(docsets.flatMap(\.searchFilters))
        let query = SearchQuery.parse(
            rawQuery,
            knownDocsetFilters: knownDocsetFilters,
            knownSymbolTypes: knownTypes
        )

        let selectedIndexes: [DocsetSymbolIndex]
        if query.docsetFilters.isEmpty {
            selectedIndexes = availableIndexes
        } else {
            selectedIndexes = availableIndexes.filter { index in
                !index.descriptor.searchFilters.isDisjoint(with: query.docsetFilters)
            }
        }

        var allResults = try await withThrowingTaskGroup(
            of: [SymbolSearchResult].self,
            returning: [SymbolSearchResult].self
        ) { group in
            for index in selectedIndexes {
                group.addTask {
                    try await index.search(query: query, limit: limit)
                }
            }

            var merged: [SymbolSearchResult] = []
            for try await partialResults in group {
                merged.append(contentsOf: partialResults)
            }
            return merged
        }
        try Task.checkCancellation()
        allResults.sort(by: Self.resultPrecedes)
        return Array(allResults.prefix(limit))
    }

    public func symbolTypeSummaries(in docset: DocsetDescriptor) async throws -> [SymbolTypeSummary] {
        try await index(for: docset).symbolTypeSummaries()
    }

    private func index(for descriptor: DocsetDescriptor) throws -> DocsetSymbolIndex {
        let cacheKey = [
            descriptor.identifier,
            descriptor.indexURL.path,
            descriptor.version ?? "",
            descriptor.revision.map(String.init) ?? "",
        ].joined(separator: "\u{0}")
        if let existing = indexes[cacheKey] {
            return existing
        }

        let staleKeys = indexes.compactMap { key, index in
            index.descriptor.identifier == descriptor.identifier ? key : nil
        }
        for staleKey in staleKeys {
            indexes.removeValue(forKey: staleKey)
            symbolTypesByIndexKey.removeValue(forKey: staleKey)
        }

        let created = try DocsetSymbolIndex(descriptor: descriptor)
        indexes[cacheKey] = created
        return created
    }

    private func collectSymbolTypes(from indexes: [DocsetSymbolIndex]) async throws -> Set<String> {
        var types: Set<String> = [
            "attribute", "category", "class", "constant", "constructor", "enumeration",
            "event", "field", "function", "guide", "method", "module", "namespace",
            "property", "protocol", "structure", "type", "variable",
        ]
        try await withThrowingTaskGroup(of: (String, Set<String>).self) { group in
            for index in indexes {
                if let cachedTypes = symbolTypesByIndexKey[index.cacheKey] {
                    types.formUnion(cachedTypes)
                    continue
                }
                group.addTask { (index.cacheKey, try await index.symbolTypes()) }
            }
            for try await (cacheKey, indexTypes) in group {
                symbolTypesByIndexKey[cacheKey] = indexTypes
                types.formUnion(indexTypes)
            }
        }
        return types
    }

    private static func resultPrecedes(_ lhs: SymbolSearchResult, _ rhs: SymbolSearchResult) -> Bool {
        if lhs.matchKind.rawValue != rhs.matchKind.rawValue {
            return lhs.matchKind.rawValue < rhs.matchKind.rawValue
        }

        if lhs.matchKind == .browse {
            return alphabeticalResultPrecedes(lhs, rhs)
        }

        let lhsGap = fuzzyGap(in: lhs)
        let rhsGap = fuzzyGap(in: rhs)
        if lhsGap != rhsGap { return lhsGap < rhsGap }
        if lhs.name.count != rhs.name.count { return lhs.name.count < rhs.name.count }

        let lhsName = lhs.name.lowercased()
        let rhsName = rhs.name.lowercased()
        if lhsName != rhsName { return lhsName < rhsName }
        if lhs.name != rhs.name { return lhs.name < rhs.name }

        let lhsDocset = lhs.docsetName.lowercased()
        let rhsDocset = rhs.docsetName.lowercased()
        if lhsDocset != rhsDocset { return lhsDocset < rhsDocset }
        if lhs.type != rhs.type { return lhs.type < rhs.type }
        return lhs.relativePath < rhs.relativePath
    }

    private static func alphabeticalResultPrecedes(_ lhs: SymbolSearchResult, _ rhs: SymbolSearchResult) -> Bool {
        let lhsName = lhs.name.lowercased()
        let rhsName = rhs.name.lowercased()
        if lhsName != rhsName { return lhsName < rhsName }
        if lhs.name != rhs.name { return lhs.name < rhs.name }
        let lhsDocset = lhs.docsetName.lowercased()
        let rhsDocset = rhs.docsetName.lowercased()
        if lhsDocset != rhsDocset { return lhsDocset < rhsDocset }
        if lhs.type != rhs.type { return lhs.type < rhs.type }
        return lhs.relativePath < rhs.relativePath
    }

    private static func fuzzyGap(in result: SymbolSearchResult) -> Int {
        guard let first = result.matchPositions.first, let last = result.matchPositions.last else { return 0 }
        return (last - first + 1) - result.matchPositions.count
    }
}
