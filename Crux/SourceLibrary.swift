import CruxCore
import Foundation
import Observation

/// Settings-facing state. Endpoint/cache/network policy stays in CruxCore's coordinator.
@MainActor @Observable
final class SourceLibrary {
    private(set) var configurations: [DocsetSourceConfiguration] = []
    private(set) var states: [UUID: SourceRefreshState] = [:]
    private(set) var entries: [SourcedCatalogEntry] = []
    private var origins: [UUID: DocsetSourceConfiguration] = [:]
    @ObservationIgnored private let registry: DocsetRegistry
    @ObservationIgnored private let coordinator: DocsetSourceCoordinator

    init(registry: DocsetRegistry, cacheDirectory: URL, catalogOverrides: [UUID: any CatalogClient] = [:]) {
        self.registry = registry
        coordinator = DocsetSourceCoordinator(cacheDirectory: cacheDirectory, catalogOverrides: catalogOverrides)
    }
    var enabledCount: Int { configurations.filter(\.canFetch).count }
    var feeds: [DashFeed] { states.values.compactMap(\.feed) }
    var isRefreshing: Bool { states.values.contains(where: \.isRefreshing) }

    func reload() async throws {
        let all = try await registry.allSources()
        origins = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        configurations = all.filter { !$0.isDeleted }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        await coordinator.setSources(try await registry.allSources())
        await synchronize()
    }

    func originName(for id: UUID?) -> String? { id.flatMap { origins[$0]?.name } }
    func originConfiguration(for id: UUID) -> DocsetSourceConfiguration? { origins[id] }

    func refresh(_ source: DocsetSourceConfiguration) async {
        guard configurations.contains(source), source.canFetch else { return }
        states[source.id, default: SourceRefreshState()].isRefreshing = true
        await coordinator.refresh(source.id)
        await synchronize()
    }

    func refreshAll() async {
        let enabled = configurations.filter(\.canFetch)
        let coordinator = self.coordinator
        for source in enabled { states[source.id, default: SourceRefreshState()].isRefreshing = true }
        await withTaskGroup(of: UUID.self) { group in
            for source in enabled {
                let id = source.id
                group.addTask { await coordinator.refresh(id); return id }
            }
            for await _ in group { await synchronize() }
        }
    }

    func save(_ source: DocsetSourceConfiguration) async throws {
        try await registry.saveSource(source)
        try await reload()
    }

    func delete(_ source: DocsetSourceConfiguration) async throws {
        try await registry.deleteSource(id: source.id)
        try await reload()
    }

    private func synchronize() async {
        states = await coordinator.states()
        entries = await coordinator.availableEntries()
    }
}
