import CruxCore
import AppKit
import Foundation
import SQLite3
import Testing
import SwiftUI
import WebKit

@testable import Crux

/// End-to-end coverage of the reading path inside the real, sandboxed app
/// process: a legacy registered docset is migrated, searched, served over loopback and
/// turned into tab state.
///
/// Running here rather than in a UI test is deliberate. These tests execute
/// under the app's own sandbox, so they also prove the network entitlements and
/// container paths are configured correctly.
@MainActor
@Suite(.serialized)
struct ReaderIntegrationTests {
    private static let identifier = "dev.crux.integration"
    private static let symbolName = "IntegrationSymbol"

    private func withModel(
        isJavaScriptEnabled: Bool? = true,
        _ body: (AppModel, URL) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "CruxReaderTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let layout = AppDirectoryLayout(applicationSupportDirectory: root)
        try FileManager.default.createDirectory(at: layout.defaultDocsetsDirectory, withIntermediateDirectories: true)
        try Self.installFixtureDocset(in: layout.defaultDocsetsDirectory, isJavaScriptEnabled: isJavaScriptEnabled)
        // Model the existing library: migration must preserve its persisted ID.
        // Fresh source-scoped IDs are exercised by MultiSourceSearch/Core source tests.
        let registry = try DocsetRegistry(databaseURL: layout.databaseURL)
        _ = try await registry.register(bundleAt: layout.defaultDocsetsDirectory.appending(path: "Integration.docset"))

        let preferences = ReaderPreferences(defaults: try #require(UserDefaults(suiteName: root.lastPathComponent)))
        let model = AppModel(preferences: preferences, layout: layout)
        await model.bootstrap()

        do {
            try await body(model, root)
            await model.shutdown()
        } catch {
            await model.shutdown()
            throw error
        }
    }

    @Test
    func scopedSearchKeepsRoomForInputBesideItsCapsule() async throws {
        try await withModel { model, _ in
            let tab = try #require(model.selectedTab)
            tab.search.selectScope(Self.identifier)
            let host = NSHostingView(rootView: ReaderSearchToolbar(
                model: model, tab: tab, isActive: true, focusRequest: 0,
                isPanelPresented: .constant(false), onSubmit: {}
            ).frame(height: 36).padding(8).preferredColorScheme(.dark))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 536, height: 52),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            defer { window.orderOut(nil) }
            host.layoutSubtreeIfNeeded()
            func findField(_ view: NSView) -> NSSearchField? {
                if let field = view as? NSSearchField { return field }
                return view.subviews.lazy.compactMap { findField($0) }.first
            }
            let field = try #require(findField(host))
            let fieldFrame = field.convert(field.bounds, to: host)
            #expect(fieldFrame.width >= 200)
            #expect(fieldFrame.maxX <= host.bounds.maxX)
            #expect(fieldFrame.minX > 100)
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            Attachment.record(png, named: "Scoped search capsule.png")
        }
    }

    @Test
    func startupFailureStillLeavesAUsableWelcomeTab() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "CruxStartupFailureTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let blockedRoot = root.appending(path: "not-a-directory", directoryHint: .notDirectory)
        try Data("blocked".utf8).write(to: blockedRoot)
        let preferences = ReaderPreferences(defaults: try #require(UserDefaults(suiteName: root.lastPathComponent)))
        let model = AppModel(
            preferences: preferences,
            layout: AppDirectoryLayout(applicationSupportDirectory: blockedRoot)
        )

        await model.bootstrap()

        #expect(model.startupError != nil)
        #expect(model.tabs.count == 1)
        #expect(model.selectedTab?.isWelcome == true)
        await model.shutdown()
    }

    @Test(arguments: ["Integration:", " INTEGRATION : ", "dev.crux.integration:", "int:"])
    func docsetPrefixSelectsTheBrowserAndContinuesScopedSearch(prefix: String) async throws {
        try await withModel { model, _ in
            let search = try #require(model.selectedTab).search
            search.updateQuery(Self.symbolName)
            try await waitUntil { !search.results.isEmpty }

            search.updateQuery(prefix)
            #expect(search.scopedDocsetIdentifier == Self.identifier)
            #expect(search.query.isEmpty)
            #expect(search.results.isEmpty)
            #expect(search.currentRoute == .docset(Self.identifier))
            #expect(search.scopeFocusRequest > 0)
            try await waitUntil { !search.isBrowsing }
            let prefixRoutes = search.routeStack
            let prefixSummaries = search.symbolTypeSummaries

            search.showDocset(Self.identifier)
            try await waitUntil { !search.isBrowsing }
            #expect(search.routeStack == prefixRoutes)
            #expect(search.symbolTypeSummaries == prefixSummaries)

            search.updateQuery(Self.symbolName)
            try await waitUntil { !search.results.isEmpty }
            #expect(search.query == Self.symbolName)
            #expect(search.scopedDocsetIdentifier == Self.identifier)
            #expect(search.results.allSatisfy { $0.docsetIdentifier == Self.identifier })
        }
    }

    @Test(arguments: ["unknown:", "Integration:IntegrationSymbol", "Integration,class:", "std::string", ":"])
    func otherQueriesKeepTheirExistingMeaning(query: String) async throws {
        try await withModel { model, _ in
            let search = try #require(model.selectedTab).search
            search.updateQuery(query)
            #expect(search.query == query)
            #expect(search.scopedDocsetIdentifier == nil)
            #expect(search.currentRoute == .results(query))
            search.reset()
        }
    }

    @Test
    func emptyQueryDeletionClearsScopeAtEveryBrowsingLevel() async throws {
        try await withModel { model, _ in
            let search = try #require(model.selectedTab).search
            #expect(!search.clearScopeIfQueryIsEmpty())
            for browseTypes in [false, true] {
                search.showDocset(Self.identifier)
                if browseTypes { search.showSymbolType("Class", in: Self.identifier) }
                search.updateQuery(Self.symbolName)
                #expect(!search.clearScopeIfQueryIsEmpty())
                #expect(search.scopedDocsetIdentifier == Self.identifier)
                search.updateQuery("")
                let focusRequest = search.scopeFocusRequest
                #expect(search.clearScopeIfQueryIsEmpty())
                #expect(search.scopedDocsetIdentifier == nil)
                #expect(search.query.isEmpty)
                #expect(search.currentRoute == .docsets)
                #expect(search.symbolTypeSummaries.isEmpty)
                #expect(search.browsedSymbols.isEmpty)
                #expect(!search.isBrowsing)
                #expect(search.scopeFocusRequest > focusRequest)
            }
        }
    }

    @Test
    func nativePrefixAndEmptyDeleteKeepTheSameFocusedFieldEditor() async throws {
        try await withModel { model, _ in
            let tab = try #require(model.selectedTab)
            let host = NSHostingView(rootView: ReaderSearchToolbar(
                model: model, tab: tab, isActive: true, focusRequest: 0,
                isPanelPresented: .constant(false), onSubmit: {}
            ).frame(height: 36))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 536, height: 52),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host
            defer { window.orderOut(nil) }
            host.layoutSubtreeIfNeeded()
            func findField(_ view: NSView) -> NSSearchField? {
                if let field = view as? NSSearchField { return field }
                for subview in view.subviews {
                    if let field = findField(subview) { return field }
                }
                return nil
            }
            let field = try #require(findField(host))
            #expect(window.makeFirstResponder(field))
            let editor = try #require(field.currentEditor())
            let textView = try #require(editor as? NSTextView)
            let delegate = try #require(field.delegate)
            field.stringValue = "int:"
            editor.string = "int:"
            delegate.controlTextDidChange?(
                Notification(name: NSControl.textDidChangeNotification, object: field)
            )
            #expect(tab.search.scopedDocsetIdentifier == Self.identifier)
            #expect(field.stringValue.isEmpty)
            #expect(editor.string.isEmpty)
            #expect(window.firstResponder === editor)
            try await waitUntil { field.placeholderString?.contains("Integration") == true }
            #expect(findField(host) === field)
            #expect(window.firstResponder === field.currentEditor())

            let handledDelete = delegate.control?(
                field, textView: try #require(field.currentEditor() as? NSTextView),
                doCommandBy: #selector(NSResponder.deleteBackward(_:))
            )
            #expect(handledDelete == true)
            #expect(tab.search.scopedDocsetIdentifier == nil)
            try await waitUntil { field.placeholderString?.contains("Integration") == false }
            #expect(findField(host) === field)
            #expect(window.firstResponder === field.currentEditor())

            tab.search.showDocset(Self.identifier)
            try await waitUntil { field.placeholderString?.contains("Integration") == true }
            field.stringValue = Self.symbolName
            editor.string = Self.symbolName
            delegate.controlTextDidChange?(
                Notification(name: NSControl.textDidChangeNotification, object: field)
            )
            #expect(tab.search.query == Self.symbolName)
            #expect(delegate.control?(field, textView: textView,
                                     doCommandBy: #selector(NSResponder.deleteBackward(_:))) == false)
            #expect(tab.search.scopedDocsetIdentifier == Self.identifier)
            try await waitUntil { !tab.search.isSearching }
        }
    }

    @Test
    func discoversTheDocsetAndFindsItsSymbols() async throws {
        try await withModel { model, _ in
            #expect(model.startupError == nil)
            #expect(model.docsets.map(\.identifier) == [Self.identifier])

            let tab = try #require(model.selectedTab)
            tab.search.updateQuery(Self.symbolName)
            try await waitUntil { !tab.search.results.isEmpty }

            let result = try #require(tab.search.results.first)
            #expect(result.name == Self.symbolName)
            #expect(result.relativePath == "symbol.html")
        }
    }

    @Test
    func servesTheDocumentOverLoopbackFromInsideTheSandbox() async throws {
        try await withModel { model, _ in
            let location = ReaderLocation(docsetIdentifier: Self.identifier, relativePath: "symbol.html")
            let url = try #require(model.url(for: location), "The document server should be running.")
            #expect(url.host() == "127.0.0.1")

            let configuration = URLSessionConfiguration.ephemeral
            let (data, response) = try await URLSession(configuration: configuration).data(from: url)
            let http = try #require(response as? HTTPURLResponse)

            #expect(http.statusCode == 200)
            #expect(String(data: data, encoding: .utf8)?.contains("Integration Page") == true)

            // The same URL without the run token must not resolve.
            var unauthorized = URLComponents(url: url, resolvingAgainstBaseURL: false)
            unauthorized?.path = "/\(Self.identifier)/symbol.html"
            let rejected = try await URLSession(configuration: configuration)
                .data(from: try #require(unauthorized?.url)).1 as? HTTPURLResponse
            #expect(rejected?.statusCode == 404)
        }
    }

    @Test
    func openingAResultCreatesATabWithNavigableHistory() async throws {
        try await withModel { model, _ in
            let search = try #require(model.selectedTab).search
            search.updateQuery(Self.symbolName)
            try await waitUntil { !search.results.isEmpty }
            model.open(try #require(search.results.first))

            let tab = try #require(model.selectedTab)
            #expect(model.tabs.count == 1)
            #expect(tab.currentLocation?.relativePath == "symbol.html")
            #expect(tab.currentLocation?.selectedSymbolName == Self.symbolName)
            #expect(tab.displayTitle == "symbol - \(Self.symbolName)")
            #expect(!tab.canGoBack)

            tab.navigate(to: ReaderLocation(docsetIdentifier: Self.identifier, relativePath: "index.html"))
            #expect(tab.currentLocation?.selectedSymbolName == nil)
            #expect(tab.canGoBack)
            tab.goBack()
            #expect(tab.currentLocation?.relativePath == "symbol.html")
            #expect(tab.currentLocation?.selectedSymbolName == Self.symbolName)
            #expect(tab.canGoForward)
        }
    }

    @Test
    func remoteResourcePolicyChangesReachTheRunningServer() async throws {
        try await withModel { model, _ in
            let location = ReaderLocation(docsetIdentifier: Self.identifier, relativePath: "symbol.html")
            let url = try #require(model.url(for: location))
            let session = URLSession(configuration: .ephemeral)

            let permissive = try await session.data(from: url).1 as? HTTPURLResponse
            #expect(permissive?.value(forHTTPHeaderField: "Content-Security-Policy")?.contains("https:") == true)

            model.preferences.allowsRemoteResources = false
            await model.applyRemoteResourcePolicyChange()

            let restricted = try await session.data(from: url).1 as? HTTPURLResponse
            #expect(restricted?.value(forHTTPHeaderField: "Content-Security-Policy")?.contains("https:") == false)
        }
    }

    @Test
    func firstUseRemoteResourceNoticeCanDisableRemoteAccess() async throws {
        try await withModel { model, _ in
            #expect(model.shouldPresentRemoteResourceNotice)

            await model.resolveRemoteResourceNotice(keepEnabled: false)

            #expect(model.preferences.hasSeenRemoteResourceNotice)
            #expect(!model.preferences.allowsRemoteResources)
            #expect(!model.shouldPresentRemoteResourceNotice)
        }
    }

    @Test
    func copyPageLinkWritesAStableSourceFileURLWithoutTheServerToken() async throws {
        try await withModel { model, _ in
            let location = ReaderLocation(
                docsetIdentifier: Self.identifier,
                relativePath: "symbol.html",
                fragment: "details"
            )
            model.open(location)
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("CruxTests-\(UUID().uuidString)"))

            #expect(model.copyCurrentPageLink(to: pasteboard))

            let copied = try #require(pasteboard.string(forType: .string))
            let copiedURL = try #require(URL(string: copied))
            #expect(copiedURL.isFileURL)
            #expect(copiedURL.lastPathComponent == "symbol.html")
            #expect(copiedURL.fragment == "details")
            #expect(!copied.contains("127.0.0.1"))
        }
    }

    @Test
    func enabledFullTextIndexAppearsAsASeparateSearchGroupAndCannotBeDisabled() async throws {
        try await withModel { model, _ in
            let descriptor = try #require(model.docsets.first)
            await model.enableFullTextSearch(for: descriptor)
            #expect(model.fullTextStates[Self.identifier]?.phase == .ready)

            let search = try #require(model.selectedTab).search
            search.updateQuery("Integration Page")
            try await waitUntil { !search.fullTextResults.isEmpty }

            let result = try #require(search.fullTextResults.first)
            #expect(result.relativePath == "symbol.html")
            model.open(result)
            #expect(model.selectedTab?.currentLocation?.relativePath == "symbol.html")

            await model.enableFullTextSearch(for: descriptor)
            #expect(model.fullTextStates[Self.identifier]?.phase == .ready)
            #expect(!search.fullTextResults.isEmpty)
        }
    }

    @Test
    func tabsOwnIndependentSearchStateAndHomeOnlyResetsTheSelectedTab() async throws {
        try await withModel { model, _ in
            let first = try #require(model.selectedTab)
            #expect(first.isWelcome)
            #expect(first.displayTitle == "Welcome")

            first.search.updateQuery(Self.symbolName)
            try await waitUntil { !first.search.results.isEmpty }
            model.open(try #require(first.search.results.first))

            let second = model.openTab()
            second.search.selectScope(Self.identifier)
            second.search.updateQuery("NoSuchSymbol")
            try await waitUntil { !second.search.isSearching }

            #expect(first.search.query == Self.symbolName)
            #expect(first.search.scopedDocsetIdentifier == nil)
            #expect(first.currentLocation?.relativePath == "symbol.html")
            #expect(second.search.query == "NoSuchSymbol")
            #expect(second.search.scopedDocsetIdentifier == Self.identifier)
            #expect(second.isWelcome)

            model.goHome(in: second)

            #expect(second.search.query.isEmpty)
            #expect(second.search.scopedDocsetIdentifier == nil)
            #expect(second.isWelcome)
            #expect(first.currentLocation?.relativePath == "symbol.html")
            #expect(first.search.query == Self.symbolName)
        }
    }

    @Test
    func closingTheLastTabImmediatelyCreatesAWelcomeTab() async throws {
        try await withModel { model, _ in
            let onlyTab = try #require(model.selectedTab)
            model.closeTab(onlyTab.id)

            #expect(model.tabs.count == 1)
            #expect(model.selectedTab?.isWelcome == true)
            #expect(model.selectedTab?.displayTitle == "Welcome")
        }
    }

    @Test
    func javaScriptFragmentsAndNewWindowLinksFollowReaderRoutingRules() async throws {
        try await withModel { model, _ in
            let original = try #require(model.selectedTab)
            model.open(ReaderLocation(
                docsetIdentifier: Self.identifier,
                relativePath: "interactive.html"
            ))
            try await waitUntil { !original.webView.isLoading && original.webView.url != nil }

            _ = try await original.webView.evaluateJavaScript(
                "document.getElementById('js-tab').click()"
            )
            let selected = try await original.webView.evaluateJavaScript(
                "document.getElementById('tab-panel').dataset.selected"
            ) as? String
            #expect(selected == "api")

            _ = try await original.webView.evaluateJavaScript(
                "document.getElementById('fragment-link').click()"
            )
            try await waitUntil { original.currentLocation?.fragment == "details" }

            _ = try await original.webView.evaluateJavaScript(
                "document.getElementById('blank-link').click()"
            )
            try await waitUntil { model.tabs.count == 2 }
            #expect(model.selectedTab?.currentLocation?.relativePath == "index.html")

            model.selectedTabID = original.id
            #expect(!original.webView.configuration.preferences.javaScriptCanOpenWindowsAutomatically)
            _ = try await original.webView.evaluateJavaScript(
                "document.getElementById('window-open').click()"
            )
            // Programmatic popups are intentionally blocked. The same
            // `window.open` call from a real user gesture still reaches the UI
            // delegate; target=_blank above exercises that shared routing path.
            try await Task.sleep(for: .milliseconds(150))
            #expect(model.tabs.count == 2)
        }
    }

    @Test
    func sameWindowLinksRefreshChapterTitleAndTableOfContents() async throws {
        try await withModel { model, _ in
            let tab = try #require(model.selectedTab)
            model.open(ReaderLocation(
                docsetIdentifier: Self.identifier,
                relativePath: "interactive.html",
                title: "Interactive",
                selectedSymbolName: "ExampleSymbol"
            ))
            try await waitUntil { !tab.webView.isLoading && tab.webView.url != nil }

            _ = try await tab.webView.evaluateJavaScript(
                "document.getElementById('normal-link').click()"
            )
            try await waitUntil {
                tab.currentLocation?.relativePath == "index.html"
                    && !tab.webView.isLoading
                    && tab.title == "Home Chapter"
                    && !tab.tableOfContents.isEmpty
            }

            #expect(tab.currentLocation?.selectedSymbolName == nil)
            #expect(tab.displayTitle == "Home Chapter")
            #expect(tab.tableOfContents.map(\.title) == ["Home"])
        }
    }

    @Test(arguments: [true, false])
    func undeclaredJavaScriptSupportsLocalPageInteractions(allowsRemoteResources: Bool) async throws {
        try await withModel(isJavaScriptEnabled: nil) { model, _ in
            model.preferences.allowsRemoteResources = allowsRemoteResources
            await model.applyRemoteResourcePolicyChange()
            let tab = try #require(model.selectedTab)
            model.open(ReaderLocation(docsetIdentifier: Self.identifier, relativePath: "scripted.html"))
            try await waitUntil { !tab.webView.isLoading && tab.webView.url?.lastPathComponent == "scripted.html" }

            let searchEnabled = try await tab.webView.evaluateJavaScript(
                "!document.getElementById('page-search').disabled", in: nil, contentWorld: .defaultClient
            ) as? Bool
            #expect(searchEnabled == true)

            // Exercise the DOM event and external script together, as Javadoc does.
            for category in ["interfaces", "classes", "all"] {
                _ = try await tab.webView.evaluateJavaScript(
                    "document.getElementById('\(category)').click()", in: nil, contentWorld: .defaultClient
                )
                let selected = try await tab.webView.evaluateJavaScript(
                    "document.querySelector('[aria-selected=true]').id", in: nil, contentWorld: .defaultClient
                ) as? String
                let visibleRows = try await tab.webView.evaluateJavaScript(
                    "Array.from(document.querySelectorAll('[data-kind]')).filter(row => !row.hidden).map(row => row.id)",
                    in: nil, contentWorld: .defaultClient
                ) as? [String]
                #expect(selected == category)
                let expectedRows = category == "all" ? ["interface-row", "class-row"]
                    : category == "interfaces" ? ["interface-row"] : ["class-row"]
                #expect(visibleRows == expectedRows)
            }

            _ = try await tab.webView.evaluateJavaScript(
                "document.getElementById('disclosure').click()", in: nil, contentWorld: .defaultClient
            )
            let expanded = try await tab.webView.evaluateJavaScript(
                "!document.getElementById('details').hidden", in: nil, contentWorld: .defaultClient
            ) as? Bool
            #expect(expanded == true)
        }
    }

    @Test
    func explicitlyDisabledJavaScriptKeepsPageHandlersInactive() async throws {
        try await withModel(isJavaScriptEnabled: false) { model, _ in
            let tab = try #require(model.selectedTab)
            model.open(ReaderLocation(docsetIdentifier: Self.identifier, relativePath: "scripted.html"))
            try await waitUntil { !tab.webView.isLoading && tab.webView.url?.lastPathComponent == "scripted.html" }
            _ = try await tab.webView.evaluateJavaScript(
                "document.getElementById('interfaces').click(); document.getElementById('disclosure').click()",
                in: nil, contentWorld: .defaultClient
            )
            let unchanged = try await tab.webView.evaluateJavaScript(
                """
                document.getElementById('page-search').disabled &&
                document.getElementById('all').getAttribute('aria-selected') === 'true' &&
                document.getElementById('details').hidden
                """, in: nil, contentWorld: .defaultClient
            ) as? Bool
            #expect(unchanged == true)
        }
    }

    // MARK: - Helpers

    private func waitUntil(
        timeout: Duration = .seconds(5),
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock().now + timeout
        while ContinuousClock().now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        Issue.record("Timed out waiting for the expected state.")
    }

    private static func installFixtureDocset(in directory: URL, isJavaScriptEnabled: Bool?) throws {
        let bundleURL = directory.appending(path: "Integration.docset", directoryHint: .isDirectory)
        let resourcesURL = bundleURL.appending(path: "Contents/Resources", directoryHint: .isDirectory)
        let documentsURL = resourcesURL.appending(path: "Documents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: documentsURL, withIntermediateDirectories: true)

        var plist: [String: Any] = [
            "CFBundleIdentifier": identifier,
            "CFBundleName": "Integration",
            "CFBundleShortVersionString": "1.0",
            "DashDocSetKeyword": "int",
            "dashIndexFilePath": "index.html",
        ]
        plist["isJavaScriptEnabled"] = isJavaScriptEnabled
        try PropertyListSerialization
            .data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: bundleURL.appending(path: "Contents/Info.plist", directoryHint: .notDirectory))
        try Data("<html><head><title>Home Chapter</title></head><body><h1 id=\"home\">Home</h1></body></html>".utf8)
            .write(to: documentsURL.appending(path: "index.html", directoryHint: .notDirectory))
        try Data("<html><body><h1>Integration Page</h1></body></html>".utf8)
            .write(to: documentsURL.appending(path: "symbol.html", directoryHint: .notDirectory))
        try Data(
            """
            <html>
              <body>
                <button id="js-tab" onclick="document.getElementById('tab-panel').dataset.selected='api'">API</button>
                <div id="tab-panel" data-selected="overview">Panel</div>
                <a id="normal-link" href="index.html">Open home here</a>
                <a id="fragment-link" href="#details">Details</a>
                <a id="blank-link" href="index.html" target="_blank">Open home</a>
                <button id="window-open" onclick="window.open('symbol.html')">Open symbol</button>
                <h2 id="details">Details</h2>
              </body>
            </html>
            """.utf8
        ).write(to: documentsURL.appending(path: "interactive.html", directoryHint: .notDirectory))

        try Data("""
            <!doctype html><html><head><script src="interactions.js"></script></head><body>
            <input id="page-search" disabled>
            <div role="tablist">
              <button id="all" role="tab" aria-selected="true" onclick="showCategory('all')">All</button>
              <button id="interfaces" role="tab" aria-selected="false" onclick="showCategory('interfaces')">Interfaces</button>
              <button id="classes" role="tab" aria-selected="false" onclick="showCategory('classes')">Classes</button>
            </div>
            <div id="interface-row" data-kind="interfaces">Example Interface</div>
            <div id="class-row" data-kind="classes">Example Class</div>
            <button id="disclosure">Details</button><div id="details" hidden>Expanded details</div>
            </body></html>
            """.utf8).write(to: documentsURL.appending(path: "scripted.html"))
        try Data("""
            function showCategory(category) {
              document.querySelectorAll('[role=tab]').forEach(tab => {
                tab.setAttribute('aria-selected', String(tab.id === category));
              });
              document.querySelectorAll('[data-kind]').forEach(row => {
                row.hidden = category !== 'all' && row.dataset.kind !== category;
              });
            }
            document.addEventListener('DOMContentLoaded', () => {
              document.getElementById('page-search').disabled = false;
              document.getElementById('disclosure').addEventListener('click', () => {
                const details = document.getElementById('details');
                details.hidden = !details.hidden;
              });
            });
            """.utf8).write(to: documentsURL.appending(path: "interactions.js"))

        var handle: OpaquePointer?
        let indexPath = resourcesURL.appending(path: "docSet.dsidx", directoryHint: .notDirectory).path
        guard sqlite3_open(indexPath, &handle) == SQLITE_OK, let database = handle else {
            throw FixtureError.couldNotCreateIndex
        }
        defer { sqlite3_close(database) }

        for sql in [
            "CREATE TABLE searchIndex(id INTEGER PRIMARY KEY, name TEXT, type TEXT, path TEXT)",
            "INSERT INTO searchIndex(name, type, path) VALUES ('\(symbolName)', 'Class', 'symbol.html')",
        ] {
            guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
                throw FixtureError.couldNotCreateIndex
            }
        }
    }

    private enum FixtureError: Error {
        case couldNotCreateIndex
    }
}
