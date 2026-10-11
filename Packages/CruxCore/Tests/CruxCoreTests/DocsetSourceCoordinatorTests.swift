import Foundation
import Testing
@testable import CruxCore

struct DocsetSourceCoordinatorTests {
    @Test func disablingSourceRejectsAnUncooperativeLateFetch() async throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = SuspendedSourceCatalog()
        var source = DocsetSourceConfiguration(name: "Test", kind: .zeal(catalogURL: URL(string: "https://test.invalid/catalog")!, downloadRootURL: URL(string: "https://test.invalid/d")!))
        let coordinator = DocsetSourceCoordinator(cacheDirectory: root, catalogOverrides: [source.id: client])
        await coordinator.setSources([source])
        let id = source.id
        let refresh = Task { await coordinator.refresh(id) }
        while !(await client.hasStarted) { await Task.yield() }
        source.isEnabled = false
        await coordinator.setSources([source])
        await client.complete()
        await refresh.value
        #expect(await coordinator.availableEntries().isEmpty)
        #expect(await coordinator.states()[source.id]?.isRefreshing == false)
    }
}

private actor SuspendedSourceCatalog: CatalogClient {
    var hasStarted = false
    var continuation: CheckedContinuation<CatalogSnapshot, Never>?
    func fetch(forceRefresh: Bool) async throws -> CatalogSnapshot {
        hasStarted = true
        return await withCheckedContinuation { continuation = $0 }
    }
    func cachedSnapshot() async -> CatalogSnapshot? { nil }
    func complete() {
        continuation?.resume(returning: CatalogSnapshot(entries: [CatalogEntry(name: "Python", title: "Python", sourceId: "com.kapeli", version: "3.14", revision: 1, downloadURL: URL(string: "https://test.invalid/d/Python")!, keywords: ["py"])], fetchedAt: Date(), isFromCache: false))
        continuation = nil
    }
}
