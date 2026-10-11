import Foundation
import GRDB

public protocol DocsetRepository: Sendable {
    func register(bundleAt bundleURL: URL) async throws -> DocsetDescriptor
    func allDocsets() async throws -> [DocsetDescriptor]
    func unregister(identifier: String) async throws
    func scanAndRegister(docsetsDirectory: URL) async throws -> DocsetScanReport
}

/// Persists descriptors only after a docset has passed structural validation.
public actor DocsetRegistry: DocsetRepository {
    private let database: DatabaseQueue
    private let parser: DocsetParser

    public init(databaseURL: URL, parser: DocsetParser = DocsetParser()) throws {
        let databaseURL = databaseURL.standardizedFileURL
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var configuration = Configuration()
        // A completed transfer may still be finishing a short persisted write
        // when another registry connection opens. Wait briefly, never forever.
        configuration.busyMode = .timeout(2)
        database = try DatabaseQueue(path: databaseURL.path, configuration: configuration)
        self.parser = parser
        let needsSourceMigration = try database.read { db in
            try db.tableExists("installed_docsets") && !db.tableExists("source_configurations")
        }
        if needsSourceMigration {
            let backupURL = databaseURL.deletingLastPathComponent()
                .appending(path: "pre-sources-\(UUID().uuidString).sqlite")
            try database.backup(to: DatabaseQueue(path: backupURL.path))
        }
        try Self.migrator.migrate(database)
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1-installed-docsets") { db in
            try db.create(table: "installed_docsets", ifNotExists: true) { table in
                table.primaryKey("identifier", .text)
                table.column("descriptor", .blob).notNull()
            }
        }
        migrator.registerMigration("v2-lifecycle") { db in
            let columns = Set(try db.columns(in: "installed_docsets").map(\.name))
            if !columns.contains("source_json") {
                try db.alter(table: "installed_docsets") { table in
                    table.add(column: "source_json", .text)
                }
            }
            if !columns.contains("advertised_version_json") {
                try db.alter(table: "installed_docsets") { table in
                    table.add(column: "advertised_version_json", .text)
                }
            }
            try db.create(table: "feeds", ifNotExists: true) { table in
                table.primaryKey("id", .text)
                table.column("feed_url", .text).notNull().unique()
                table.column("payload", .blob).notNull()
            }
            try db.create(table: "transfer_jobs", ifNotExists: true) { table in
                table.primaryKey("id", .text)
                table.column("payload", .blob).notNull()
            }
            try db.create(table: "app_settings", ifNotExists: true) { table in
                table.primaryKey("key", .text)
                table.column("value", .blob).notNull()
            }
        }
        migrator.registerMigration("v3-versioned-installations") { db in
            try db.alter(table: "installed_docsets") { table in
                table.add(column: "selection_policy_json", .text)
                table.add(column: "install_target_json", .text)
                table.add(column: "slot_source_id", .text)
                table.add(column: "slot_family_id", .text)
            }
            // NULL slots belong to legacy/local entries, never inferred by name.
            try db.create(index: "unique_install_slot", on: "installed_docsets",
                          columns: ["slot_source_id", "slot_family_id"], unique: true)
        }
        migrator.registerMigration("v4-replacement-receipts") { db in
            try db.create(table: "replacement_commits") { table in
                table.primaryKey("id", .text)
            }
        }
        migrator.registerMigration("v5-configured-sources") { db in
            try db.create(table: "source_configurations") { table in
                table.primaryKey("id", .text)
                table.column("payload", .blob).notNull()
            }
            try db.alter(table: "installed_docsets") { table in
                table.add(column: "configured_source_id", .text).notNull().defaults(to: "")
                table.add(column: "configured_source_name", .text)
            }
            try db.drop(index: "unique_install_slot")
            try db.create(index: "unique_install_slot", on: "installed_docsets",
                          columns: ["configured_source_id", "slot_source_id", "slot_family_id"], unique: true)
        }
        return migrator
    }

    @discardableResult
    public func register(bundleAt bundleURL: URL) async throws -> DocsetDescriptor {
        try await register(bundleAt: bundleURL, assignRuntimeID: false)
    }

    public func register(bundleAt bundleURL: URL, assignRuntimeID: Bool) async throws -> DocsetDescriptor {
        let parsed = try parser.parse(bundleAt: bundleURL)
        return try await database.write { db in
        let records = try Row.fetchAll(db, sql: "SELECT * FROM installed_docsets").compactMap(Self.decodeInstalled)
        let existing = records.first {
            $0.descriptor.bundleURL.resolvingSymlinksInPath().standardizedFileURL.path == parsed.bundleURL.resolvingSymlinksInPath().standardizedFileURL.path
        }
        if let existing, existing.descriptor.bundleIdentifier != parsed.bundleIdentifier {
            throw DocsetInstallError.identityMismatch(expected: existing.descriptor.bundleIdentifier, found: parsed.bundleIdentifier)
        }
        let identifier = existing?.identifier ?? ((assignRuntimeID || records.contains { $0.identifier == parsed.identifier })
            ? UUID().uuidString.lowercased() : parsed.identifier)
        let descriptor = parsed.identified(as: identifier)
        if let target = existing?.installTarget {
            guard existing?.descriptor.bundleURL == descriptor.bundleURL else { throw DocsetReplacementError.conflictingInstall }
            try target.validate(descriptor)
        }
        let record = InstalledDocset(
            descriptor: descriptor,
            source: existing?.source ?? .localImport,
            advertisedVersion: existing?.advertisedVersion ?? DocsetVersion(descriptor: descriptor),
            selectionPolicy: existing?.selectionPolicy ?? .latest,
            installTarget: existing?.installTarget,
            sourceConfigurationID: existing?.sourceConfigurationID ?? (assignRuntimeID ? DocsetSourceConfiguration.localID : nil),
            sourceName: existing?.sourceName ?? (assignRuntimeID ? "Local Imports" : nil)
        )
        try Self.writeInstalled(record, in: db)
        return descriptor
        }
    }

    @discardableResult
    public func upsert(_ record: InstalledDocset) async throws -> InstalledDocset {
        try await database.write { db in
            try Self.writeInstalled(record, in: db)
        }
        return record
    }

    public func allDocsets() async throws -> [DocsetDescriptor] {
        try await allInstalled().map(\.descriptor)
    }

    public func allInstalled() async throws -> [InstalledDocset] {
        let records = try await database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT *
                  FROM installed_docsets
                """)
                .compactMap(Self.decodeInstalled)
        }
        return records.sorted { lhs, rhs in
            let comparison = lhs.descriptor.displayName.localizedCaseInsensitiveCompare(rhs.descriptor.displayName)
            return comparison == .orderedSame
                ? lhs.identifier < rhs.identifier
                : comparison == .orderedAscending
        }
    }

    public func installed(identifier: String) async throws -> InstalledDocset? {
        try await database.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT *
                      FROM installed_docsets WHERE identifier = ?
                    """,
                arguments: [identifier]
            )
            .flatMap(Self.decodeInstalled)
        }
    }

    public func unregister(identifier: String) async throws {
        try await database.write { db in
            try db.execute(
                sql: "DELETE FROM installed_docsets WHERE identifier = ?",
                arguments: [identifier]
            )
        }
    }

    public func installed(sourceId: String, familyId: String) async throws -> InstalledDocset? {
        try await installed(sourceConfigurationID: nil, sourceId: sourceId, familyId: familyId)
    }

    public func installed(sourceConfigurationID: UUID?, sourceId: String, familyId: String) async throws -> InstalledDocset? {
        try await database.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM installed_docsets WHERE configured_source_id = ? AND slot_source_id = ? AND slot_family_id = ?",
                             arguments: [sourceConfigurationID?.uuidString ?? "", sourceId, familyId]).flatMap(Self.decodeInstalled)
        }
    }

    // MARK: - Configured sources

    public func localImport(bundleIdentifier: String, sourceConfigurationID: UUID) async throws -> InstalledDocset? {
        for record in try await allInstalled() {
            guard case .localImport = record.source else { continue }
            guard record.sourceConfigurationID == sourceConfigurationID else { continue }
            if record.descriptor.bundleIdentifier == bundleIdentifier { return record }
        }
        return nil
    }

    public func allSources() async throws -> [DocsetSourceConfiguration] {
        let payloads = try await database.read { db in try Data.fetchAll(db, sql: "SELECT payload FROM source_configurations ORDER BY id") }
        return try payloads.map { try JSONDecoder().decode(DocsetSourceConfiguration.self, from: $0) }
    }

    public func source(id: UUID) async throws -> DocsetSourceConfiguration? {
        try await allSources().first { $0.id == id }
    }

    public func saveSource(_ source: DocsetSourceConfiguration) async throws {
        try await database.write { db in
            let sources = try Data.fetchAll(db, sql: "SELECT payload FROM source_configurations")
                .map { try JSONDecoder().decode(DocsetSourceConfiguration.self, from: $0) }
            if let old = sources.first(where: { $0.id == source.id }) {
                guard !source.isBuiltIn || !source.isDeleted else { throw DocsetSourceError.builtInSource }
                guard old.kind == source.kind, old.transportPolicy == source.transportPolicy,
                      !old.isDeleted || source.isDeleted else { throw DocsetSourceError.endpointChanged }
                if !source.canFetch {
                    try Self.writeSource(source, in: db)
                    return
                }
            } else if source.isBuiltIn { throw DocsetSourceError.invalidConfiguration }
            try source.validate()
            guard !sources.contains(where: { $0.id != source.id && !$0.isDeleted &&
                ($0.name.caseInsensitiveCompare(source.name) == .orderedSame || ($0.kind == source.kind && source.kind != .unavailable))
            }) else { throw DocsetSourceError.duplicateSource }
            try Self.writeSource(source, in: db)
        }
    }

    public func deleteSource(id: UUID) async throws {
        guard var source = try await source(id: id) else { return }
        guard !source.isBuiltIn else { throw DocsetSourceError.builtInSource }
        source.isDeleted = true; source.isEnabled = false
        try await saveSource(source)
    }

    /// One transaction preserves legacy identities and paths while recording origin.
    /// Call before scanning or restoring transfers. A missing proof is not a Zeal opt-in.
    public func initializeSources(legacyCatalogSourceID: UUID? = nil, legacyCatalogEntries: [CatalogEntry] = []) async throws {
        try await database.write { db in
            guard try Data.fetchOne(db, sql: "SELECT value FROM app_settings WHERE key = 'source-migration-v1'") == nil else { return }
            for source in DocsetSourceConfiguration.defaults { try Self.writeSource(source, in: db) }
            let feeds = try Data.fetchAll(db, sql: "SELECT payload FROM feeds")
                .map { try JSONDecoder().decode(DashFeed.self, from: $0) }
            for feed in feeds {
                let trimmed = feed.name.trimmingCharacters(in: .whitespacesAndNewlines)
                let base = trimmed.isEmpty ? "Feed" : String(trimmed.prefix(120))
                let duplicates = feeds.filter { $0.name.caseInsensitiveCompare(feed.name) == .orderedSame }.count > 1
                let name = duplicates ? "\(base.prefix(109)) · \(feed.id.uuidString.prefix(8))" : base
                var configuration = DocsetSourceConfiguration(id: feed.id, name: name, kind: .feed(url: feed.feedURL))
                if (try? configuration.validate()) == nil { configuration.isEnabled = false }
                try Self.writeSource(configuration, in: db)
            }
            let legacy = DocsetSourceConfiguration(id: DocsetSourceConfiguration.legacyID, name: "Legacy Catalog",
                kind: .unavailable, isEnabled: false)
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM installed_docsets")
            for row in rows {
                guard var record = try Self.decodeInstalled(row), record.sourceConfigurationID == nil else { continue }
                switch record.source {
                case let .catalog(name, publisher):
                    let knownEntry = legacyCatalogEntries.contains { $0.name == name && $0.sourceId == publisher }
                    let proven = knownEntry ? DocsetSourceConfiguration.defaults.first { $0.id == legacyCatalogSourceID } : nil
                    record.sourceConfigurationID = proven?.id ?? legacy.id
                    record.sourceName = proven?.name ?? legacy.name
                    if proven == nil { try Self.writeSource(legacy, in: db) }
                    if let id = record.sourceConfigurationID { record.installTarget = record.installTarget?.scoped(to: id) }
                case let .feed(url):
                    let feed = feeds.first { $0.feedURL == url }
                    record.sourceConfigurationID = feed?.id ?? legacy.id
                    record.sourceName = feed?.name ?? "Removed Feed"
                    if feed == nil { try Self.writeSource(legacy, in: db) }
                case .localImport:
                    record.sourceConfigurationID = DocsetSourceConfiguration.localID
                    record.sourceName = "Local Imports"
                }
                try Self.writeInstalled(record, in: db, migratingSource: true)
            }
            let payloads = try Data.fetchAll(db, sql: "SELECT payload FROM transfer_jobs")
            for payload in payloads {
                var job = try JSONDecoder().decode(TransferJob.self, from: payload)
                guard job.kind != .localImport, job.sourceConfigurationID == nil else { continue }
                let knownEntry = legacyCatalogEntries.contains { $0.name == job.catalogName && $0.sourceId == job.catalogSourceId }
                let id = job.kind == .feed ? feeds.first { $0.feedURL == job.feedURL }?.id : (knownEntry ? legacyCatalogSourceID : nil)
                job.sourceConfigurationID = id ?? legacy.id
                if id == nil { try Self.writeSource(legacy, in: db) }
                job.sourceName = DocsetSourceConfiguration.defaults.first { $0.id == id }?.name ?? legacy.name
                job.target = job.target?.scoped(to: job.sourceConfigurationID!)
                try db.execute(sql: "UPDATE transfer_jobs SET payload = ? WHERE id = ?",
                    arguments: [try JSONEncoder().encode(job), job.id.uuidString])
            }
            try db.execute(sql: "INSERT INTO app_settings(key, value) VALUES ('source-migration-v1', ?)", arguments: [Data([1])])
        }
    }

    private nonisolated static func writeSource(_ source: DocsetSourceConfiguration, in db: Database) throws {
        try db.execute(sql: "INSERT INTO source_configurations(id, payload) VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET payload = excluded.payload",
                       arguments: [source.id.uuidString, try JSONEncoder().encode(source)])
    }

    func commitReplacement(_ record: InstalledDocset, replacing expected: InstalledDocset?, transactionId: UUID) async throws {
        try await database.write { db in
            let previous = try Row.fetchOne(db, sql: "SELECT * FROM installed_docsets WHERE identifier = ?",
                                            arguments: [record.identifier]).flatMap(Self.decodeInstalled)
            guard previous == expected, record.installTarget != nil else { throw DocsetReplacementError.conflictingInstall }
            try Self.writeInstalled(record, in: db)
            try db.execute(sql: "INSERT INTO replacement_commits(id) VALUES (?)", arguments: [transactionId.uuidString])
        }
    }

    func hasReplacementCommit(_ id: UUID) async throws -> Bool {
        try await database.read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM replacement_commits WHERE id = ?)", arguments: [id.uuidString]) ?? false
        }
    }

    /// Discovers bundles on disk without dropping registry rows whose files are
    /// currently unreachable — a disconnected volume must not unregister them.
    public func scanAndRegister(docsetsDirectory: URL) async throws -> DocsetScanReport {
        try await scanAndRegister(docsetsDirectory: docsetsDirectory, assignRuntimeIDs: false)
    }

    public func scanAndRegister(docsetsDirectory: URL, assignRuntimeIDs: Bool) async throws -> DocsetScanReport {
        let urls = try FileManager.default.contentsOfDirectory(
            at: docsetsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension.lowercased() == "docset" }
        .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }

        var registered: [DocsetDescriptor] = []
        var failures: [DocsetScanFailure] = []
        for url in urls {
            do {
                if url.lastPathComponent.range(of: "^crux-[0-9a-f]{64}\\.docset$", options: .regularExpression) != nil,
                   !(try await allInstalled()).contains(where: { $0.descriptor.bundleURL.standardizedFileURL == url.standardizedFileURL }) {
                    throw DocsetReplacementError.recoveryRequired
                }
                registered.append(try await register(bundleAt: url, assignRuntimeID: assignRuntimeIDs))
            } catch {
                failures.append(DocsetScanFailure(
                    bundleURL: url.standardizedFileURL,
                    message: (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                ))
            }
        }
        return DocsetScanReport(registered: registered, failures: failures)
    }

    // MARK: - Feeds

    public func allFeeds() async throws -> [DashFeed] {
        let payloads = try await database.read { db in
            try Data.fetchAll(db, sql: "SELECT payload FROM feeds")
        }
        return try payloads
            .map { try JSONDecoder().decode(DashFeed.self, from: $0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func saveFeed(_ feed: DashFeed) async throws {
        let existing = try await allFeeds()
        if existing.contains(where: { $0.id != feed.id && $0.feedURL == feed.feedURL }) {
            throw DashFeedError.duplicateFeed
        }
        if existing.contains(where: { $0.id != feed.id && $0.downloadURL == feed.downloadURL }) {
            throw DashFeedError.duplicateDownload(feed.downloadURL)
        }
        let data = try JSONEncoder().encode(feed)
        try await database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO feeds(id, feed_url, payload)
                    VALUES (?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET feed_url = excluded.feed_url, payload = excluded.payload
                    """,
                arguments: [feed.id.uuidString, feed.feedURL.absoluteString, data]
            )
        }
    }

    public func deleteFeed(id: UUID) async throws {
        try await database.write { db in
            try db.execute(sql: "DELETE FROM feeds WHERE id = ?", arguments: [id.uuidString])
        }
    }

    // MARK: - Jobs

    public func allJobs() async throws -> [TransferJob] {
        let payloads = try await database.read { db in
            try Data.fetchAll(db, sql: "SELECT payload FROM transfer_jobs")
        }
        return try payloads.map { try JSONDecoder().decode(TransferJob.self, from: $0) }
    }

    public func saveJobs(_ jobs: [TransferJob]) async throws {
        let encoded = try jobs.map { job -> (String, Data) in
            (job.id.uuidString, try JSONEncoder().encode(job))
        }
        try await database.write { db in
            try db.execute(sql: "DELETE FROM transfer_jobs")
            for (id, data) in encoded {
                try db.execute(
                    sql: "INSERT INTO transfer_jobs(id, payload) VALUES (?, ?)",
                    arguments: [id, data]
                )
            }
        }
    }

    // MARK: - Settings

    public func loadSettings() async throws -> LibrarySettings {
        let data = try await database.read { db in
            try Data.fetchOne(db, sql: "SELECT value FROM app_settings WHERE key = ?", arguments: ["library"])
        }
        guard let data else { return .default }
        return try JSONDecoder().decode(LibrarySettings.self, from: data)
    }

    public func saveSettings(_ settings: LibrarySettings) async throws {
        let data = try JSONEncoder().encode(settings)
        try await database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO app_settings(key, value) VALUES (?, ?)
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value
                    """,
                arguments: ["library", data]
            )
        }
    }

    /// Commits the filesystem paths and the selected storage root in one
    /// SQLite transaction after `StorageMigrator` has verified every copy.
    ///
    /// Readers can observe the old snapshot or the new one, never a mixture of
    /// relocated descriptors and the previous storage setting.
    public func applyStorageMigration(
        records: [InstalledDocset],
        settings: LibrarySettings
    ) async throws {
        let settingsData = try JSONEncoder().encode(settings)

        try await database.write { db in
            for record in records {
                try Self.writeInstalled(record, in: db)
            }
            try db.execute(
                sql: """
                    INSERT INTO app_settings(key, value) VALUES (?, ?)
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value
                    """,
                arguments: ["library", settingsData]
            )
        }
    }

    // MARK: - Decoding

    private nonisolated static func writeInstalled(_ record: InstalledDocset, in db: Database, migratingSource: Bool = false) throws {
        if let target = record.installTarget {
            try target.validate(record.descriptor)
            guard record.source == .catalog(name: target.familyId, sourceId: target.sourceId),
                  record.selectionPolicy == target.selectionPolicy,
                  record.advertisedVersion == target.release.advertisedVersion,
                  record.sourceConfigurationID == target.sourceConfigurationID else { throw DocsetReplacementError.targetMismatch }
        }
        if let previous = try Row.fetchOne(db, sql: "SELECT * FROM installed_docsets WHERE identifier = ?",
                                          arguments: [record.identifier]).flatMap(decodeInstalled),
           !migratingSource && (previous.installTarget?.slotKey != record.installTarget?.slotKey || previous.sourceConfigurationID != record.sourceConfigurationID) {
            throw DocsetReplacementError.conflictingInstall
        }
        let encoder = JSONEncoder()
        for row in try Row.fetchAll(db, sql: "SELECT * FROM installed_docsets") {
            guard let other = try decodeInstalled(row), other.identifier != record.identifier else { continue }
            guard other.descriptor.bundleURL.resolvingSymlinksInPath().standardizedFileURL != record.descriptor.bundleURL.resolvingSymlinksInPath().standardizedFileURL else {
                throw DocsetReplacementError.conflictingInstall
            }
            if record.sourceConfigurationID == DocsetSourceConfiguration.localID, record.source == .localImport,
               other.sourceConfigurationID == record.sourceConfigurationID, other.source == .localImport,
               other.descriptor.bundleIdentifier == record.descriptor.bundleIdentifier {
                throw DocsetReplacementError.conflictingInstall
            }
        }
        let publisher: String?
        let family: String?
        switch record.source {
        case let .catalog(name, sourceId): publisher = sourceId; family = name
        case let .feed(url): publisher = "feed"; family = url.absoluteString
        case .localImport:
            publisher = record.sourceConfigurationID == DocsetSourceConfiguration.localID ? "local" : nil
            family = publisher == nil ? nil : record.descriptor.bundleIdentifier
        }
        func json<T: Encodable>(_ value: T) throws -> String { String(decoding: try encoder.encode(value), as: UTF8.self) }
        try db.execute(sql: """
            INSERT INTO installed_docsets(identifier, descriptor, source_json, advertised_version_json,
                                          selection_policy_json, install_target_json, slot_source_id, slot_family_id,
                                          configured_source_id, configured_source_name)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(identifier) DO UPDATE SET
                descriptor = excluded.descriptor, source_json = excluded.source_json,
                advertised_version_json = excluded.advertised_version_json,
                selection_policy_json = excluded.selection_policy_json, install_target_json = excluded.install_target_json,
                slot_source_id = excluded.slot_source_id, slot_family_id = excluded.slot_family_id,
                configured_source_id = excluded.configured_source_id, configured_source_name = excluded.configured_source_name
            """, arguments: [record.identifier, try encoder.encode(record.descriptor), try json(record.source),
                             try json(record.advertisedVersion), try json(record.selectionPolicy),
                             try record.installTarget.map(json), publisher, family,
                             record.sourceConfigurationID?.uuidString ?? "", record.sourceName])
    }

    // Row never leaves GRDB's database access closure. Only immutable Sendable
    // snapshots cross back to the registry actor.
    private nonisolated static func decodeInstalled(_ row: Row) throws -> InstalledDocset? {
        guard let descriptorData = row["descriptor"] as Data? else { return nil }
        let descriptor = try JSONDecoder().decode(DocsetDescriptor.self, from: descriptorData)
        let source: DocsetSource
        if let json = row["source_json"] as String?, let data = json.data(using: .utf8) {
            source = (try? JSONDecoder().decode(DocsetSource.self, from: data)) ?? .localImport
        } else {
            source = .localImport
        }
        let advertised: DocsetVersion
        if let json = row["advertised_version_json"] as String?, let data = json.data(using: .utf8) {
            advertised = (try? JSONDecoder().decode(DocsetVersion.self, from: data))
                ?? DocsetVersion(descriptor: descriptor)
        } else {
            advertised = DocsetVersion(descriptor: descriptor)
        }
        let policy: DocsetSelectionPolicy
        if let json = row["selection_policy_json"] as String? {
            policy = try JSONDecoder().decode(DocsetSelectionPolicy.self, from: Data(json.utf8))
        } else { policy = .latest }
        let target: DocsetInstallTarget?
        if let json = row["install_target_json"] as String? {
            target = try JSONDecoder().decode(DocsetInstallTarget.self, from: Data(json.utf8))
            try target?.validate(descriptor)
        } else { target = nil }
        return InstalledDocset(descriptor: descriptor, source: source, advertisedVersion: advertised,
                               selectionPolicy: policy, installTarget: target,
                               sourceConfigurationID: (row["configured_source_id"] as String?).flatMap(UUID.init(uuidString:)),
                               sourceName: row["configured_source_name"])
    }
}

public struct DocsetScanReport: Equatable, Sendable {
    public let registered: [DocsetDescriptor]
    public let failures: [DocsetScanFailure]
}

public struct DocsetScanFailure: Equatable, Sendable {
    public let bundleURL: URL
    public let message: String
}
