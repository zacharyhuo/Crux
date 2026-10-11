import Foundation

public struct SourceRefreshState: Equatable, Sendable {
    public var isRefreshing = false
    public var message: String?
    public var fetchedAt: Date?
    public var isFromCache = false
    public var entries: [CatalogEntry] = []
    public var feed: DashFeed?
    public init() {}
}

/// Independent caches and generation fences: a stopped source cannot return through a late response.
public actor DocsetSourceCoordinator {
    private let cacheDirectory: URL
    private let catalogOverrides: [UUID: any CatalogClient]
    private var sources: [UUID: DocsetSourceConfiguration] = [:]
    private var clients: [UUID: any CatalogClient] = [:]
    private var snapshots: [UUID: SourceRefreshState] = [:]
    private var generations: [UUID: UUID] = [:]
    private var tasks: [UUID: Task<SourceRefreshState, Never>] = [:]

    public init(cacheDirectory: URL, catalogOverrides: [UUID: any CatalogClient] = [:]) {
        self.cacheDirectory = cacheDirectory
        self.catalogOverrides = catalogOverrides
    }

    public func setSources(_ configurations: [DocsetSourceConfiguration]) async {
        let oldSources = sources
        let incoming = Dictionary(uniqueKeysWithValues: configurations.map { ($0.id, $0) })
        for id in sources.keys where incoming[id] != sources[id] {
            generations[id] = UUID()
            tasks[id]?.cancel(); tasks[id] = nil
            snapshots[id]?.isRefreshing = false
        }
        sources = incoming
        for source in configurations {
            let isNew = oldSources[source.id] == nil
            if generations[source.id] == nil { generations[source.id] = UUID() }
            guard isNew else { continue }
            if let provider = source.catalogProvider {
                let client = catalogOverrides[source.id] ?? RemoteCatalogClient(provider: provider,
                    cacheDirectory: directory(for: source.id), transportPolicy: source.transportPolicy)
                clients[source.id] = client
                let generation = generations[source.id]
                if let cached = await client.cachedSnapshot(), generations[source.id] == generation {
                    snapshots[source.id] = state(from: cached)
                }
            } else if case .feed = source.kind,
                      let data = try? Data(contentsOf: directory(for: source.id).appending(path: "feed.json")),
                      let feed = try? JSONDecoder().decode(DashFeed.self, from: data),
                      feed.feedURL == source.endpointURL,
                      (try? source.transportPolicy.validate(feed.downloadURL)) != nil {
                snapshots[source.id] = state(from: feed, cached: true)
            }
            if snapshots[source.id] == nil { snapshots[source.id] = SourceRefreshState() }
        }
    }

    public func states() -> [UUID: SourceRefreshState] { snapshots }

    public func availableEntries() -> [SourcedCatalogEntry] {
        sources.values.filter(\.canFetch).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .flatMap { source in (snapshots[source.id]?.entries ?? []).map { SourcedCatalogEntry(source: source, entry: $0) } }
    }

    public func refresh(_ id: UUID) async {
        guard let source = sources[id], source.canFetch, snapshots[id]?.isRefreshing != true else { return }
        let generation = generations[id]
        var previous = snapshots[id] ?? SourceRefreshState()
        previous.isRefreshing = true
        snapshots[id] = previous
        let client = clients[id]
        let directory = directory(for: id)
        let task = Task<SourceRefreshState, Never> {
            do {
                try source.validate()
                if let client {
                    let snapshot = try await client.fetch(forceRefresh: true)
                    var result = SourceRefreshState()
                    result.entries = snapshot.entries
                    result.fetchedAt = snapshot.fetchedAt
                    result.isFromCache = snapshot.isFromCache
                    if snapshot.isFromCache { result.message = "Using the last successful catalog; refresh did not succeed." }
                    return result
                }
                if case let .feed(url) = source.kind {
                    let fetched = try await DashFeedClient(transportPolicy: source.transportPolicy).fetch(feedURL: url)
                    let feed = DashFeed(id: id, feedURL: url, name: fetched.name, version: fetched.version,
                                        revision: fetched.revision, downloadURL: fetched.downloadURL)
                    try Task.checkCancellation()
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try JSONEncoder().encode(feed).write(to: directory.appending(path: "feed.json"), options: .atomic)
                    return Self.feedState(feed, cached: false)
                }
                throw DocsetSourceError.sourceUnavailable
            } catch {
                var result = previous
                result.isRefreshing = false
                result.isFromCache = !result.entries.isEmpty
                result.message = source.id == DocsetSourceConfiguration.cruxID && error.localizedDescription.contains("404")
                    ? "Crux Docset is not anonymously accessible yet (the repository may still be private)."
                    : error.localizedDescription
                return result
            }
        }
        tasks[id] = task
        let result = await task.value
        guard generations[id] == generation, sources[id]?.canFetch == true else { return }
        snapshots[id] = result
        tasks[id] = nil
    }

    public func refreshEnabled() async {
        let ids = sources.values.filter(\.canFetch).map(\.id)
        await withTaskGroup(of: Void.self) { group in
            for id in ids { group.addTask { await self.refresh(id) } }
        }
    }

    private func directory(for id: UUID) -> URL { cacheDirectory.appending(path: "sources/\(id.uuidString)", directoryHint: .isDirectory) }
    private func state(from snapshot: CatalogSnapshot) -> SourceRefreshState {
        var result = SourceRefreshState()
        result.entries = snapshot.entries; result.fetchedAt = snapshot.fetchedAt; result.isFromCache = true
        return result
    }
    private func state(from feed: DashFeed, cached: Bool) -> SourceRefreshState { Self.feedState(feed, cached: cached) }
    private static func feedState(_ feed: DashFeed, cached: Bool) -> SourceRefreshState {
        var result = SourceRefreshState()
        result.feed = feed; result.fetchedAt = cached ? nil : Date(); result.isFromCache = cached
        result.entries = [CatalogEntry(name: feed.id.uuidString, title: feed.name, sourceId: "feed", version: feed.version,
            revision: feed.revision, downloadURL: feed.downloadURL, keywords: [])]
        return result
    }
}
