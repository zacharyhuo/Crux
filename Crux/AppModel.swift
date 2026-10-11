import AppKit
import CruxCore
import Foundation
import Observation
import UniformTypeIdentifiers

enum SettingsSection: Hashable {
    case general
    case docsets
    case privacy
}

enum DocsetsSettingsSection: Hashable {
    case available
    case installed
    case sources
    static var feeds: Self { .sources }
}

/// Application-wide state for the reader window and the library.
///
/// The model owns the long-lived services — registry, search, loopback server,
/// transfer queue and session store — and exposes only main-actor state to
/// SwiftUI. Disk, SQLite, network and socket work stays inside the `CruxCore`
/// actors it calls.
@MainActor
@Observable
final class AppModel: ReaderDocumentContext, TabSearchContext {
    private(set) var docsets: [DocsetDescriptor] = []
    private(set) var installed: [InstalledDocset] = []
    private(set) var scanFailures: [DocsetScanFailure] = []
    private(set) var startupError: String?
    private(set) var libraryError: String?
    private(set) var libraryNotice: String?
    private(set) var isBootstrapping = true

    private(set) var fullTextStates: [String: FullTextIndexState] = [:]

    private(set) var tabs: [ReaderTab] = []
    var selectedTabID: UUID?

    private(set) var catalog: [CatalogEntry] = []
    private(set) var catalogIsFromCache = false
    private(set) var catalogFetchedAt: Date?
    private(set) var isRefreshingCatalog = false
    private(set) var feeds: [DashFeed] = []
    private(set) var sourceLibrary: SourceLibrary?
    var sources: [DocsetSourceConfiguration] { sourceLibrary?.configurations ?? [] }
    var sourceStates: [UUID: SourceRefreshState] { sourceLibrary?.states ?? [:] }
    var enabledSourceCount: Int { sourceLibrary?.enabledCount ?? (injectedCatalogClient == nil ? 0 : 1) }
    var availableDocsets: [SourcedCatalogEntry] {
        if let sourceLibrary { return sourceLibrary.entries }
        return catalog.map { SourcedCatalogEntry(source: DocsetSourceConfiguration.defaults[0], entry: $0) }
    }
    private(set) var transferJobs: [TransferJob] = []
    private(set) var librarySettings = LibrarySettings.default
    /// Exact old docset bundles kept until the user confirms moving them to Trash.
    /// A custom storage root can contain unrelated files, so the root itself is
    /// deliberately never a cleanup target.
    var pendingTrashItems: [URL] = []
    var settingsSelection: SettingsSection = .general
    var docsetsSection: DocsetsSettingsSection = .available

    let preferences: ReaderPreferences
    let layout: AppDirectoryLayout

    @ObservationIgnored private let server: LocalDocumentServer
    @ObservationIgnored private let sessionStore: ReaderSessionStore
    @ObservationIgnored let symbolSearchService = SymbolSearchService()
    @ObservationIgnored private let fullTextService: FullTextSearchService?
    @ObservationIgnored let applicationUpdater: (any ApplicationUpdating)?
    @ObservationIgnored private let installer = DocsetInstaller()
    @ObservationIgnored private let migrator = StorageMigrator()
    @ObservationIgnored private var registry: DocsetRegistry?
    @ObservationIgnored private var transferQueue: TransferQueue?
    @ObservationIgnored private var catalogClient: (any CatalogClient)?
    @ObservationIgnored private var feedClient: DashFeedClient
    @ObservationIgnored private let injectedCatalogClient: (any CatalogClient)?
    @ObservationIgnored private let sourceCatalogOverrides: [UUID: any CatalogClient]
    @ObservationIgnored private let injectedDownloadClient: (any DownloadClient)?
    @ObservationIgnored private let usesBackgroundDownloads: Bool
    @ObservationIgnored let backgroundDownloadIdentifier: String
    /// A main-actor mirror of the server's routing table, so the UI can build
    /// document URLs without awaiting the server actor on every navigation.
    @ObservationIgnored private var router: DocumentRouter
    @ObservationIgnored private var endpoint: DocumentServerEndpoint?
    @ObservationIgnored private var sessionSaveTask: Task<Void, Never>?
    @ObservationIgnored private var catalogRequiresArtworkRefresh = false
    @ObservationIgnored private var hasAttemptedAutomaticCatalogRefresh = false
    @ObservationIgnored private var scopedStorageURL: URL?
    @ObservationIgnored private var handledCompletedJobIDs: Set<UUID> = []
    @ObservationIgnored private var completedJobsTask: Task<Void, Never>?
    @ObservationIgnored private let trashItem: @Sendable (URL) throws -> Void
    @ObservationIgnored private var fullTextIndexTasks: [String: Task<FullTextIndexState, any Error>] = [:]
    @ObservationIgnored private var fullTextIndexGenerations: [String: UUID] = [:]
    @ObservationIgnored private var bootstrapHasStarted = false

    var selectedTab: ReaderTab? {
        tabs.first { $0.id == selectedTabID }
    }

    var currentDocsetsDirectory: URL {
        librarySettings.resolvedDocsetsDirectory(layout: layout)
    }

    var availableUpdates: [String: TransferRequest] {
        if sourceLibrary != nil {
            return Dictionary(uniqueKeysWithValues: installed.compactMap { record in
                guard record.selectionPolicy == .latest, let item = catalogItem(forInstalledDocset: record),
                      item.entry.advertisedVersion > record.advertisedVersion,
                      let source = sources.first(where: { $0.id == item.sourceConfigurationID }), source.canFetch else { return nil }
                let request: TransferRequest?
                if case .feed = source.kind, let feed = sourceStates[source.id]?.feed {
                    request = .feed(feed, source: source, replacing: record)
                } else { request = try? .catalog(item, replacing: record) }
                guard let request else { return nil }
                return (record.identifier, request)
            })
        }
        return Dictionary(uniqueKeysWithValues: installed.compactMap { record in
            guard let request = DocsetUpdateChecker.availableUpdate(
                for: record,
                catalog: catalog,
                feeds: feeds
            ) else { return nil }
            return (record.identifier, request)
        })
    }

    init(
        preferences: ReaderPreferences = ReaderPreferences(),
        layout: AppDirectoryLayout? = nil,
        catalogClient: (any CatalogClient)? = nil,
        sourceCatalogOverrides: [UUID: any CatalogClient] = [:],
        downloadClient: (any DownloadClient)? = nil,
        feedClient: DashFeedClient = DashFeedClient(),
        usesBackgroundDownloads: Bool = false,
        backgroundDownloadIdentifier: String = AppIdentity.current.backgroundDownloadIdentifier,
        releaseChecker: GitHubReleaseChecker? = nil,
        applicationUpdater: (any ApplicationUpdating)? = nil,
        trashItem: @escaping @Sendable (URL) throws -> Void = { url in
            _ = try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
    ) {
        self.preferences = preferences
        let resolvedLayout = layout ?? AppModel.defaultLayout()
        self.layout = resolvedLayout
        fullTextService = try? FullTextSearchService(databaseURL: resolvedLayout.fullTextIndexURL)
        // Preserve the old test initializer while removing GitHub polling from
        // the app lifecycle. Sparkle now owns discovery and installation.
        self.applicationUpdater = applicationUpdater
        injectedCatalogClient = catalogClient
        self.sourceCatalogOverrides = sourceCatalogOverrides
        injectedDownloadClient = downloadClient
        self.feedClient = feedClient
        self.usesBackgroundDownloads = usesBackgroundDownloads
        self.backgroundDownloadIdentifier = backgroundDownloadIdentifier
        self.trashItem = trashItem
        let token = LocalDocumentServer.makeToken()
        server = LocalDocumentServer(token: token)
        router = DocumentRouter(token: token, roots: [])
        sessionStore = ReaderSessionStore(sessionDirectory: self.layout.sessionDirectory)
    }

    static func defaultLayout(
        identity: AppIdentity = .current,
        applicationSupportBaseDirectory: URL = AppIdentity.applicationSupportBaseDirectory
    ) -> AppDirectoryLayout {
        return AppDirectoryLayout(
            applicationSupportDirectory: identity.applicationSupportDirectory(in: applicationSupportBaseDirectory)
        )
    }

    // MARK: - Lifecycle

    func bootstrap() async {
        guard !bootstrapHasStarted else { return }
        bootstrapHasStarted = true
        isBootstrapping = true
        ensureAtLeastOneTab()
        defer { isBootstrapping = false }
        do {
            try FileManager.default.createDirectory(
                at: layout.defaultDocsetsDirectory,
                withIntermediateDirectories: true
            )
            let registry = try DocsetRegistry(databaseURL: layout.databaseURL)
            self.registry = registry
            librarySettings = try await registry.loadSettings()
            activateStorageAccess()

            if let catalogClient = injectedCatalogClient {
                self.catalogClient = catalogClient
                if let cached = await catalogClient.cachedSnapshot() {
                catalog = cached.entries
                catalogFetchedAt = cached.fetchedAt
                catalogIsFromCache = true
                catalogRequiresArtworkRefresh = cached.requiresArtworkRefresh
                }
            } else {
                // Recover old unscoped journals before changing their registry source association.
                try await DocsetReplacementTransaction(registry: registry, docsetsDirectory: currentDocsetsDirectory, installer: installer).recoverPending()
                let proof = await RemoteCatalogClient(cacheDirectory: layout.cacheDirectory).cachedSnapshot()
                try await registry.initializeSources(legacyCatalogSourceID: proof == nil ? nil : DocsetSourceConfiguration.zealID,
                    legacyCatalogEntries: proof?.entries ?? [])
                if proof != nil {
                    let original = layout.cacheDirectory.appending(path: "catalog.json")
                    let destination = layout.cacheDirectory.appending(path: "sources/\(DocsetSourceConfiguration.zealID.uuidString)/catalog.json")
                    if !FileManager.default.fileExists(atPath: destination.path),
                       (try? original.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])).map({ $0.isRegularFile == true && $0.isSymbolicLink != true }) == true {
                        do {
                            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                            try FileManager.default.copyItem(at: original, to: destination)
                        } catch {
                            libraryNotice = String(localized: "The previous catalog cache could not be migrated. Installed documents remain available.")
                        }
                    }
                }
                let library = SourceLibrary(registry: registry, cacheDirectory: layout.cacheDirectory, catalogOverrides: sourceCatalogOverrides)
                sourceLibrary = library
                try await library.reload()
                synchronizeSourceCatalog()
            }

            let downloadClient = injectedDownloadClient ?? (
                usesBackgroundDownloads
                    ? URLSessionDownloadClient.background(identifier: backgroundDownloadIdentifier)
                    : URLSessionDownloadClient(configuration: .ephemeral)
            )
            let queue = TransferQueue(
                downloadClient: downloadClient,
                installer: installer,
                registry: registry,
                layout: layout
            )
            transferQueue = queue
            await queue.setObserver { [weak self] jobs in
                Task { @MainActor in
                    self?.applyJobs(jobs)
                }
            }
            try await queue.restorePersistedJobs(startQueued: false)

            await reloadInstalled(scanning: true)
            await refreshFullTextStates()
            feeds = (try? await registry.allFeeds()) ?? []

            endpoint = try await server.start()
            await publishRoots()
            await restoreSession()
            resumeInterruptedFullTextIndexes()
            await queue.resumeScheduling()
        } catch {
            startupError = error.localizedDescription
            ensureAtLeastOneTab()
        }
    }

    /// Re-reads the docsets directory, for example after a download or a disk reconnects.
    func refreshLibrary() async {
        await reloadInstalled(scanning: true)
        tabs.forEach { $0.search.refreshForInstalledDocsetsChange() }
    }

    /// Pushes the current docset list and remote-resource policy to the server.
    func publishRoots() async {
        let roots = docsets.map { descriptor in
            DocumentRoot(
                identifier: descriptor.identifier,
                documentsURL: descriptor.documentsURL,
                isJavaScriptEnabled: descriptor.isJavaScriptEnabled,
                allowsRemoteResources: preferences.allowsRemoteResources(forDocset: descriptor.identifier)
            )
        }
        router = DocumentRouter(token: router.token, roots: roots)
        await server.update(roots: roots)
    }

    /// Applies a policy change to the server and reloads open tabs so the new
    /// content security policy takes effect immediately.
    func applyRemoteResourcePolicyChange() async {
        await publishRoots()
        for tab in tabs {
            tab.reload()
        }
    }

    var shouldPresentRemoteResourceNotice: Bool {
        preferences.allowsRemoteResources && !preferences.hasSeenRemoteResourceNotice
    }

    /// Records the first-use privacy decision and applies it to every open tab.
    func resolveRemoteResourceNotice(keepEnabled: Bool) async {
        preferences.hasSeenRemoteResourceNotice = true
        preferences.allowsRemoteResources = keepEnabled
        await applyRemoteResourcePolicyChange()
    }

    func shutdown() async {
        await completedJobsTask?.value
        completedJobsTask = nil
        let pendingSessionSave = sessionSaveTask
        pendingSessionSave?.cancel()
        sessionSaveTask = nil
        saveSessionBeforeTermination()
        scopedStorageURL?.stopAccessingSecurityScopedResource()
        scopedStorageURL = nil
        let indexTasks = Array(fullTextIndexTasks.values)
        indexTasks.forEach { $0.cancel() }
        fullTextIndexTasks = [:]
        for task in indexTasks {
            _ = await task.result
        }
        await pendingSessionSave?.value
        await server.shutdownAndWait()
    }

    // MARK: - Catalog, feeds, transfers

    private func synchronizeSourceCatalog() {
        guard let sourceLibrary else { return }
        catalog = sourceLibrary.entries.map(\.entry)
        feeds = sourceLibrary.feeds
        catalogIsFromCache = sourceLibrary.states.values.contains { $0.isFromCache && !$0.entries.isEmpty }
        catalogFetchedAt = sourceLibrary.states.values.compactMap(\.fetchedAt).max()
    }

    func saveSource(_ source: DocsetSourceConfiguration) async {
        guard let sourceLibrary else { return }
        do {
            try await sourceLibrary.save(source)
            if !source.canFetch { await transferQueue?.cancel(sourceConfigurationID: source.id) }
            synchronizeSourceCatalog()
            libraryError = nil
            if source.canFetch { Task { await self.refreshSource(source) } }
        } catch { libraryError = error.localizedDescription }
    }

    func setSourceEnabled(_ source: DocsetSourceConfiguration, enabled: Bool) async {
        guard let sourceLibrary else { return }
        do {
            var updated = source
            updated.isEnabled = enabled
            try await sourceLibrary.save(updated)
            if !enabled { await transferQueue?.cancel(sourceConfigurationID: source.id) }
            synchronizeSourceCatalog()
            libraryError = nil
            if enabled { Task { await self.refreshSource(updated) } }
        } catch { libraryError = error.localizedDescription }
    }

    func deleteSource(_ source: DocsetSourceConfiguration) async {
        guard let sourceLibrary else { return }
        do {
            try await sourceLibrary.delete(source)
            await transferQueue?.cancel(sourceConfigurationID: source.id)
            synchronizeSourceCatalog()
            libraryError = nil
        } catch { libraryError = error.localizedDescription }
    }

    func refreshSource(_ source: DocsetSourceConfiguration) async {
        await sourceLibrary?.refresh(source)
        synchronizeSourceCatalog()
    }

    func sourceDisplayName(for record: InstalledDocset) -> String {
        let name = rawSourceDisplayName(for: record)
        let id = SourcePresentation.originID(record)
        let collisions = Set(installed.filter { rawSourceDisplayName(for: $0).caseInsensitiveCompare(name) == .orderedSame }
            .map { SourcePresentation.originID($0) })
        return SourcePresentation.distinctOriginName(name, id: id, collidingIDs: collisions,
            deleted: sourceLibrary?.originConfiguration(for: id)?.isDeleted ?? false)
    }

    private func rawSourceDisplayName(for record: InstalledDocset) -> String {
        if record.source == .localImport { return String(localized: "Local Imports") }
        return sourceLibrary?.originName(for: SourcePresentation.originID(record)) ?? record.sourceName ?? String(localized: "Legacy Catalog")
    }

    func docsetDisplayName(for descriptor: DocsetDescriptor) -> String {
        guard showsInstalledSourceNames, let record = installed.first(where: { $0.identifier == descriptor.identifier }) else { return descriptor.displayName }
        return "\(descriptor.displayName)（\(sourceDisplayName(for: record))）"
    }

    func transferDisplayName(for job: TransferJob) -> String {
        guard enabledSourceCount > 1, let source = sourceLibrary?.originName(for: job.sourceConfigurationID) ?? job.sourceName else { return job.displayName }
        return "\(job.displayName)（\(source)）"
    }

    /// Installed provenance does not depend on how many catalogs are currently enabled.
    /// A single enabled origin stays concise; disabled, removed and missing origins remain visible.
    var showsInstalledSourceNames: Bool {
        let originCount = Set(installed.map { SourcePresentation.originID($0) }).count
        if SourcePresentation.showsInstalledSections(enabledSourceCount: enabledSourceCount, groupCount: originCount) {
            return true
        }
        guard sourceLibrary != nil else { return false }
        return installed.contains { record in
            !sources.contains { $0.id == SourcePresentation.originID(record) && $0.canFetch }
        }
    }

    func searchDocsetTitle(for descriptor: DocsetDescriptor) -> String? {
        showsInstalledSourceNames ? docsetDisplayName(for: descriptor) : nil
    }

    func catalogItem(forInstalledDocset record: InstalledDocset) -> SourcedCatalogEntry? {
        if injectedCatalogClient != nil {
            return availableDocsets.first { item in
                if case let .catalog(name, publisher) = record.source { return item.entry.name == name && item.entry.sourceId == publisher }
                return false
            }
        }
        return availableDocsets.first { item in
            guard item.sourceConfigurationID == record.sourceConfigurationID else { return false }
            switch record.source {
            case let .catalog(name, publisher): return item.entry.name == name && item.entry.sourceId == publisher
            case .feed: return item.entry.sourceId == "feed"
            case .localImport: return false
            }
        }
    }

    func installedRecord(for item: SourcedCatalogEntry) -> InstalledDocset? {
        if injectedCatalogClient != nil { return installedRecord(for: item.entry) }
        return installed.first { record in
            guard record.sourceConfigurationID == item.sourceConfigurationID else { return false }
            if case .feed = record.source { return item.entry.sourceId == "feed" }
            if case let .catalog(name, publisher) = record.source { return name == item.entry.name && publisher == item.entry.sourceId }
            return false
        }
    }

    func isTransferring(_ item: SourcedCatalogEntry) -> Bool {
        if injectedCatalogClient != nil { return isTransferring(item.entry) }
        return transferJobs.contains { job in
            job.isActive && job.sourceConfigurationID == item.sourceConfigurationID &&
                (job.kind == .feed || (job.catalogName == item.entry.name && job.catalogSourceId == item.entry.sourceId))
        }
    }

    func installCatalogEntry(_ item: SourcedCatalogEntry, selection: DocsetSelectionPolicy = .latest) async {
        if injectedCatalogClient != nil { await installCatalogEntry(item.entry, selection: selection); return }
        guard let transferQueue else { return }
        do {
            guard let source = sources.first(where: { $0.id == item.sourceConfigurationID }), source.canFetch,
                  let current = availableDocsets.first(where: { $0.id == item.id }), current == item else { throw DocsetSourceError.sourceUnavailable }
            let existing = installedRecord(for: item)
            let request: TransferRequest
            if case .feed = source.kind {
                guard selection == .latest, let feed = sourceStates[source.id]?.feed else { throw CatalogError.versionSelectionUnavailable }
                request = .feed(feed, source: source, replacing: existing)
            } else { request = try .catalog(item, selection: selection, replacing: existing) }
            if let target = request.target, existing?.installTarget == target { return }
            let job = await transferQueue.enqueue(request)
            if case let .failed(message) = job.status { libraryError = message }
            else { libraryError = nil; libraryNotice = nil }
        } catch { libraryError = error.localizedDescription }
    }

    func refreshCatalog() async {
        await refreshCatalog(publishingErrors: true)
    }

    private func refreshCatalog(publishingErrors: Bool) async {
        if let sourceLibrary {
            guard !isRefreshingCatalog else { return }
            isRefreshingCatalog = true
            await sourceLibrary.refreshAll()
            synchronizeSourceCatalog()
            isRefreshingCatalog = false
            return
        }
        guard let catalogClient, !isRefreshingCatalog else { return }
        isRefreshingCatalog = true
        defer { isRefreshingCatalog = false }
        do {
            let snapshot = try await catalogClient.fetch(forceRefresh: true)
            catalog = snapshot.entries
            catalogFetchedAt = snapshot.fetchedAt
            catalogIsFromCache = snapshot.isFromCache
            catalogRequiresArtworkRefresh = snapshot.requiresArtworkRefresh
            if publishingErrors, !snapshot.isFromCache {
                libraryError = nil
            }
        } catch {
            if publishingErrors {
                libraryError = error.localizedDescription
            }
        }
    }

    func refreshCatalogIfNeeded() async {
        guard !hasAttemptedAutomaticCatalogRefresh,
              catalog.isEmpty || catalogRequiresArtworkRefresh else { return }
        hasAttemptedAutomaticCatalogRefresh = true
        await refreshCatalog(publishingErrors: false)
    }

    func downloadCatalogEntries(_ entries: [CatalogEntry]) async {
        for entry in entries where !isInstalled(entry) {
            await installCatalogEntry(entry, selection: .latest)
        }
    }

    /// The caller confirms any replacement before invoking this method. A menu
    /// binding alone must never call it or mutate the installed policy.
    func installCatalogEntry(_ entry: CatalogEntry, selection: DocsetSelectionPolicy = .latest) async {
        guard let transferQueue else { return }
        do {
            let request = try TransferRequest.catalog(entry, selection: selection)
            if let target = request.target {
                guard let current = catalog.first(where: {
                    $0.releaseFamily?.sourceId == target.sourceId && $0.releaseFamily?.familyId == target.familyId
                }), current.releaseFamily?.bundleName == target.bundleName,
                try current.resolve(.pinnedRelease(target.release.id)) == target.release else {
                    throw CatalogError.releaseUnavailable(target.release.id)
                }
            }
            if let target = request.target, installedRecord(for: entry)?.installTarget == target { return }
            let job = await transferQueue.enqueue(request)
            if case let .failed(message) = job.status { libraryError = message }
            else { libraryError = nil; libraryNotice = nil }
        } catch { libraryError = error.localizedDescription }
    }

    func installedRecord(for entry: CatalogEntry) -> InstalledDocset? {
        installed.first { record in
            if let family = entry.releaseFamily {
                return record.installTarget?.sourceId == family.sourceId && record.installTarget?.familyId == family.familyId
            }
            if case let .catalog(name, sourceId) = record.source { return name == entry.name && sourceId == entry.sourceId }
            return false
        }
    }

    func isTransferring(_ entry: CatalogEntry) -> Bool {
        transferJobs.contains { job in
            job.isActive && job.catalogName == entry.name && job.catalogSourceId == entry.sourceId
        }
    }

    func dismissLibraryNotice() { libraryNotice = nil }

    func importDocsets(at urls: [URL]) async {
        guard let transferQueue else { return }
        for url in urls {
            var request = TransferRequest.importing(fileURL: url)
            if sourceLibrary != nil {
                request.sourceConfigurationID = DocsetSourceConfiguration.localID
                request.sourceName = String(localized: "Local Imports")
            }
            _ = await transferQueue.enqueue(request)
        }
    }

    func presentImportPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [
            UTType(filenameExtension: "docset") ?? .directory,
            UTType(filenameExtension: "tgz") ?? .gzip,
            UTType(filenameExtension: "tar") ?? .archive,
            .gzip,
        ]
        panel.prompt = String(localized: "library.action.import")
        guard panel.runModal() == .OK else { return }
        Task { await importDocsets(at: panel.urls) }
    }

    func cancelJob(_ id: UUID) async {
        await transferQueue?.cancel(id)
    }

    func retryJob(_ id: UUID) async {
        await transferQueue?.retry(id)
    }

    func clearFinishedJobs() async {
        await transferQueue?.clearFinished()
    }

    func addFeed(urlString: String) async {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme != nil else {
            libraryError = String(localized: "library.feeds.invalidURL")
            return
        }
        guard let registry else { return }
        do {
            let feed = try await feedClient.fetch(feedURL: url)
            try await registry.saveFeed(feed)
            feeds = try await registry.allFeeds()
            libraryError = nil
        } catch {
            libraryError = error.localizedDescription
        }
    }

    func refreshFeed(_ feed: DashFeed) async {
        guard let registry else { return }
        do {
            let updated = try await feedClient.refresh(feed)
            try await registry.saveFeed(updated)
            feeds = try await registry.allFeeds()
            libraryError = nil
        } catch {
            libraryError = error.localizedDescription
        }
    }

    func refreshAllFeeds() async {
        if sourceLibrary != nil { return }
        for feed in feeds {
            await refreshFeed(feed)
        }
    }

    func deleteFeed(_ feed: DashFeed) async {
        guard let registry else { return }
        do {
            try await registry.deleteFeed(id: feed.id)
            feeds = try await registry.allFeeds()
        } catch {
            libraryError = error.localizedDescription
        }
    }

    func installFeed(_ feed: DashFeed) async {
        guard let transferQueue else { return }
        let request = TransferRequest.feed(feed)
        if await transferQueue.pendingCount(matching: request) == 0 {
            _ = await transferQueue.enqueue(request)
        }
    }

    func checkForUpdates() async {
        await refreshCatalog()
        await refreshAllFeeds()
    }

    func updateDocset(_ record: InstalledDocset) async {
        guard let request = availableUpdates[record.identifier] else { return }
        guard let transferQueue else { return }
        if await transferQueue.pendingCount(matching: request) == 0 {
            _ = await transferQueue.enqueue(request)
        }
    }

    func updateAllDocsets() async {
        for record in installed where availableUpdates[record.identifier] != nil {
            await updateDocset(record)
        }
    }

    func uninstall(_ record: InstalledDocset) async {
        guard let registry, let transferQueue else { return }
        guard await transferQueue.beginLibraryMutation() else {
            libraryError = DocsetReplacementError.slotBusy.localizedDescription
            return
        }
        do {
            guard installed.contains(record) else { throw DocsetReplacementError.conflictingInstall }
            if let indexingTask = fullTextIndexTasks.removeValue(forKey: record.identifier) {
                indexingTask.cancel()
                _ = await indexingTask.result
            }
            fullTextIndexGenerations.removeValue(forKey: record.identifier)
            try await fullTextService?.removeIndex(for: record.identifier)
            if record.isReachable {
                try await installer.uninstall(record.descriptor)
            }
            try await registry.unregister(identifier: record.identifier)
            closeTabs(forDocset: record.identifier)
            fullTextStates.removeValue(forKey: record.identifier)
            await reloadInstalled(scanning: false)
            tabs.forEach { $0.search.refreshForInstalledDocsetsChange() }
            libraryError = nil
        } catch {
            libraryError = error.localizedDescription
        }
        await transferQueue.endLibraryMutation()
    }

    func dismissLibraryError() {
        libraryError = nil
    }

    func selectDocsetSettings(_ section: DocsetsSettingsSection) {
        settingsSelection = .docsets
        docsetsSection = section
    }

    func checkForNewRelease() async {
        applicationUpdater?.checkForUpdates()
    }

    func isInstalled(_ entry: CatalogEntry) -> Bool {
        installedRecord(for: entry) != nil
    }

    func isInstalled(_ feed: DashFeed) -> Bool {
        installed.contains { record in
            if case let .feed(url) = record.source { return url == feed.feedURL }
            return false
        }
    }

    func catalogIconData(forDocset identifier: String) -> Data? {
        guard let record = installed.first(where: { $0.identifier == identifier }) else { return nil }
        if sourceLibrary != nil { return catalogItem(forInstalledDocset: record)?.entry.iconData }
        if case let .catalog(name, sourceID) = record.source,
           let exact = catalog.first(where: { $0.name == name && $0.sourceId == sourceID }) {
            return exact.iconData
        }

        let descriptor = record.descriptor
        let preferredNames = Set([descriptor.displayName, descriptor.name]
            .map(Self.iconMatchKey)
            .filter { !$0.isEmpty })
        if let exact = uniqueCatalogIconData(where: { entry in
            [entry.name, entry.title].map(Self.iconMatchKey).contains(where: preferredNames.contains)
        }) {
            return exact
        }

        let identifier = Self.iconMatchKey(descriptor.identifier)
        if !identifier.isEmpty,
           let identifierMatch = uniqueCatalogIconData(where: { entry in
            [entry.name, entry.title].map(Self.iconMatchKey).contains(identifier)
        }) {
            return identifierMatch
        }

        let filters = Set(descriptor.searchFilters.map(Self.iconMatchKey).filter { !$0.isEmpty })
        return uniqueCatalogIconData { entry in
            entry.keywords.map(Self.iconMatchKey).contains(where: filters.contains)
        }
    }

    private func uniqueCatalogIconData(where predicate: (CatalogEntry) -> Bool) -> Data? {
        var match: Data?
        for entry in catalog where entry.iconData != nil && predicate(entry) {
            guard match == nil else { return nil }
            match = entry.iconData
        }
        return match
    }

    private static func iconMatchKey(_ value: String) -> String {
        value.unicodeScalars
            .filter { scalar in
                CharacterSet.alphanumerics.contains(scalar) || scalar == "+" || scalar == "#"
            }
            .map { Character(String($0).lowercased()) }
            .reduce(into: "") { $0.append($1) }
    }

    // MARK: - Storage

    func presentStorageFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "settings.general.storage.choose")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await migrateStorage(to: url, bookmark: bookmarkData(for: url)) }
    }

    func restoreDefaultStorage() async {
        await migrateStorage(to: layout.defaultDocsetsDirectory, bookmark: nil)
    }

    func trashPendingStorageCopy() {
        let targets = pendingTrashItems
        var failures: [URL] = []
        for target in targets {
            do {
                try trashItem(target)
            } catch {
                failures.append(target)
            }
        }
        pendingTrashItems = failures
        if !failures.isEmpty {
            libraryError = String(localized: "settings.general.storage.trash.failed")
        }
    }

    func dismissPendingTrash() {
        pendingTrashItems = []
    }

    // MARK: - Search

    func enableFullTextSearch(for descriptor: DocsetDescriptor) async {
        guard self.descriptor(for: descriptor.identifier) == descriptor else { return }
        guard let fullTextService else {
            libraryError = String(localized: "fullText.error.unavailable")
            return
        }
        do {
            try await fullTextService.enable(for: descriptor)
            await refreshFullTextState(for: descriptor.identifier)
            await rebuildFullTextIndex(for: descriptor, force: false)
        } catch {
            libraryError = error.localizedDescription
        }
    }

    func rebuildFullTextIndex(for descriptor: DocsetDescriptor, force: Bool = true) async {
        guard let fullTextService, self.descriptor(for: descriptor.identifier) == descriptor else { return }
        let generation = UUID()
        let previousTask = fullTextIndexTasks[descriptor.identifier]
        fullTextIndexGenerations[descriptor.identifier] = generation
        if let previousTask {
            previousTask.cancel()
            _ = await previousTask.result
        }
        guard fullTextIndexGenerations[descriptor.identifier] == generation,
              self.descriptor(for: descriptor.identifier) == descriptor else { return }
        let task = Task { [weak self, fullTextService] in
            try await fullTextService.index(descriptor, forceRebuild: force) { [weak self] progress in
                Task { @MainActor in
                    guard self?.fullTextIndexGenerations[descriptor.identifier] == generation,
                          var state = self?.fullTextStates[progress.docsetIdentifier] else { return }
                    state.phase = .indexing
                    state.indexedDocumentCount = progress.indexedDocumentCount
                    state.totalDocumentCount = progress.totalDocumentCount
                    state.lastIndexedPath = progress.currentPath
                    self?.fullTextStates[progress.docsetIdentifier] = state
                }
            }
        }
        fullTextIndexTasks[descriptor.identifier] = task
        do {
            let state = try await task.value
            guard fullTextIndexGenerations[descriptor.identifier] == generation else { return }
            fullTextStates[descriptor.identifier] = state
            libraryError = nil
            tabs.forEach { $0.search.refreshForInstalledDocsetsChange() }
        } catch is CancellationError {
            guard fullTextIndexGenerations[descriptor.identifier] == generation else { return }
            await refreshFullTextState(for: descriptor.identifier, expectedGeneration: generation)
        } catch {
            guard fullTextIndexGenerations[descriptor.identifier] == generation else { return }
            await refreshFullTextState(for: descriptor.identifier, expectedGeneration: generation)
            guard fullTextIndexGenerations[descriptor.identifier] == generation else { return }
            libraryError = error.localizedDescription
        }
        if fullTextIndexGenerations[descriptor.identifier] == generation {
            fullTextIndexTasks[descriptor.identifier] = nil
            fullTextIndexGenerations[descriptor.identifier] = nil
        }
    }

    func cancelFullTextIndexing(for identifier: String) {
        fullTextIndexTasks[identifier]?.cancel()
    }

    /// Bootstrap is the only caller allowed to replace the entire UI snapshot.
    /// Runtime indexing refreshes merge one docset through the helper below so
    /// concurrent progress for another docset cannot move backwards.
    private func refreshFullTextStates() async {
        guard let fullTextService else { return }
        do {
            fullTextStates = Dictionary(uniqueKeysWithValues: try await fullTextService.allStates().map {
                ($0.docsetIdentifier, $0)
            })
        } catch {
            libraryError = error.localizedDescription
        }
    }

    private func refreshFullTextState(
        for identifier: String,
        expectedGeneration: UUID? = nil
    ) async {
        guard let fullTextService else { return }
        do {
            let state = try await fullTextService.state(for: identifier)
            if let expectedGeneration,
               fullTextIndexGenerations[identifier] != expectedGeneration {
                return
            }
            if let state {
                fullTextStates[identifier] = state
            } else {
                fullTextStates.removeValue(forKey: identifier)
            }
        } catch {
            if let expectedGeneration,
               fullTextIndexGenerations[identifier] != expectedGeneration {
                return
            }
            libraryError = error.localizedDescription
        }
    }

    private func resumeInterruptedFullTextIndexes() {
        for descriptor in docsets {
            guard let state = fullTextStates[descriptor.identifier],
                  state.isEnabled,
                  state.phase == .interrupted || state.phase == .indexing || state.phase == .pending else {
                continue
            }
            Task { await rebuildFullTextIndex(for: descriptor, force: false) }
        }
    }

    // MARK: - Tabs

    @discardableResult
    func openTab(at location: ReaderLocation? = nil) -> ReaderTab {
        let tab = ReaderTab(state: ReaderTabState(location: location), context: self)
        tabs.append(tab)
        selectedTabID = tab.id
        scheduleSessionSave()
        return tab
    }

    func open(_ result: SymbolSearchResult, inNewTab: Bool = false) {
        let location = ReaderLocation(
            docsetIdentifier: result.docsetIdentifier,
            relativePath: result.relativePath,
            fragment: result.fragment,
            title: result.contextName ?? result.docsetName,
            selectedSymbolName: result.name
        )
        open(location, inNewTab: inNewTab)
    }

    func open(_ result: FullTextSearchResult, inNewTab: Bool = false) {
        open(ReaderLocation(
            docsetIdentifier: result.docsetIdentifier,
            relativePath: result.relativePath,
            title: result.title
        ), inNewTab: inNewTab)
    }

    func open(_ location: ReaderLocation, inNewTab: Bool = false) {
        if inNewTab || tabs.isEmpty {
            openTab(at: location)
        } else if let tab = selectedTab ?? tabs.first {
            selectedTabID = tab.id
            tab.navigate(to: location)
        }
        scheduleSessionSave()
    }

    /// Opens a docset's landing page, or its first browsable symbol when the
    /// bundle does not declare one.
    func openLandingPage(for descriptor: DocsetDescriptor) {
        guard let path = descriptor.indexPagePath else { return }
        open(ReaderLocation(
            docsetIdentifier: descriptor.identifier,
            relativePath: path,
            title: descriptor.displayName
        ), inNewTab: tabs.isEmpty)
    }

    func closeTab(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: index)
        if selectedTabID == id {
            selectedTabID = tabs[max(0, index - 1)...].first?.id ?? tabs.last?.id
        }
        if tabs.isEmpty {
            openTab()
        }
        scheduleSessionSave()
    }

    func goHome(in tab: ReaderTab) {
        tab.resetToWelcome()
        selectedTabID = tab.id
        scheduleSessionSave()
    }

    func selectNextTab(offset: Int) {
        guard !tabs.isEmpty, let current = tabs.firstIndex(where: { $0.id == selectedTabID }) else { return }
        let next = (current + offset + tabs.count) % tabs.count
        selectedTabID = tabs[next].id
    }

    // MARK: - Session

    private func restoreSession() async {
        guard preferences.restoresLastSession else {
            await sessionStore.clear()
            tabs = []
            selectedTabID = nil
            ensureAtLeastOneTab()
            return
        }

        let installed = Set(docsets.map(\.identifier))
        let restored = await sessionStore.load().pruned(keepingDocsets: installed)
        tabs = restored.tabs.map { ReaderTab(state: $0, context: self) }
        selectedTabID = restored.selectedTabID ?? tabs.first?.id
        ensureAtLeastOneTab()
    }

    /// Coalesces rapid navigation into a single write.
    func scheduleSessionSave() {
        sessionSaveTask?.cancel()
        sessionSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await self?.saveSessionNow()
        }
    }

    func saveSessionNow() async {
        guard preferences.restoresLastSession else {
            await sessionStore.clear()
            return
        }
        try? await sessionStore.save(currentSessionState)
    }

    /// Termination cannot wait on an actor, so the last write is done inline.
    func saveSessionBeforeTermination() {
        let fileURL = ReaderSessionStore.fileURL(in: layout.sessionDirectory)
        guard preferences.restoresLastSession else {
            ReaderSessionStore.remove(at: fileURL)
            return
        }
        try? ReaderSessionStore.write(currentSessionState, to: fileURL)
    }

    private var currentSessionState: ReaderSessionState {
        ReaderSessionState(tabs: tabs.map(\.state), selectedTabID: selectedTabID)
    }

    // MARK: - ReaderDocumentContext

    func url(for location: ReaderLocation) -> URL? {
        guard let endpoint else { return nil }
        return router.url(
            host: endpoint.host,
            port: endpoint.port,
            docsetIdentifier: location.docsetIdentifier,
            relativePath: location.relativePath,
            fragment: location.fragment
        )
    }

    func location(for url: URL) -> ReaderLocation? {
        guard let endpoint,
              url.host() == endpoint.host,
              url.port == Int(endpoint.port) else {
            return nil
        }
        return router.location(for: url)
    }

    func isJavaScriptEnabled(forDocset identifier: String) -> Bool {
        docsets.first { $0.identifier == identifier }?.isJavaScriptEnabled ?? false
    }

    func searchableDocsets(matching identifier: String?) -> [DocsetDescriptor] {
        guard let identifier else { return docsets }
        return docsets.filter { $0.identifier == identifier }
    }

    func searchFullText(
        _ query: String,
        in docsets: [DocsetDescriptor],
        limit: Int
    ) async throws -> [FullTextSearchResult] {
        try await fullTextService?.search(query, in: docsets, limit: limit) ?? []
    }

    func openDocument(_ location: ReaderLocation, inNewTab: Bool) {
        open(location, inNewTab: inNewTab)
    }

    func openExternalURL(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    func descriptor(for identifier: String) -> DocsetDescriptor? {
        docsets.first { $0.identifier == identifier }
    }

    /// Returns the stable on-disk page URL rather than the per-launch loopback
    /// URL, whose random access token intentionally expires at quit.
    func sourceURL(for location: ReaderLocation) -> URL? {
        guard let descriptor = descriptor(for: location.docsetIdentifier) else { return nil }
        let components = location.relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !location.relativePath.hasPrefix("/"),
              !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            return nil
        }
        let documentsRoot = descriptor.documentsURL.resolvingSymlinksInPath().standardizedFileURL
        let pageURL = descriptor.documentsURL
            .appending(path: location.relativePath, directoryHint: .notDirectory)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard pageURL.path.hasPrefix(documentsRoot.path + "/") else { return nil }
        guard var components = URLComponents(url: pageURL, resolvingAgainstBaseURL: false) else { return nil }
        components.fragment = location.fragment
        return components.url
    }

    @discardableResult
    func copyCurrentPageLink(to pasteboard: NSPasteboard = .general) -> Bool {
        guard let location = selectedTab?.currentLocation,
              let pageURL = sourceURL(for: location) else {
            return false
        }
        pasteboard.clearContents()
        return pasteboard.setString(pageURL.absoluteString, forType: .string)
    }

    func revealDocsetsDirectoryInFinder() {
        let directory = currentDocsetsDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([directory])
    }

    // MARK: - Private

    private func reloadInstalled(scanning: Bool) async {
        guard let registry else { return }
        do {
            let active = await transferQueue?.snapshot ?? []
            let installing = active.contains { if case .installing = $0.status { return true }; return false }
            if scanning && !installing {
                let report = try await registry.scanAndRegister(docsetsDirectory: currentDocsetsDirectory, assignRuntimeIDs: sourceLibrary != nil)
                scanFailures = report.failures
            }
            installed = try await registry.allInstalled()
            docsets = installed.filter(\.isReachable).map(\.descriptor)
            await publishRoots()
        } catch {
            libraryError = error.localizedDescription
        }
    }

    private func applyJobs(_ jobs: [TransferJob]) {
        transferJobs = jobs
        let completed = Set(jobs.compactMap { job -> UUID? in
            if case .completed = job.status { return job.id }
            return nil
        })
        let newlyCompleted = completed.subtracting(handledCompletedJobIDs)
        handledCompletedJobIDs = completed
        guard !newlyCompleted.isEmpty else { return }
        let completedIdentifiers = Set(jobs.compactMap { job -> String? in
            guard newlyCompleted.contains(job.id),
                  case let .completed(identifier) = job.status else { return nil }
            return identifier
        })
        // Invalidate old progress/completion callbacks synchronously, before
        // any await can publish a stale generation over a replaced bundle.
        let oldIndexTasks = completedIdentifiers.compactMap { identifier -> Task<FullTextIndexState, any Error>? in
            fullTextIndexGenerations[identifier] = UUID()
            let task = fullTextIndexTasks.removeValue(forKey: identifier)
            task?.cancel()
            return task
        }
        let previousCompletion = completedJobsTask
        completedJobsTask = Task {
            await previousCompletion?.value
            for task in oldIndexTasks { _ = await task.result }
            await reloadInstalled(scanning: false)
            tabs.forEach { $0.search.refreshForInstalledDocsetsChange() }
            for tab in tabs {
                guard let location = tab.currentLocation, completedIdentifiers.contains(location.docsetIdentifier),
                      let descriptor = descriptor(for: location.docsetIdentifier) else { continue }
                if let source = sourceURL(for: location),
                   (try? source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                    tab.reload()
                } else {
                    if let home = descriptor.indexPagePath {
                        tab.navigate(to: ReaderLocation(docsetIdentifier: descriptor.identifier, relativePath: home))
                    } else { tab.resetToWelcome() }
                    libraryNotice = String(localized: "library.version.pageMissing")
                }
            }
            scheduleSessionSave()
            for descriptor in docsets where completedIdentifiers.contains(descriptor.identifier)
                && fullTextStates[descriptor.identifier]?.isEnabled == true {
                await rebuildFullTextIndex(for: descriptor, force: false)
            }
        }
    }

    private func closeTabs(forDocset identifier: String) {
        let remaining = tabs.filter { $0.currentLocation?.docsetIdentifier != identifier }
        if remaining.count != tabs.count {
            tabs = remaining
            if selectedTabID.map({ id in remaining.contains { $0.id == id } }) != true {
                selectedTabID = remaining.first?.id
            }
            if tabs.isEmpty { openTab() }
            scheduleSessionSave()
        }
    }

    private func ensureAtLeastOneTab() {
        guard tabs.isEmpty else { return }
        let tab = ReaderTab(state: ReaderTabState(), context: self)
        tabs = [tab]
        selectedTabID = tab.id
    }

    private func activateStorageAccess() {
        scopedStorageURL?.stopAccessingSecurityScopedResource()
        scopedStorageURL = nil
        guard let data = librarySettings.bookmarkData else { return }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return }
        guard url.startAccessingSecurityScopedResource() else { return }
        scopedStorageURL = url
        if isStale, let fresh = bookmarkData(for: url) {
            librarySettings.bookmarkData = fresh
            Task { try? await registry?.saveSettings(librarySettings) }
        }
    }

    private func bookmarkData(for url: URL) -> Data? {
        try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    private func migrateStorage(to destination: URL, bookmark: Data?) async {
        guard let registry else { return }
        let source = currentDocsetsDirectory
        do {
            let records = try await registry.allInstalled()
            let (relocated, report) = try await migrator.migrate(
                records: records,
                from: source,
                to: destination,
                trashSourceAfterSwitch: false
            )
            let newSettings = LibrarySettings(
                customDocsetsPath: destination == layout.defaultDocsetsDirectory ? nil : destination.path,
                bookmarkData: destination == layout.defaultDocsetsDirectory ? nil : bookmark
            )
            try await registry.applyStorageMigration(records: relocated, settings: newSettings)
            librarySettings = newSettings
            activateStorageAccess()
            await reloadInstalled(scanning: true)
            if !report.copied.isEmpty, source != destination {
                pendingTrashItems = report.sourceItemsEligibleForTrash
            }
            libraryError = nil
        } catch {
            libraryError = error.localizedDescription
        }
    }
}
