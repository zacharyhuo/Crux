import Foundation
import Testing

@testable import CruxCore

struct SymbolSearchTests {
    @Test
    func nestedGroupingNeverCrossesDocsetOrTypeAndRequiresDifferentLocations() {
        let shared = SearchResult(
            name: "ReadableStream",
            type: "Class",
            relativePath: "globals.html",
            fragment: "ReadableStream",
            documentURL: URL(fileURLWithPath: "/tmp/globals.html"),
            docsetIdentifier: "node",
            docsetName: "Node.js",
            contextName: "globals",
            matchKind: .exact,
            matchPositions: []
        )
        let alternate = SearchResult(
            name: "readablestream",
            type: "class",
            relativePath: "webstreams.html",
            fragment: "ReadableStream",
            documentURL: URL(fileURLWithPath: "/tmp/webstreams.html"),
            docsetIdentifier: "node",
            docsetName: "Node.js",
            contextName: "webstreams",
            matchKind: .exact,
            matchPositions: []
        )
        let otherType = SearchResult(
            name: "ReadableStream",
            type: "Method",
            relativePath: "method.html",
            fragment: nil,
            documentURL: URL(fileURLWithPath: "/tmp/method.html"),
            docsetIdentifier: "node",
            docsetName: "Node.js",
            contextName: "stream",
            matchKind: .exact,
            matchPositions: []
        )
        let otherDocset = SearchResult(
            name: "ReadableStream",
            type: "Class",
            relativePath: "class.html",
            fragment: nil,
            documentURL: URL(fileURLWithPath: "/tmp/class.html"),
            docsetIdentifier: "browser",
            docsetName: "Browser",
            contextName: nil,
            matchKind: .exact,
            matchPositions: []
        )

        let grouped = [shared, shared, alternate, otherType, otherDocset].nestedResultGroups()

        #expect(grouped.count == 3)
        #expect(grouped[0].results == [shared, alternate])
        #expect(grouped[0].similarResultCount == 2)
        #expect(grouped[1].results == [otherType])
        #expect(grouped[2].results == [otherDocset])
    }

    @Test
    func ranksExactPrefixSubstringAndFuzzyMatchesDeterministically() async throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try TestDocsetFixture.create(
            in: root,
            symbols: [
                TestSymbol("NSString", type: "cl", path: "nsstring.html"),
                TestSymbol("StringBuilder", type: "cl", path: "builder.html"),
                TestSymbol("String", type: "cl", path: "string.html"),
                TestSymbol("Strong", type: "cl", path: "strong.html"),
            ]
        )
        let descriptor = try DocsetParser().parse(bundleAt: bundle)
        let service = SymbolSearchService()

        let stringResults = try await service.search("python,class:string", in: [descriptor])
        #expect(stringResults.map(\.name) == ["String", "StringBuilder", "NSString"])
        #expect(stringResults.map(\.matchKind) == [.exact, .prefix, .substring])
        #expect(stringResults.allSatisfy { $0.type == "Class" })

        let fuzzyResults = try await service.search("strng", in: [descriptor])
        #expect(fuzzyResults.first?.name == "String")
        #expect(fuzzyResults.first?.matchKind == .fuzzy)
        #expect(fuzzyResults.first?.matchPositions == [0, 1, 2, 4, 5])
    }

    @Test
    func filtersAcrossDocsetsUsingNamesAndAliases() async throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let python = try TestDocsetFixture.create(
            in: root,
            name: "Python",
            symbols: [TestSymbol("render", type: "Function", path: "python-render.html")]
        )
        let django = try TestDocsetFixture.create(
            in: root,
            name: "Django",
            identifier: "org.djangoproject.Django",
            symbols: [TestSymbol("render", type: "Function", path: "django-render.html")]
        )
        let descriptors = try [python, django].map { try DocsetParser().parse(bundleAt: $0) }
        let service = SymbolSearchService()

        let pythonOnly = try await service.search("py:render", in: descriptors)
        let both = try await service.search("python,django:render", in: descriptors)

        #expect(pythonOnly.map(\.docsetName) == ["Python"])
        #expect(both.map(\.docsetName) == ["Django", "Python"])
    }

    @Test
    func browsesEmptyQueriesAlphabeticallyAndHonorsTheGlobalLimit() async throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try TestDocsetFixture.create(
            in: root,
            symbols: [
                TestSymbol("Zulu", type: "Class", path: "z.html"),
                TestSymbol("Alpha", type: "Class", path: "a.html"),
                TestSymbol("Beta", type: "Class", path: "b.html"),
            ]
        )
        let descriptor = try DocsetParser().parse(bundleAt: bundle)

        let results = try await SymbolSearchService().search("", in: [descriptor], limit: 2)

        #expect(results.map(\.name) == ["Alpha", "Beta"])
        #expect(results.allSatisfy { $0.matchKind == .browse })
    }

    @Test
    func appliesTypeFiltersBeforeLimitingBrowseResults() async throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try TestDocsetFixture.create(
            in: root,
            symbols: [
                TestSymbol("AlphaClass", type: "cl", path: "class.html"),
                TestSymbol("ZuluFunction", type: "func", path: "function.html"),
            ]
        )
        let descriptor = try DocsetParser().parse(bundleAt: bundle)

        let results = try await SymbolSearchService().search(
            "function:",
            in: [descriptor],
            limit: 1
        )

        #expect(results.map(\.name) == ["ZuluFunction"])
        #expect(results.first?.type == "Function")
    }

    @Test
    func readsLegacyZDashPathsAndFragments() async throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try TestDocsetFixture.create(
            in: root,
            schema: .zDash,
            symbols: [TestSymbol(
                "AnchorThing",
                type: "Method",
                path: "anchor.html",
                fragment: "method",
                container: "LegacyContainer"
            )]
        )
        let descriptor = try DocsetParser().parse(bundleAt: bundle)

        let result = try #require(try await SymbolSearchService().search("AnchorThing", in: [descriptor]).first)

        #expect(result.relativePath == "anchor.html")
        #expect(result.fragment == "method")
        #expect(result.documentURL.path.hasSuffix("/Documents/anchor.html"))
        #expect(result.documentURL.fragment == "method")
        #expect(result.contextName == "LegacyContainer")
    }

    @Test
    func derivesModernContextsFromDocumentPathsAndSummarizesNormalizedTypes() async throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try TestDocsetFixture.create(
            in: root,
            symbols: [
                TestSymbol("ReadableStream", type: "cl", path: "nodejs/api/webstreams.html"),
                TestSymbol("WritableStream", type: "classes", path: "nodejs/api/globals.html"),
                TestSymbol("read", type: "instm", path: "nodejs/api/stream.html"),
            ]
        )
        let descriptor = try DocsetParser().parse(bundleAt: bundle)
        let service = SymbolSearchService()

        let result = try #require(try await service.search("ReadableStream", in: [descriptor]).first)
        let summaries = try await service.symbolTypeSummaries(in: descriptor)

        #expect(result.contextName == "webstreams")
        #expect(summaries == [
            SymbolTypeSummary(type: "Class", count: 2),
            SymbolTypeSummary(type: "Method", count: 1),
        ])
    }

    @Test
    func preservesUnknownSymbolTypeCasing() async throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try TestDocsetFixture.create(
            in: root,
            symbols: [TestSymbol("Accept", type: "HTTP Header", path: "accept.html")]
        )
        let descriptor = try DocsetParser().parse(bundleAt: bundle)

        let result = try #require(
            try await SymbolSearchService().search("Accept", in: [descriptor]).first
        )

        #expect(result.type == "HTTP Header")
    }

    @Test
    func reopensTheIndexWhenARegisteredVersionReplacesTheSamePath() async throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let oldBundle = try TestDocsetFixture.create(
            in: root,
            version: "3.13",
            revision: 1,
            symbols: [TestSymbol("OldSymbol", type: "Class", path: "old.html")]
        )
        let oldDescriptor = try DocsetParser().parse(bundleAt: oldBundle)
        let service = SymbolSearchService()
        #expect(try await service.search("OldSymbol", in: [oldDescriptor]).map(\.name) == ["OldSymbol"])

        try FileManager.default.removeItem(at: oldBundle)
        let newBundle = try TestDocsetFixture.create(
            in: root,
            version: "3.14",
            revision: 2,
            symbols: [TestSymbol("NewSymbol", type: "Class", path: "new.html")]
        )
        let newDescriptor = try DocsetParser().parse(bundleAt: newBundle)

        #expect(try await service.search("NewSymbol", in: [newDescriptor]).map(\.name) == ["NewSymbol"])
        #expect(try await service.search("OldSymbol", in: [newDescriptor]).isEmpty)
    }

    @Test
    func keepsExactMatchesAheadOfTheCandidateLimit() async throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fuzzySymbols = (0..<1_000).map { index in
            TestSymbol("a-long-broad-candidate-\(index)", type: "Class", path: "fuzzy/\(index).html")
        }
        let bundle = try TestDocsetFixture.create(
            in: root,
            symbols: fuzzySymbols + [TestSymbol("abc", type: "Class", path: "exact.html")],
            writeSymbolDocuments: false
        )
        let descriptor = try DocsetParser().parse(bundleAt: bundle)

        let results = try await SymbolSearchService().search("abc", in: [descriptor], limit: 1)

        #expect(results.map(\.name) == ["abc"])
        #expect(results.first?.matchKind == .exact)
    }

    @Test
    func rejectsSymbolPathsThatEscapeThroughASymlink() async throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try TestDocsetFixture.create(
            in: root,
            symbols: [TestSymbol("Secret", type: "Class", path: "escape/secret.html")]
        )
        let documentsURL = bundle.appending(path: "Contents/Resources/Documents")
        let escapeURL = documentsURL.appending(path: "escape")
        let outsideURL = root.appending(path: "outside", directoryHint: .isDirectory)
        try FileManager.default.removeItem(at: escapeURL)
        try FileManager.default.createDirectory(at: outsideURL, withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: outsideURL.appending(path: "secret.html"))
        try FileManager.default.createSymbolicLink(at: escapeURL, withDestinationURL: outsideURL)
        let descriptor = try DocsetParser().parse(bundleAt: bundle)

        let results = try await SymbolSearchService().search("Secret", in: [descriptor])

        #expect(results.isEmpty)
    }

    @Test
    func aNewDebouncedQueryCancelsThePreviousOne() async throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try TestDocsetFixture.create(
            in: root,
            symbols: [
                TestSymbol("First", type: "Class", path: "first.html"),
                TestSymbol("Second", type: "Class", path: "second.html"),
            ]
        )
        let descriptor = try DocsetParser().parse(bundleAt: bundle)
        let coordinator = SearchCoordinator(service: SymbolSearchService())

        let first = Task {
            try await coordinator.search("First", in: [descriptor], debounce: .milliseconds(200))
        }
        try await Task.sleep(for: .milliseconds(20))
        let second = try await coordinator.search("Second", in: [descriptor], debounce: .zero)

        await #expect(throws: CancellationError.self) {
            try await first.value
        }
        #expect(second.map(\.name) == ["Second"])
    }

    @Test
    func cancellingOneCoordinatorDoesNotInterruptAnotherUsingTheSharedIndex() async throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var symbols = (0..<2_000).map {
            TestSymbol("SharedSymbol\($0)", type: "Class", path: "shared.html")
        }
        symbols.append(TestSymbol("Needle", type: "Class", path: "needle.html"))
        let bundle = try TestDocsetFixture.create(
            in: root,
            symbols: symbols,
            writeSymbolDocuments: false
        )
        let descriptor = try DocsetParser().parse(bundleAt: bundle)
        let service = SymbolSearchService()
        let firstCoordinator = SearchCoordinator(service: service)
        let secondCoordinator = SearchCoordinator(service: service)

        let cancelled = Task {
            try await firstCoordinator.search("SharedSymbol", in: [descriptor], limit: 2_000, debounce: .zero)
        }
        await Task.yield()
        let surviving = Task {
            try await secondCoordinator.search("Needle", in: [descriptor], debounce: .zero)
        }
        await firstCoordinator.cancel()

        _ = try? await cancelled.value
        #expect(try await surviving.value.map(\.name) == ["Needle"])
    }

    @Test
    func suppressesAnObsoleteResultEvenWhenTheServiceIgnoresCancellation() async throws {
        let coordinator = SearchCoordinator(service: CancellationIgnoringSearchService())

        let first = Task {
            try await coordinator.search("First", in: [], debounce: .zero)
        }
        try await Task.sleep(for: .milliseconds(10))
        _ = try await coordinator.search("Second", in: [], debounce: .zero)

        await #expect(throws: CancellationError.self) {
            try await first.value
        }
    }
}

private struct CancellationIgnoringSearchService: SearchService {
    func search(
        _ rawQuery: String,
        in docsets: [DocsetDescriptor],
        limit: Int
    ) async throws -> [SymbolSearchResult] {
        if rawQuery == "First" {
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                // Deliberately emulate a dependency that completes despite cancellation.
            }
        }
        return []
    }
}
