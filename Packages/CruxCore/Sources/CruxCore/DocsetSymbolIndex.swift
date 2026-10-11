import Foundation
import GRDB

/// A read-only connection to one docset-owned symbol database.
final class DocsetSymbolIndex: Sendable {
    let descriptor: DocsetDescriptor
    let cacheKey: String
    private let database: DatabaseQueue

    init(descriptor: DocsetDescriptor) throws {
        self.descriptor = descriptor
        cacheKey = [
            descriptor.identifier,
            descriptor.indexURL.path,
            descriptor.version ?? "",
            descriptor.revision.map(String.init) ?? "",
        ].joined(separator: "\u{0}")
        var configuration = Configuration()
        configuration.readonly = true
        database = try DatabaseQueue(path: descriptor.indexURL.path, configuration: configuration)
    }

    func symbolTypes() async throws -> Set<String> {
        do {
            return try await database.read { [descriptor] db in
                try Task.checkCancellation()
                let sql = switch descriptor.indexSchema {
                case .dash:
                    "SELECT DISTINCT type FROM searchIndex WHERE type IS NOT NULL AND type <> ''"
                case .zDash:
                    "SELECT DISTINCT ztypename FROM ztokentype WHERE ztypename IS NOT NULL AND ztypename <> ''"
                }
                let rawTypes = try String.fetchAll(db, sql: sql)
                return Set(rawTypes.map(SymbolTypeNormalizer.normalize).map { $0.lowercased() })
            }
        } catch where Task.isCancelled {
            throw CancellationError()
        }
    }

    func symbolTypeSummaries() async throws -> [SymbolTypeSummary] {
        do {
            return try await database.read { [descriptor] db in
                try Task.checkCancellation()
                let sql = switch descriptor.indexSchema {
                case .dash:
                    """
                    SELECT type AS raw_type, COUNT(*) AS symbol_count
                      FROM searchIndex
                     WHERE type IS NOT NULL AND trim(type) <> ''
                     GROUP BY type
                    """
                case .zDash:
                    """
                    SELECT tokenType.ztypename AS raw_type, COUNT(*) AS symbol_count
                      FROM ztoken AS token
                      JOIN ztokentype AS tokenType ON token.ztokentype = tokenType.z_pk
                     WHERE tokenType.ztypename IS NOT NULL AND trim(tokenType.ztypename) <> ''
                     GROUP BY tokenType.ztypename
                    """
                }
                let rows = try Row.fetchAll(db, sql: sql)
                var counts: [String: Int] = [:]
                for row in rows {
                    let rawType: String = row["raw_type"]
                    let count: Int = row["symbol_count"]
                    counts[SymbolTypeNormalizer.normalize(rawType), default: 0] += count
                }
                return counts.map(SymbolTypeSummary.init(type:count:)).sorted {
                    $0.type.localizedCaseInsensitiveCompare($1.type) == .orderedAscending
                }
            }
        } catch where Task.isCancelled {
            throw CancellationError()
        }
    }

    func search(query: SearchQuery, limit: Int) async throws -> [SymbolSearchResult] {
        do {
            let candidates = try await fetchCandidates(
                term: query.term,
                symbolTypeFilters: query.symbolTypeFilters,
                limit: limit
            )
            try Task.checkCancellation()
            let results: [SymbolSearchResult] = candidates.compactMap { row -> SymbolSearchResult? in
                guard !Task.isCancelled else { return nil }
                let normalizedType = SymbolTypeNormalizer.normalize(row.type)
                if !query.symbolTypeFilters.isEmpty,
                   !query.symbolTypeFilters.contains(normalizedType.lowercased()) {
                    return nil
                }
                return makeResult(row: row, normalizedType: normalizedType, term: query.term)
            }
            try Task.checkCancellation()
            return results
        } catch where Task.isCancelled {
            throw CancellationError()
        }
    }

    private func fetchCandidates(
        term: String,
        symbolTypeFilters: [String],
        limit: Int
    ) async throws -> [RawSymbol] {
        let candidateLimit = term.isEmpty ? limit : max(1_000, min(limit * 20, 10_000))
        return try await database.read { [descriptor] db in
            try Task.checkCancellation()
            let (selection, typeExpression) = switch descriptor.indexSchema {
            case .dash:
                ("SELECT name, type, path, NULL AS fragment, NULL AS context FROM searchIndex", "type")
            case .zDash:
                try Self.zDashSelection(in: db)
            }

            var conditions: [String] = []
            var arguments = StatementArguments()
            let rawTypeFilters = SymbolTypeNormalizer.rawFilterValues(for: symbolTypeFilters)
            if !rawTypeFilters.isEmpty {
                let placeholders = Array(repeating: "?", count: rawTypeFilters.count).joined(separator: ", ")
                conditions.append("lower(trim(\(typeExpression))) IN (\(placeholders))")
                arguments += StatementArguments(rawTypeFilters)
            }

            if term.isEmpty {
                let whereClause = conditions.isEmpty ? "" : " WHERE " + conditions.joined(separator: " AND ")
                arguments += [candidateLimit]
                return try RawSymbol.fetchAll(
                    db,
                    sql: "\(selection)\(whereClause) ORDER BY name COLLATE NOCASE, type COLLATE NOCASE, path LIMIT ?",
                    arguments: arguments
                )
            }

            let pattern = Self.fuzzyLikePattern(for: term)
            let escapedTerm = Self.escapeLikeLiteral(term)
            conditions.insert("name LIKE ? ESCAPE '\\' COLLATE NOCASE", at: 0)
            arguments = StatementArguments([pattern]) + arguments
            arguments += [term, escapedTerm + "%", "%" + escapedTerm + "%", candidateLimit]
            let whereClause = " WHERE " + conditions.joined(separator: " AND ")
            return try RawSymbol.fetchAll(
                db,
                sql: """
                    \(selection)
                    \(whereClause)
                     ORDER BY CASE
                         WHEN name = ? COLLATE NOCASE THEN 0
                         WHEN name LIKE ? ESCAPE '\\' COLLATE NOCASE THEN 1
                         WHEN name LIKE ? ESCAPE '\\' COLLATE NOCASE THEN 2
                         ELSE 3
                     END,
                     length(name), name COLLATE NOCASE, type COLLATE NOCASE, path
                     LIMIT ?
                    """,
                arguments: arguments
            )
        }
    }

    private func makeResult(row: RawSymbol, normalizedType: String, term: String) -> SymbolSearchResult? {
        let pathAndFragment = Self.splitPathAndFragment(path: row.path, fragment: row.fragment)
        guard let targetURL = Self.safeDocumentURL(
            documentsURL: descriptor.documentsURL,
            relativePath: pathAndFragment.path,
            fragment: pathAndFragment.fragment
        ) else {
            return nil
        }

        let match: SymbolMatch
        if term.isEmpty {
            match = SymbolMatch(kind: .browse, positions: [])
        } else if let computed = SymbolMatcher.match(term: term, candidate: row.name) {
            match = computed
        } else {
            return nil
        }

        return SymbolSearchResult(
            name: row.name,
            type: normalizedType,
            relativePath: pathAndFragment.path,
            fragment: pathAndFragment.fragment,
            documentURL: targetURL,
            docsetIdentifier: descriptor.identifier,
            docsetName: descriptor.name,
            contextName: Self.contextName(explicit: row.context, relativePath: pathAndFragment.path),
            matchKind: match.kind,
            matchPositions: match.positions
        )
    }

    private static func zDashSelection(in db: Database) throws -> (String, String) {
        let hasContainerTable = try db.tableExists("zcontainer")
        let hasContainerColumn = try db.columns(in: "ztoken").contains {
            $0.name.caseInsensitiveCompare("zcontainer") == .orderedSame
        }
        let contextSelection = hasContainerTable && hasContainerColumn
            ? "container.zcontainername AS context"
            : "NULL AS context"
        let contextJoin = hasContainerTable && hasContainerColumn
            ? "LEFT JOIN zcontainer AS container ON token.zcontainer = container.z_pk"
            : ""
        return (
            """
            SELECT token.ztokenname AS name,
                   tokenType.ztypename AS type,
                   file.zpath AS path,
                   metadata.zanchor AS fragment,
                   \(contextSelection)
              FROM ztoken AS token
              JOIN ztokenmetainformation AS metadata
                ON token.zmetainformation = metadata.z_pk
              JOIN zfilepath AS file
                ON metadata.zfile = file.z_pk
              JOIN ztokentype AS tokenType
                ON token.ztokentype = tokenType.z_pk
              \(contextJoin)
            """,
            "tokenType.ztypename"
        )
    }

    private static func contextName(explicit: String?, relativePath: String) -> String? {
        if let explicit = explicit?.trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty {
            return explicit
        }
        guard let component = relativePath.split(separator: "/").last else { return nil }
        let filename = String(component)
        let stem = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
        return stem.removingPercentEncoding?.nilIfEmpty ?? stem.nilIfEmpty
    }

    private static func fuzzyLikePattern(for term: String) -> String {
        let escapedCharacters = term.map { character -> String in
            escapeLikeLiteral(String(character))
        }
        return "%" + escapedCharacters.joined(separator: "%") + "%"
    }

    private static func escapeLikeLiteral(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    private static func splitPathAndFragment(path: String, fragment: String?) -> (path: String, fragment: String?) {
        let cleanedPath = path.replacingOccurrences(
            of: "<dash_entry_[^>]*>",
            with: "",
            options: .regularExpression
        )
        guard fragment == nil, let separator = cleanedPath.firstIndex(of: "#") else {
            return (cleanedPath, cleanedFragment(fragment))
        }
        let next = cleanedPath.index(after: separator)
        return (
            String(cleanedPath[..<separator]),
            cleanedFragment(String(cleanedPath[next...]))
        )
    }

    private static func cleanedFragment(_ fragment: String?) -> String? {
        guard let fragment, !fragment.isEmpty else { return nil }
        return fragment.replacingOccurrences(
            of: "<dash_entry_[^>]*>",
            with: "",
            options: .regularExpression
        )
    }

    private static func safeDocumentURL(
        documentsURL: URL,
        relativePath: String,
        fragment: String?
    ) -> URL? {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              URL(string: relativePath)?.scheme == nil,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            return nil
        }

        let rootURL = documentsURL.resolvingSymlinksInPath().standardizedFileURL
        let fileURL = documentsURL
            .appending(path: relativePath, directoryHint: .notDirectory)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard fileURL.path.hasPrefix(rootURL.path + "/") else { return nil }
        guard let fragment else { return fileURL }

        var urlComponents = URLComponents(url: fileURL, resolvingAgainstBaseURL: false)
        urlComponents?.fragment = fragment
        return urlComponents?.url
    }
}

private struct RawSymbol: FetchableRecord, Decodable, Sendable {
    let name: String
    let type: String
    let path: String
    let fragment: String?
    let context: String?
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

struct SymbolMatch: Sendable {
    let kind: SymbolMatchKind
    let positions: [Int]
}

enum SymbolMatcher {
    static func match(term: String, candidate: String) -> SymbolMatch? {
        let needle = term.map { String($0).lowercased() }
        let haystack = candidate.map { String($0).lowercased() }
        guard !needle.isEmpty, needle.count <= haystack.count else { return nil }

        if needle == haystack {
            return SymbolMatch(kind: .exact, positions: Array(haystack.indices))
        }
        if Array(haystack.prefix(needle.count)) == needle {
            return SymbolMatch(kind: .prefix, positions: Array(0..<needle.count))
        }
        if let start = contiguousMatchStart(needle: needle, haystack: haystack) {
            return SymbolMatch(kind: .substring, positions: Array(start..<(start + needle.count)))
        }

        var positions: [Int] = []
        var nextNeedleIndex = 0
        for (candidateIndex, character) in haystack.enumerated() where nextNeedleIndex < needle.count {
            if character == needle[nextNeedleIndex] {
                positions.append(candidateIndex)
                nextNeedleIndex += 1
            }
        }
        guard nextNeedleIndex == needle.count else { return nil }
        return SymbolMatch(kind: .fuzzy, positions: positions)
    }

    private static func contiguousMatchStart(needle: [String], haystack: [String]) -> Int? {
        guard needle.count <= haystack.count else { return nil }
        for start in 0...(haystack.count - needle.count) {
            if Array(haystack[start..<(start + needle.count)]) == needle {
                return start
            }
        }
        return nil
    }
}

enum SymbolTypeNormalizer {
    private static let aliases: [String: String] = [
        "cat": "Category",
        "cl": "Class",
        "classes": "Class",
        "data": "Constant",
        "enum": "Enumeration",
        "func": "Function",
        "functions": "Function",
        "instm": "Method",
        "methods": "Method",
        "intf": "Protocol",
        "protocols": "Protocol",
    ]

    static func normalize(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let alias = aliases[trimmed.lowercased()] {
            return alias
        }
        // Unknown values are docset-owned data. Preserve their spelling instead
        // of guessing at title case, which would turn acronyms such as HTTP into Http.
        return trimmed
    }

    static func rawFilterValues(for normalizedFilters: [String]) -> [String] {
        var rawValues: Set<String> = []
        for filter in normalizedFilters.map({ $0.lowercased() }) {
            rawValues.insert(filter)
            for (alias, normalizedType) in aliases where normalizedType.lowercased() == filter {
                rawValues.insert(alias)
            }
        }
        return rawValues.sorted()
    }
}
