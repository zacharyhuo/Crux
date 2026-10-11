import CruxCore
import Foundation
import SQLite3
import Testing
@testable import Crux

@MainActor struct MultiSourceSearchTests {
    @Test func ambiguousPrefixWaitsForExplicitSourceSelection() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "CruxPrefixTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = try DocsetRegistry(databaseURL: root.appending(path: "library.sqlite"))
        let a = try await registry.register(bundleAt: makeBundle(root: root, directory: "A"))
        let b = try await registry.register(bundleAt: makeBundle(root: root, directory: "B"))
        let context = PrefixSearchContext(docsets: [a, b])
        let search = TabSearchState(context: context)
        search.updateQuery("py:")
        #expect(search.scopedDocsetIdentifier == nil)
        #expect(search.query == "py:")
        #expect(search.currentRoute == .docsets)
        search.reset()
        #expect(search.prefixChoiceIdentifiers.isEmpty)
        search.updateQuery("py:")
        search.showDocset(b.identifier)
        #expect(search.scopedDocsetIdentifier == b.identifier)
        #expect(search.query.isEmpty)
        #expect(search.scopeFocusRequest > 0)
        let deadline = ContinuousClock.now + .seconds(3)
        while search.isBrowsing {
            guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(5))
        }
        search.reset()
    }

    private func makeBundle(root: URL, directory: String) throws -> URL {
        let bundle = root.appending(path: "\(directory).docset")
        let resources = bundle.appending(path: "Contents/Resources")
        try FileManager.default.createDirectory(at: resources.appending(path: "Documents"), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "dev.fixture.Python", "CFBundleName": "Python", "DashDocSetKeyword": "py"], format: .xml, options: 0)
            .write(to: bundle.appending(path: "Contents/Info.plist"))
        var handle: OpaquePointer?
        guard sqlite3_open(resources.appending(path: "docSet.dsidx").path, &handle) == SQLITE_OK, let db = handle else { throw CocoaError(.fileWriteUnknown) }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, "CREATE TABLE searchIndex(id INTEGER PRIMARY KEY, name TEXT, type TEXT, path TEXT)", nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        return bundle
    }
}

@MainActor private final class PrefixSearchContext: TabSearchContext {
    let symbolSearchService = SymbolSearchService()
    let docsets: [DocsetDescriptor]
    init(docsets: [DocsetDescriptor]) { self.docsets = docsets }
    func searchableDocsets(matching identifier: String?) -> [DocsetDescriptor] { docsets.filter { identifier == nil || $0.identifier == identifier } }
    func searchFullText(_ query: String, in docsets: [DocsetDescriptor], limit: Int) async throws -> [FullTextSearchResult] { [] }
}
