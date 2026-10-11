import Foundation
import GRDB
import SwiftSoup

public enum FullTextIndexPhase: String, Codable, Equatable, Sendable {
    case disabled
    case pending
    case indexing
    case interrupted
    case ready
    case failed
}

public struct FullTextIndexState: Codable, Equatable, Sendable {
    public let docsetIdentifier: String
    public var isEnabled: Bool
    public var phase: FullTextIndexPhase
    public var indexedDocumentCount: Int
    public var totalDocumentCount: Int
    public var lastIndexedPath: String?
    public var contentSignature: String
    public var failureMessage: String?

    public init(
        docsetIdentifier: String,
        isEnabled: Bool,
        phase: FullTextIndexPhase,
        indexedDocumentCount: Int = 0,
        totalDocumentCount: Int = 0,
        lastIndexedPath: String? = nil,
        contentSignature: String = "",
        failureMessage: String? = nil
    ) {
        self.docsetIdentifier = docsetIdentifier
        self.isEnabled = isEnabled
        self.phase = phase
        self.indexedDocumentCount = indexedDocumentCount
        self.totalDocumentCount = totalDocumentCount
        self.lastIndexedPath = lastIndexedPath
        self.contentSignature = contentSignature
        self.failureMessage = failureMessage
    }
}

public struct FullTextIndexProgress: Equatable, Sendable {
    public let docsetIdentifier: String
    public let indexedDocumentCount: Int
    public let totalDocumentCount: Int
    public let currentPath: String
}

public struct FullTextSearchResult: Equatable, Hashable, Sendable {
    public let docsetIdentifier: String
    public let docsetName: String
    public let relativePath: String
    public let title: String
    public let excerpt: String
    public let rank: Double

    public init(
        docsetIdentifier: String,
        docsetName: String,
        relativePath: String,
        title: String,
        excerpt: String,
        rank: Double
    ) {
        self.docsetIdentifier = docsetIdentifier
        self.docsetName = docsetName
        self.relativePath = relativePath
        self.title = title
        self.excerpt = excerpt
        self.rank = rank
    }
}

public enum FullTextSearchError: Error, Equatable, LocalizedError, Sendable {
    case indexingNotEnabled(String)

    public var errorDescription: String? {
        switch self {
        case let .indexingNotEnabled(identifier):
            "Full-text indexing is not enabled for \(identifier)."
        }
    }
}

/// Owns Crux's rebuildable page-content index.
///
/// A docset's vendor database remains read-only. Extracted HTML lives in a
/// separate Crux-owned SQLite file so it can be rebuilt or deleted without
/// mutating the source-of-truth docset.
public actor FullTextSearchService {
    public static let shortQueryResultLimit = 100
    public static let defaultMaximumDocumentBytes: Int64 = 16 * 1_024 * 1_024

    private struct Page: Sendable {
        let url: URL
        let relativePath: String
        let fileSize: Int64
        let modificationTime: TimeInterval
    }

    private struct ExtractedPage: Sendable {
        let title: String
        let body: String
    }

    private let database: DatabaseQueue
    private let maximumDocumentBytes: Int64

    public init(
        databaseURL: URL,
        maximumDocumentBytes: Int64 = FullTextSearchService.defaultMaximumDocumentBytes
    ) throws {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        database = try DatabaseQueue(path: databaseURL.standardizedFileURL.path)
        self.maximumDocumentBytes = max(1, maximumDocumentBytes)
        try Self.migrator.migrate(database)
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1-full-text") { db in
            try db.create(table: "full_text_documents") { table in
                table.autoIncrementedPrimaryKey("rowid")
                table.column("docset_identifier", .text).notNull()
                table.column("relative_path", .text).notNull()
                table.column("title", .text).notNull()
                table.column("body", .text).notNull()
                table.uniqueKey(["docset_identifier", "relative_path"])
            }
            // GRDB exposes FTS5 safely, but the raw declaration makes the
            // required trigram tokenizer explicit and easy to audit.
            try db.execute(sql: """
                CREATE VIRTUAL TABLE full_text_search USING fts5(
                  title,
                  body,
                  content='full_text_documents',
                  content_rowid='rowid',
                  tokenize='trigram'
                )
                """)
            try db.execute(sql: """
                CREATE TRIGGER full_text_documents_ai AFTER INSERT ON full_text_documents BEGIN
                  INSERT INTO full_text_search(rowid, title, body)
                  VALUES (new.rowid, new.title, new.body);
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER full_text_documents_ad AFTER DELETE ON full_text_documents BEGIN
                  INSERT INTO full_text_search(full_text_search, rowid, title, body)
                  VALUES ('delete', old.rowid, old.title, old.body);
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER full_text_documents_au AFTER UPDATE ON full_text_documents BEGIN
                  INSERT INTO full_text_search(full_text_search, rowid, title, body)
                  VALUES ('delete', old.rowid, old.title, old.body);
                  INSERT INTO full_text_search(rowid, title, body)
                  VALUES (new.rowid, new.title, new.body);
                END
                """)
            try db.create(table: "full_text_index_state") { table in
                table.primaryKey("docset_identifier", .text)
                table.column("is_enabled", .boolean).notNull()
                table.column("phase", .text).notNull()
                table.column("indexed_count", .integer).notNull()
                table.column("total_count", .integer).notNull()
                table.column("last_path", .text)
                table.column("content_signature", .text).notNull()
                table.column("failure_message", .text)
            }
            try db.create(
                index: "full_text_documents_docset",
                on: "full_text_documents",
                columns: ["docset_identifier"]
            )
        }
        return migrator
    }

    public func state(for identifier: String) throws -> FullTextIndexState? {
        let row = try database.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT * FROM full_text_index_state WHERE docset_identifier = ?",
                arguments: [identifier]
            )
        }
        return row.flatMap(Self.decodeState)
    }

    public func allStates() throws -> [FullTextIndexState] {
        try database.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM full_text_index_state ORDER BY docset_identifier")
                .compactMap(Self.decodeState)
        }
    }

    /// Permanently opts a docset into full-text indexing. Repeated calls keep a
    /// completed or interrupted index intact; removal happens only with the docset.
    public func enable(for docset: DocsetDescriptor) throws {
        var value = try state(for: docset.identifier) ?? FullTextIndexState(
            docsetIdentifier: docset.identifier,
            isEnabled: true,
            phase: .pending
        )
        value.isEnabled = true
        if value.phase == .disabled { value.phase = .pending }
        value.failureMessage = nil
        try save(value)
    }

    @discardableResult
    public func index(
        _ docset: DocsetDescriptor,
        forceRebuild: Bool = false,
        progress: (@Sendable (FullTextIndexProgress) -> Void)? = nil
    ) async throws -> FullTextIndexState {
        guard var current = try state(for: docset.identifier), current.isEnabled else {
            throw FullTextSearchError.indexingNotEnabled(docset.identifier)
        }

        let pages = try pages(in: docset)
        let signature = inventorySignature(for: docset, pages: pages)
        let mustStartOver = forceRebuild || current.contentSignature != signature
        if !mustStartOver, current.phase == .ready {
            return current
        }

        if mustStartOver {
            try deleteDocuments(for: docset.identifier)
            current.indexedDocumentCount = 0
            current.lastIndexedPath = nil
        }
        current.phase = .indexing
        current.totalDocumentCount = pages.count
        current.contentSignature = signature
        current.failureMessage = nil
        try save(current)

        let startingIndex: Int
        if !mustStartOver,
           let lastPath = current.lastIndexedPath,
           let lastIndex = pages.firstIndex(where: { $0.relativePath == lastPath }) {
            startingIndex = lastIndex + 1
        } else {
            startingIndex = 0
        }

        do {
            for page in pages.dropFirst(startingIndex) {
                // Yielding keeps cancellation and UI progress responsive even
                // when every HTML file is tiny and already in the filesystem cache.
                await Task.yield()
                try Task.checkCancellation()
                if let extracted = try extract(page) {
                    try upsert(
                        docsetIdentifier: docset.identifier,
                        relativePath: page.relativePath,
                        page: extracted
                    )
                    current.indexedDocumentCount += 1
                }
                current.lastIndexedPath = page.relativePath
                try save(current)
                progress?(FullTextIndexProgress(
                    docsetIdentifier: docset.identifier,
                    indexedDocumentCount: current.indexedDocumentCount,
                    totalDocumentCount: pages.count,
                    currentPath: page.relativePath
                ))
            }

            current.phase = .ready
            current.lastIndexedPath = pages.last?.relativePath
            try save(current)
            return current
        } catch is CancellationError {
            // Cancellation is a pause, not an opt-out. Keep the one-way enabled
            // flag and persist the cursor so the menu can resume later.
            if try state(for: docset.identifier)?.isEnabled == true {
                current.phase = .interrupted
                try save(current)
            }
            throw CancellationError()
        } catch {
            current.phase = .failed
            current.failureMessage = error.localizedDescription
            try save(current)
            throw error
        }
    }

    public func search(
        _ rawQuery: String,
        in docsets: [DocsetDescriptor],
        limit: Int = 300
    ) throws -> [FullTextSearchResult] {
        try Task.checkCancellation()
        guard limit > 0, !docsets.isEmpty else { return [] }
        let parsed = SearchQuery.parse(
            rawQuery,
            knownDocsetFilters: Set(docsets.flatMap(\.searchFilters)),
            knownSymbolTypes: []
        )
        let term = parsed.term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return [] }
        let selected = parsed.docsetFilters.isEmpty ? docsets : docsets.filter {
            !$0.searchFilters.isDisjoint(with: parsed.docsetFilters)
        }
        let names = Dictionary(uniqueKeysWithValues: selected.map { ($0.identifier, $0.displayName) })
        guard !names.isEmpty else { return [] }

        let rows = term.count < 3
            ? try shortQuery(term, identifiers: Array(names.keys), limit: min(limit, Self.shortQueryResultLimit))
            : try trigramQuery(term, identifiers: Array(names.keys), limit: limit)
        let results: [FullTextSearchResult] = rows.compactMap { row in
            guard let identifier: String = row["docset_identifier"],
                  let docsetName = names[identifier],
                  let relativePath: String = row["relative_path"],
                  let title: String = row["title"],
                  let excerpt: String = row["excerpt"] else {
                return nil
            }
            let rank: Double = row["rank"] ?? 0
            return FullTextSearchResult(
                docsetIdentifier: identifier,
                docsetName: docsetName,
                relativePath: relativePath,
                title: title,
                excerpt: excerpt,
                rank: rank
            )
        }
        try Task.checkCancellation()
        return results
    }

    public func removeIndex(for identifier: String) throws {
        try database.write { db in
            try db.execute(
                sql: "DELETE FROM full_text_documents WHERE docset_identifier = ?",
                arguments: [identifier]
            )
            try db.execute(
                sql: "DELETE FROM full_text_index_state WHERE docset_identifier = ?",
                arguments: [identifier]
            )
        }
    }

    // MARK: - HTML inventory and extraction

    private func pages(in docset: DocsetDescriptor) throws -> [Page] {
        let root = docset.documentsURL.resolvingSymlinksInPath().standardizedFileURL
        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .contentModificationDateKey,
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: docset.documentsURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else { return [] }

        var result: [Page] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true,
                  ["html", "htm"].contains(url.pathExtension.lowercased()),
                  Int64(values.fileSize ?? 0) <= maximumDocumentBytes else {
                continue
            }
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            guard resolved.path.hasPrefix(root.path + "/") else { continue }
            let relativePath = String(resolved.path.dropFirst(root.path.count + 1))
            result.append(Page(
                url: resolved,
                relativePath: relativePath,
                fileSize: Int64(values.fileSize ?? 0),
                modificationTime: values.contentModificationDate?.timeIntervalSince1970 ?? 0
            ))
        }
        return result.sorted { $0.relativePath < $1.relativePath }
    }

    private func extract(_ page: Page) throws -> ExtractedPage? {
        let values = try page.url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              Int64(values.fileSize ?? 0) <= maximumDocumentBytes else {
            return nil
        }
        let data = try Data(contentsOf: page.url, options: [.mappedIfSafe])
        guard Int64(data.count) <= maximumDocumentBytes else { return nil }
        let html = String(decoding: data, as: UTF8.self)
        let document = try SwiftSoup.parse(html)
        try document.select("script, style, noscript").remove()
        let body = try document.body()?.text()
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !body.isEmpty else { return nil }
        let parsedTitle = try document.title().trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackTitle = page.url.deletingPathExtension().lastPathComponent
        return ExtractedPage(title: parsedTitle.isEmpty ? fallbackTitle : parsedTitle, body: body)
    }

    /// Stable FNV-1a digest of the inventory. Unlike Swift's `Hasher`, this is
    /// deterministic across launches and can therefore drive resume decisions.
    private func inventorySignature(for docset: DocsetDescriptor, pages: [Page]) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        let fields = [docset.version ?? "", docset.revision.map(String.init) ?? ""] + pages.flatMap {
            [$0.relativePath, String($0.fileSize), String($0.modificationTime)]
        }
        for byte in fields.joined(separator: "\u{0}").utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    // MARK: - SQLite

    private func upsert(
        docsetIdentifier: String,
        relativePath: String,
        page: ExtractedPage
    ) throws {
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO full_text_documents(docset_identifier, relative_path, title, body)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(docset_identifier, relative_path) DO UPDATE SET
                        title = excluded.title,
                        body = excluded.body
                    """,
                arguments: [docsetIdentifier, relativePath, page.title, page.body]
            )
        }
    }

    private func deleteDocuments(for identifier: String) throws {
        try database.write { db in
            try db.execute(
                sql: "DELETE FROM full_text_documents WHERE docset_identifier = ?",
                arguments: [identifier]
            )
        }
    }

    private func save(_ state: FullTextIndexState) throws {
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO full_text_index_state(
                        docset_identifier, is_enabled, phase, indexed_count,
                        total_count, last_path, content_signature, failure_message
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(docset_identifier) DO UPDATE SET
                        is_enabled = excluded.is_enabled,
                        phase = excluded.phase,
                        indexed_count = excluded.indexed_count,
                        total_count = excluded.total_count,
                        last_path = excluded.last_path,
                        content_signature = excluded.content_signature,
                        failure_message = excluded.failure_message
                    """,
                arguments: [
                    state.docsetIdentifier,
                    state.isEnabled,
                    state.phase.rawValue,
                    state.indexedDocumentCount,
                    state.totalDocumentCount,
                    state.lastIndexedPath,
                    state.contentSignature,
                    state.failureMessage,
                ]
            )
        }
    }

    private func trigramQuery(_ term: String, identifiers: [String], limit: Int) throws -> [Row] {
        let matchQuery = term.split(whereSeparator: \.isWhitespace)
            .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
            .joined(separator: " AND ")
        let placeholders = identifiers.map { _ in "?" }.joined(separator: ", ")
        var arguments = StatementArguments([matchQuery])
        for identifier in identifiers { arguments += [identifier] }
        arguments += [limit]
        return try database.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT d.docset_identifier, d.relative_path, d.title,
                           snippet(full_text_search, 1, '', '', ' … ', 24) AS excerpt,
                           bm25(full_text_search, 5.0, 1.0) AS rank
                      FROM full_text_search
                      JOIN full_text_documents AS d ON d.rowid = full_text_search.rowid
                      JOIN full_text_index_state AS s
                        ON s.docset_identifier = d.docset_identifier AND s.is_enabled = 1
                     WHERE full_text_search MATCH ?
                       AND d.docset_identifier IN (\(placeholders))
                     ORDER BY rank, d.title, d.relative_path
                     LIMIT ?
                    """,
                arguments: arguments
            )
        }
    }

    private func shortQuery(_ term: String, identifiers: [String], limit: Int) throws -> [Row] {
        let escaped = term
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        let pattern = "%\(escaped)%"
        let placeholders = identifiers.map { _ in "?" }.joined(separator: ", ")
        var arguments = StatementArguments([pattern, pattern])
        for identifier in identifiers { arguments += [identifier] }
        arguments += [limit]
        return try database.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT d.docset_identifier, d.relative_path, d.title,
                           substr(d.body, 1, 240) AS excerpt,
                           0.0 AS rank
                      FROM full_text_documents AS d
                      JOIN full_text_index_state AS s
                        ON s.docset_identifier = d.docset_identifier AND s.is_enabled = 1
                     WHERE (d.title LIKE ? ESCAPE '\\' OR d.body LIKE ? ESCAPE '\\')
                       AND d.docset_identifier IN (\(placeholders))
                     ORDER BY d.title, d.relative_path
                     LIMIT ?
                    """,
                arguments: arguments
            )
        }
    }

    private static func decodeState(_ row: Row) -> FullTextIndexState? {
        guard let identifier: String = row["docset_identifier"],
              let phaseRaw: String = row["phase"],
              let phase = FullTextIndexPhase(rawValue: phaseRaw) else {
            return nil
        }
        return FullTextIndexState(
            docsetIdentifier: identifier,
            isEnabled: row["is_enabled"],
            phase: phase,
            indexedDocumentCount: row["indexed_count"],
            totalDocumentCount: row["total_count"],
            lastIndexedPath: row["last_path"],
            contentSignature: row["content_signature"],
            failureMessage: row["failure_message"]
        )
    }
}
