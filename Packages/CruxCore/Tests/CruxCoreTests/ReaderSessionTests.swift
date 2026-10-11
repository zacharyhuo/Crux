import Foundation
import Testing

@testable import CruxCore

@Suite
struct ReaderSessionTests {
    private func location(_ path: String, docset: String = "org.python.Python") -> ReaderLocation {
        ReaderLocation(docsetIdentifier: docset, relativePath: path, title: path)
    }

    @Test
    func historyMovesBackAndForwardWithoutLeakingBetweenTabs() {
        var first = ReaderTabState(location: location("a.html"))
        var second = ReaderTabState(location: location("x.html"))

        first.navigate(to: location("b.html"))
        first.navigate(to: location("c.html"))
        second.navigate(to: location("y.html"))

        #expect(first.goBack()?.relativePath == "b.html")
        #expect(first.canGoForward)
        #expect(second.current?.relativePath == "y.html")
        #expect(second.entries.count == 2)

        #expect(first.goForward()?.relativePath == "c.html")
        #expect(!first.canGoForward)
        #expect(first.goForward() == nil)
    }

    @Test
    func navigatingAfterGoingBackDropsTheForwardEntries() {
        var tab = ReaderTabState(location: location("a.html"))
        tab.navigate(to: location("b.html"))
        tab.navigate(to: location("c.html"))
        tab.goBack()

        tab.navigate(to: location("d.html"))

        #expect(tab.entries.map(\.relativePath) == ["a.html", "b.html", "d.html"])
        #expect(!tab.canGoForward)
    }

    @Test
    func repeatedNavigationToTheSameLocationDoesNotGrowHistory() {
        var tab = ReaderTabState(location: location("a.html"))
        tab.navigate(to: location("a.html"))

        #expect(tab.entries.count == 1)

        // A different fragment is a different history entry, as in a browser.
        tab.navigate(to: ReaderLocation(
            docsetIdentifier: "org.python.Python",
            relativePath: "a.html",
            fragment: "section"
        ))
        #expect(tab.entries.count == 2)
        #expect(tab.canGoBack)
    }

    @Test
    func historyStaysBoundedForLongBrowsingSessions() {
        var tab = ReaderTabState(location: location("0.html"))
        for index in 1...(ReaderTabState.historyLimit + 20) {
            tab.navigate(to: location("\(index).html"))
        }

        #expect(tab.entries.count == ReaderTabState.historyLimit)
        #expect(tab.current?.relativePath == "\(ReaderTabState.historyLimit + 20).html")
    }

    @Test
    func pruningDropsEntriesAndTabsForUninstalledDocsets() {
        var mixed = ReaderTabState(location: location("a.html"))
        mixed.navigate(to: location("gone.html", docset: "dev.crux.removed"))
        mixed.navigate(to: location("b.html"))
        let orphan = ReaderTabState(location: location("only.html", docset: "dev.crux.removed"))

        let session = ReaderSessionState(tabs: [mixed, orphan], selectedTabID: orphan.id)
            .pruned(keepingDocsets: ["org.python.Python"])

        #expect(session.tabs.count == 1)
        #expect(session.tabs[0].entries.map(\.relativePath) == ["a.html", "b.html"])
        #expect(session.tabs[0].current?.relativePath == "b.html")
        #expect(session.selectedTabID == mixed.id)
    }

    @Test
    func sessionsRoundTripThroughDiskAndTolerateAMissingFile() async throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReaderSessionStore(sessionDirectory: root.appending(path: "Session", directoryHint: .isDirectory))

        #expect(await store.load() == .empty)

        var tab = ReaderTabState(location: location("a.html"))
        tab.navigate(to: location("b.html"))
        tab.updateCurrentTitle("Section B")
        let state = ReaderSessionState(tabs: [tab], selectedTabID: tab.id)
        try await store.save(state)

        let restored = await store.load()
        #expect(restored == state)
        #expect(restored.tabs[0].current?.title == "Section B")

        await store.clear()
        #expect(await store.load() == .empty)
    }

    @Test
    func welcomeTabsSurvivePruningAndSelectedSymbolsRoundTrip() async throws {
        let root = try TestDocsetFixture.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReaderSessionStore(
            sessionDirectory: root.appending(path: "Session", directoryHint: .isDirectory)
        )
        let welcome = ReaderTabState()
        let location = ReaderLocation(
            docsetIdentifier: "org.python.Python",
            relativePath: "library/pprint.html",
            title: "Pretty printing",
            selectedSymbolName: "pprint"
        )
        let reader = ReaderTabState(location: location)
        let original = ReaderSessionState(tabs: [welcome, reader], selectedTabID: welcome.id)

        let pruned = original.pruned(keepingDocsets: ["org.python.Python"])
        #expect(pruned.tabs.map(\.id) == [welcome.id, reader.id])
        #expect(pruned.selectedTabID == welcome.id)

        try await store.save(pruned)
        let restored = await store.load()
        #expect(restored == pruned)
        #expect(restored.tabs[1].current?.selectedSymbolName == "pprint")
    }

    @Test
    func resettingATabReturnsItToWelcomeWithoutChangingItsIdentity() {
        var tab = ReaderTabState(location: location("a.html"))
        let id = tab.id
        tab.navigate(to: location("b.html"))

        tab.resetToWelcome()

        #expect(tab.id == id)
        #expect(tab.entries.isEmpty)
        #expect(tab.current == nil)
        #expect(!tab.canGoBack)
        #expect(!tab.canGoForward)
    }
}
