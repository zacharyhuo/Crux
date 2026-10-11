import Foundation

/// A place inside a docset that a tab can navigate to.
///
/// Locations are stored as docset identifier plus relative path rather than as
/// absolute URLs, because the loopback port and access token change on every
/// launch. This is what makes a restored session usable instead of stale.
public struct ReaderLocation: Codable, Equatable, Hashable, Sendable {
    public let docsetIdentifier: String
    public let relativePath: String
    public let fragment: String?
    public var title: String
    /// The symbol that opened this page, kept separately from the page title so
    /// tab labels can present "chapter - symbol" and restore it with history.
    public let selectedSymbolName: String?

    public init(
        docsetIdentifier: String,
        relativePath: String,
        fragment: String? = nil,
        title: String = "",
        selectedSymbolName: String? = nil
    ) {
        self.docsetIdentifier = docsetIdentifier
        self.relativePath = relativePath
        self.fragment = fragment
        self.title = title
        self.selectedSymbolName = selectedSymbolName
    }

    /// Two locations are the same page when only the fragment differs.
    public func isSamePage(as other: ReaderLocation) -> Bool {
        docsetIdentifier == other.docsetIdentifier && relativePath == other.relativePath
    }
}

/// The navigation state of one reader tab.
///
/// The tab owns its own history rather than delegating to the web view, so back
/// and forward behave identically for restored sessions and can be unit tested
/// without WebKit.
public struct ReaderTabState: Codable, Equatable, Identifiable, Sendable {
    /// The number of entries a single tab keeps. Older entries fall off the back.
    public static let historyLimit = 100

    public let id: UUID
    public private(set) var entries: [ReaderLocation]
    public private(set) var currentIndex: Int

    public init(id: UUID = UUID(), location: ReaderLocation? = nil) {
        self.id = id
        entries = location.map { [$0] } ?? []
        currentIndex = location == nil ? -1 : 0
    }

    public var current: ReaderLocation? {
        entries.indices.contains(currentIndex) ? entries[currentIndex] : nil
    }

    public var canGoBack: Bool { currentIndex > 0 }
    public var canGoForward: Bool { currentIndex >= 0 && currentIndex < entries.count - 1 }

    public var title: String {
        guard let current else { return "" }
        return current.title.isEmpty ? current.relativePath : current.title
    }

    /// Pushes a location, discarding any forward history, as a browser does.
    public mutating func navigate(to location: ReaderLocation) {
        if let current, current == location { return }
        if currentIndex < entries.count - 1 {
            entries.removeSubrange((currentIndex + 1)...)
        }
        entries.append(location)
        if entries.count > Self.historyLimit {
            entries.removeFirst(entries.count - Self.historyLimit)
        }
        currentIndex = entries.count - 1
    }

    @discardableResult
    public mutating func goBack() -> ReaderLocation? {
        guard canGoBack else { return nil }
        currentIndex -= 1
        return current
    }

    @discardableResult
    public mutating func goForward() -> ReaderLocation? {
        guard canGoForward else { return nil }
        currentIndex += 1
        return current
    }

    public mutating func updateCurrentTitle(_ title: String) {
        guard entries.indices.contains(currentIndex), !title.isEmpty else { return }
        entries[currentIndex].title = title
    }

    /// Clears the current document and history while preserving the tab's
    /// stable identity. An empty state is the persisted representation of Welcome.
    public mutating func resetToWelcome() {
        entries.removeAll(keepingCapacity: false)
        currentIndex = -1
    }

    /// Drops entries whose docset is no longer installed and repositions the cursor.
    ///
    /// Returns `false` when nothing usable is left, so the caller can close the tab.
    public mutating func pruneEntries(keepingDocsets installedIdentifiers: Set<String>) -> Bool {
        let wasWelcomeTab = entries.isEmpty
        var survivors: [ReaderLocation] = []
        var restoredIndex = -1
        for (index, entry) in entries.enumerated()
        where installedIdentifiers.contains(entry.docsetIdentifier) {
            survivors.append(entry)
            // Track the newest survivor at or before the old cursor so the tab
            // reopens as close as possible to where the user left it.
            if index <= currentIndex { restoredIndex = survivors.count - 1 }
        }

        entries = survivors
        guard !survivors.isEmpty else {
            currentIndex = -1
            return wasWelcomeTab
        }
        currentIndex = restoredIndex >= 0 ? restoredIndex : 0
        return true
    }
}

/// Everything the reader restores on the next launch.
public struct ReaderSessionState: Codable, Equatable, Sendable {
    public var tabs: [ReaderTabState]
    public var selectedTabID: UUID?

    public init(tabs: [ReaderTabState] = [], selectedTabID: UUID? = nil) {
        self.tabs = tabs
        self.selectedTabID = selectedTabID
    }

    public static let empty = ReaderSessionState()

    /// Removes tabs that can no longer resolve and keeps the selection valid.
    public func pruned(keepingDocsets installedIdentifiers: Set<String>) -> ReaderSessionState {
        var survivors: [ReaderTabState] = []
        for tab in tabs {
            var candidate = tab
            if candidate.pruneEntries(keepingDocsets: installedIdentifiers) {
                survivors.append(candidate)
            }
        }
        let selected = survivors.contains { $0.id == selectedTabID } ? selectedTabID : survivors.first?.id
        return ReaderSessionState(tabs: survivors, selectedTabID: selected)
    }
}

/// Reads and writes the reader session file.
public actor ReaderSessionStore {
    private let fileURL: URL

    public init(sessionDirectory: URL) {
        fileURL = ReaderSessionStore.fileURL(in: sessionDirectory)
    }

    public static func fileURL(in sessionDirectory: URL) -> URL {
        sessionDirectory.appending(path: "reader-session.json", directoryHint: .notDirectory)
    }

    /// A missing or unreadable session is not an error; the reader simply starts empty.
    public func load() -> ReaderSessionState {
        Self.load(from: fileURL)
    }

    public func save(_ state: ReaderSessionState) throws {
        try Self.write(state, to: fileURL)
    }

    public func clear() {
        Self.remove(at: fileURL)
    }

    // MARK: - Blocking access
    //
    // Application termination cannot await an actor, so the same file format is
    // also reachable synchronously. Normal operation goes through the actor.

    public static func load(from fileURL: URL) -> ReaderSessionState {
        guard let data = try? Data(contentsOf: fileURL),
              let state = try? JSONDecoder().decode(ReaderSessionState.self, from: data) else {
            return .empty
        }
        return state
    }

    public static func write(_ state: ReaderSessionState, to fileURL: URL) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(state)
        // A partially written session file would be worse than no session at all.
        try data.write(to: fileURL, options: .atomic)
    }

    public static func remove(at fileURL: URL) {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
