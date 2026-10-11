import Foundation

/// A normalized query that can be executed across installed docsets.
public struct SearchQuery: Equatable, Sendable {
    public let rawValue: String
    public let term: String
    public let docsetFilters: [String]
    public let symbolTypeFilters: [String]

    public var isFiltered: Bool {
        !docsetFilters.isEmpty || !symbolTypeFilters.isEmpty
    }

    public static func parse(
        _ rawValue: String,
        knownDocsetFilters: Set<String>,
        knownSymbolTypes: Set<String>
    ) -> SearchQuery {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedDocsets = Set(knownDocsetFilters.map(normalize))
        let normalizedTypes = Set(knownSymbolTypes.map(normalize))

        guard let separator = trimmed.firstIndex(of: ":"), separator != trimmed.startIndex else {
            return plain(rawValue: rawValue, term: trimmed)
        }

        let prefix = trimmed[..<separator]
        let tokens = prefix.split(separator: ",", omittingEmptySubsequences: false)
            .map { normalize(String($0)) }

        guard !tokens.isEmpty, tokens.allSatisfy({ !$0.isEmpty }) else {
            return plain(rawValue: rawValue, term: trimmed)
        }

        var docsetFilters: [String] = []
        var symbolTypeFilters: [String] = []

        for token in tokens {
            if normalizedDocsets.contains(token) {
                appendUnique(token, to: &docsetFilters)
            } else if normalizedTypes.contains(token) {
                appendUnique(token, to: &symbolTypeFilters)
            } else {
                // A colon is meaningful only when every prefix token resolves.
                // This keeps language symbols such as `std::string` intact.
                return plain(rawValue: rawValue, term: trimmed)
            }
        }

        let termStart = trimmed.index(after: separator)
        let term = trimmed[termStart...].trimmingCharacters(in: .whitespacesAndNewlines)
        return SearchQuery(
            rawValue: rawValue,
            term: term,
            docsetFilters: docsetFilters,
            symbolTypeFilters: symbolTypeFilters
        )
    }

    private static func plain(rawValue: String, term: String) -> SearchQuery {
        SearchQuery(rawValue: rawValue, term: term, docsetFilters: [], symbolTypeFilters: [])
    }

    private static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func appendUnique(_ value: String, to values: inout [String]) {
        if !values.contains(value) {
            values.append(value)
        }
    }
}
