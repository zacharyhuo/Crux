import CruxCore
import Foundation
import Observation

/// One level in the Dash-style search suggestion panel.
enum SearchPanelRoute: Hashable {
    case docsets
    case docset(String)
    case symbolType(String, String)
    case results(String)
    case nested(SymbolSearchGroupKey)
}

/// Search and structured-browsing state owned by exactly one reader tab.
///
/// A separate coordinator per tab is important: `SearchCoordinator` implements
/// latest-query-wins by cancellation, so sharing one would make typing in tab B
/// cancel an in-flight query in tab A.
@MainActor
@Observable
final class TabSearchState {
    private(set) var query = ""
    private(set) var scopedDocsetIdentifier: String?
    private(set) var prefixChoiceIdentifiers: [String] = []
    private(set) var scopeFocusRequest = 0
    private(set) var results: [SymbolSearchResult] = []
    private(set) var fullTextResults: [FullTextSearchResult] = []
    private(set) var symbolTypeSummaries: [SymbolTypeSummary] = []
    private(set) var browsedSymbols: [SymbolSearchResult] = []
    private(set) var isSearching = false
    private(set) var isBrowsing = false
    private(set) var routeStack: [SearchPanelRoute] = [.docsets]

    @ObservationIgnored private weak var context: (any TabSearchContext)?
    @ObservationIgnored private let symbolService: SymbolSearchService
    @ObservationIgnored private var coordinator: SearchCoordinator
    @ObservationIgnored private var browseCoordinator: SearchCoordinator
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var browseTask: Task<Void, Never>?

    init(context: any TabSearchContext) {
        self.context = context
        let service = context.symbolSearchService
        symbolService = service
        coordinator = SearchCoordinator(service: service)
        browseCoordinator = SearchCoordinator(service: service)
    }

    var currentRoute: SearchPanelRoute { routeStack.last ?? .docsets }
    var groupedResults: [SymbolSearchResultGroup] { results.nestedResultGroups() }

    func updateQuery(_ value: String) {
        guard value != query else { return }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        prefixChoiceIdentifiers = []
        if trimmed.hasSuffix(":"), let context {
            let matches = context.searchableDocsets(matching: nil).filter {
               $0.searchFilters.contains(String(trimmed.dropLast())
                   .trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            }
            if matches.count == 1, let descriptor = matches.first {
                showDocset(descriptor.identifier)
                return
            }
            if matches.count > 1 {
                query = value
                scopedDocsetIdentifier = nil
                prefixChoiceIdentifiers = matches.map(\.identifier)
                searchTask?.cancel(); browseTask?.cancel()
                clearResults()
                routeStack = [.docsets]
                return
            }
        }
        query = value
        if trimmed.isEmpty {
            routeStack.removeAll { route in
                if case .results = route { return true }
                if case .nested = route { return true }
                return false
            }
            if routeStack.isEmpty { routeStack = baseRoutes() }
        } else if let last = routeStack.last {
            switch last {
            case .results:
                routeStack[routeStack.count - 1] = .results(trimmed)
            case .nested:
                routeStack.removeLast()
                if case .results = routeStack.last {
                    routeStack[routeStack.count - 1] = .results(trimmed)
                } else {
                    routeStack.append(.results(trimmed))
                }
            default:
                routeStack.append(.results(trimmed))
            }
        }
        scheduleSearch()
    }

    /// `nil` is the All Docsets scope and is also what removing the SwiftUI
    /// search token writes back through its binding.
    func selectScope(_ identifier: String?) {
        prefixChoiceIdentifiers = []
        guard identifier != scopedDocsetIdentifier else { return }
        scopedDocsetIdentifier = identifier
        routeStack = baseRoutes()
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            routeStack.append(.results(query))
        }
        scheduleSearch()
    }

    func showDocset(_ identifier: String) {
        prefixChoiceIdentifiers = []
        scopedDocsetIdentifier = identifier
        scopeFocusRequest &+= 1
        query = ""
        prefixChoiceIdentifiers = []
        searchTask?.cancel()
        clearResults()
        routeStack = [.docsets, .docset(identifier)]
        loadTypeSummaries(for: identifier)
    }

    @discardableResult
    func clearScopeIfQueryIsEmpty() -> Bool {
        guard query.isEmpty, scopedDocsetIdentifier != nil else { return false }
        browseTask?.cancel()
        symbolTypeSummaries = []
        browsedSymbols = []
        isBrowsing = false
        selectScope(nil)
        scopeFocusRequest &+= 1
        return true
    }

    func showSymbolType(_ type: String, in identifier: String) {
        routeStack.removeAll { route in
            if case .symbolType = route { return true }
            return false
        }
        routeStack.append(.symbolType(identifier, type))
        browsedSymbols = []
        loadSymbols(ofType: type, in: identifier)
    }

    func showNestedResults(for key: SymbolSearchGroupKey) {
        guard groupedResults.contains(where: { $0.key == key && $0.hasSimilarResults }) else { return }
        if case .nested = routeStack.last { routeStack.removeLast() }
        routeStack.append(.nested(key))
    }

    func nestedGroup(for key: SymbolSearchGroupKey) -> SymbolSearchResultGroup? {
        groupedResults.first { $0.key == key }
    }

    func goBack() {
        switch currentRoute {
        case .nested:
            routeStack.removeLast()
        case .results:
            updateQuery("")
        case .symbolType:
            routeStack.removeLast()
            browsedSymbols = []
        case .docset:
            scopedDocsetIdentifier = nil
            symbolTypeSummaries = []
            routeStack = [.docsets]
        case .docsets:
            break
        }
    }

    func refreshForInstalledDocsetsChange() {
        if let scopedDocsetIdentifier,
           context?.searchableDocsets(matching: scopedDocsetIdentifier).isEmpty != false {
            selectScope(nil)
        } else {
            switch currentRoute {
            case let .docset(identifier):
                loadTypeSummaries(for: identifier)
            case let .symbolType(identifier, type):
                loadSymbols(ofType: type, in: identifier)
            default:
                scheduleSearch()
            }
        }
    }

    func reset() {
        searchTask?.cancel()
        browseTask?.cancel()
        let previousCoordinator = coordinator
        let previousBrowseCoordinator = browseCoordinator
        coordinator = SearchCoordinator(service: symbolService)
        browseCoordinator = SearchCoordinator(service: symbolService)
        // Cancelling the retired coordinator cannot race with a new query,
        // which already uses the replacement instance above.
        Task { await previousCoordinator.cancel() }
        Task { await previousBrowseCoordinator.cancel() }
        query = ""
        scopedDocsetIdentifier = nil
        prefixChoiceIdentifiers = []
        results = []
        fullTextResults = []
        symbolTypeSummaries = []
        browsedSymbols = []
        isSearching = false
        isBrowsing = false
        routeStack = [.docsets]
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let context else {
            clearResults()
            return
        }
        let docsets = context.searchableDocsets(matching: scopedDocsetIdentifier)
        guard !docsets.isEmpty else {
            clearResults()
            return
        }

        isSearching = true
        searchTask = Task { [coordinator] in
            do {
                let foundSymbols = try await coordinator.search(trimmed, in: docsets, limit: 300)
                let foundPages = try await context.searchFullText(trimmed, in: docsets, limit: 200)
                guard !Task.isCancelled else { return }
                results = foundSymbols
                fullTextResults = foundPages
                isSearching = false
            } catch is CancellationError {
                // The replacement request owns the loading flag and result set.
            } catch {
                guard !Task.isCancelled else { return }
                clearResults()
            }
        }
    }

    private func loadTypeSummaries(for identifier: String) {
        browseTask?.cancel()
        symbolTypeSummaries = []
        guard let descriptor = context?.searchableDocsets(matching: identifier).first else {
            symbolTypeSummaries = []
            return
        }
        isBrowsing = true
        browseTask = Task { [symbolService] in
            do {
                let summaries = try await symbolService.symbolTypeSummaries(in: descriptor)
                guard !Task.isCancelled, currentRoute == .docset(identifier) else { return }
                symbolTypeSummaries = summaries
                isBrowsing = false
            } catch {
                guard !Task.isCancelled else { return }
                symbolTypeSummaries = []
                isBrowsing = false
            }
        }
    }

    private func loadSymbols(ofType type: String, in identifier: String) {
        browseTask?.cancel()
        guard let descriptor = context?.searchableDocsets(matching: identifier).first else {
            browsedSymbols = []
            return
        }
        isBrowsing = true
        browseTask = Task { [browseCoordinator] in
            do {
                let found = try await browseCoordinator.search(
                    "\(type):",
                    in: [descriptor],
                    limit: 5_000,
                    debounce: .zero
                )
                guard !Task.isCancelled, currentRoute == .symbolType(identifier, type) else { return }
                browsedSymbols = found
                isBrowsing = false
            } catch {
                guard !Task.isCancelled else { return }
                browsedSymbols = []
                isBrowsing = false
            }
        }
    }

    private func clearResults() {
        results = []
        fullTextResults = []
        isSearching = false
    }

    private func baseRoutes() -> [SearchPanelRoute] {
        if let scopedDocsetIdentifier {
            return [.docsets, .docset(scopedDocsetIdentifier)]
        }
        return [.docsets]
    }
}
