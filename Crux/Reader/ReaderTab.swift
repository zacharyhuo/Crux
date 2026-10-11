import AppKit
import CruxCore
import Foundation
import Observation
import WebKit

/// One entry in the table of contents extracted from the rendered page.
struct TableOfContentsItem: Identifiable, Equatable, Sendable {
    let id: String
    let level: Int
    let title: String
}

/// Resolves the loopback URLs and per-docset policy a tab needs.
///
/// The tab talks to this instead of `AppModel` directly so navigation logic can
/// be exercised without building the whole application state.
@MainActor
protocol TabSearchContext: AnyObject {
    var symbolSearchService: SymbolSearchService { get }
    func searchableDocsets(matching identifier: String?) -> [DocsetDescriptor]
    func searchFullText(
        _ query: String,
        in docsets: [DocsetDescriptor],
        limit: Int
    ) async throws -> [FullTextSearchResult]
}

protocol ReaderDocumentContext: AnyObject {
    func url(for location: ReaderLocation) -> URL?
    func location(for url: URL) -> ReaderLocation?
    func isJavaScriptEnabled(forDocset identifier: String) -> Bool
    func openDocument(_ location: ReaderLocation, inNewTab: Bool)
    func openExternalURL(_ url: URL)
}

/// A single reader tab and the web view that renders it.
///
/// History lives in `ReaderTabState` rather than in `WKBackForwardList`. Driving
/// navigation from the model keeps restored sessions, menu commands and the
/// toolbar consistent, and it is what allows the behaviour to be unit tested.
@MainActor
@Observable
final class ReaderTab: Identifiable {
    /// Zoom steps roughly matching what other macOS document readers offer.
    private static let zoomLevels: [CGFloat] = [0.5, 0.75, 0.9, 1.0, 1.15, 1.3, 1.5, 1.75, 2.0, 2.5, 3.0]

    let id: UUID
    private(set) var state: ReaderTabState
    private(set) var tableOfContents: [TableOfContentsItem] = []
    private(set) var isLoading = false
    private(set) var loadingProgress = 0.0
    private(set) var failureMessage: String?
    let search: TabSearchState

    @ObservationIgnored let webView: WKWebView
    @ObservationIgnored private let navigator: ReaderNavigator
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private weak var context: (any ReaderDocumentContext)?
    /// Suppresses history recording while the model itself is driving a load.
    @ObservationIgnored private var isPerformingModelNavigation = false
    @ObservationIgnored private var tableOfContentsTask: Task<Void, Never>?
    @ObservationIgnored private var loadTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var loadGeneration = UUID()
    @ObservationIgnored private var navigationLoads: [ObjectIdentifier: LoadAttempt] = [:]
    @ObservationIgnored private var activeModelNavigationID: ObjectIdentifier?

    var title: String { state.title }
    var isWelcome: Bool { currentLocation == nil }
    var displayTitle: String {
        guard let location = currentLocation else { return "Welcome" }
        let chapter = location.title.isEmpty ? location.relativePath : location.title
        guard let symbol = location.selectedSymbolName, !symbol.isEmpty else { return chapter }
        return "\(chapter) - \(symbol)"
    }
    var canGoBack: Bool { state.canGoBack }
    var canGoForward: Bool { state.canGoForward }
    var currentLocation: ReaderLocation? { state.current }
    var zoomLevel: CGFloat { webView.pageZoom }

    init(state: ReaderTabState, context: any ReaderDocumentContext & TabSearchContext) {
        id = state.id
        self.state = state
        self.context = context
        search = TabSearchState(context: context)

        let configuration = WKWebViewConfiguration()
        // Nothing the reader shows should outlive the launch or leak between docsets.
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        // Script-enabled docsets may open a page from a real user gesture, but
        // cannot create tabs automatically while loading or from a timer.
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = WKWebView(frame: .zero, configuration: configuration)
        // Back and forward are owned by the model, so the native list stays unused.
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsMagnification = true

        navigator = ReaderNavigator(context: context)
        webView.navigationDelegate = navigator
        webView.uiDelegate = navigator
        navigator.owner = self

        observeWebView()
        if let location = state.current {
            load(location, recordHistory: false)
        }
    }

    deinit {
        // KVO registrations must be torn down before the web view is released.
        observations.forEach { $0.invalidate() }
        loadTimeoutTask?.cancel()
    }

    // MARK: - Navigation

    func navigate(to location: ReaderLocation) {
        state.navigate(to: location)
        load(location, recordHistory: false)
    }

    func goBack() {
        guard let location = state.goBack() else { return }
        load(location, recordHistory: false)
    }

    func goForward() {
        guard let location = state.goForward() else { return }
        load(location, recordHistory: false)
    }

    func reload() {
        guard let location = state.current else { return }
        load(location, recordHistory: false)
    }

    /// Home is a workspace reset, not a navigation entry. Consequently Back is
    /// disabled afterwards and all search state belonging to this tab is gone.
    func resetToWelcome() {
        loadGeneration = UUID()
        loadTimeoutTask?.cancel()
        tableOfContentsTask?.cancel()
        webView.stopLoading()
        navigationLoads = [:]
        activeModelNavigationID = nil
        state.resetToWelcome()
        search.reset()
        tableOfContents = []
        isLoading = false
        loadingProgress = 0
        failureMessage = nil
        isPerformingModelNavigation = false
    }

    func retryAfterFailure() {
        reload()
    }

    func scrollToAnchor(_ identifier: String) {
        // Pass document-authored text as a WebKit argument instead of
        // interpolating it into JavaScript. This is analogous to using bound
        // query parameters instead of constructing SQL with string templates.
        Task { [webView] in
            _ = try? await webView.callAsyncJavaScript(
                """
                const target = document.getElementById(identifier)
                  ?? document.getElementsByName(identifier)[0];
                if (target) { target.scrollIntoView({ block: "start" }); }
                """,
                arguments: ["identifier": identifier],
                in: nil,
                contentWorld: .defaultClient
            )
        }
    }

    private func load(_ location: ReaderLocation, recordHistory: Bool) {
        if recordHistory { state.navigate(to: location) }
        beginLoad(location, generation: UUID(), retryCount: 0)
    }

    private func beginLoad(_ location: ReaderLocation, generation: UUID, retryCount: Int) {
        guard let url = context?.url(for: location) else {
            failureMessage = String(localized: "reader.error.unavailable")
            return
        }
        loadGeneration = generation
        loadTimeoutTask?.cancel()
        failureMessage = nil
        tableOfContents = []
        isPerformingModelNavigation = true
        if let activeModelNavigationID {
            navigationLoads.removeValue(forKey: activeModelNavigationID)
        }
        activeModelNavigationID = nil
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        if let navigation = webView.load(request) {
            let navigationID = ObjectIdentifier(navigation)
            activeModelNavigationID = navigationID
            navigationLoads[navigationID] = LoadAttempt(
                generation: generation,
                location: location,
                retryCount: retryCount
            )
        }

        loadTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, let self,
                  loadGeneration == generation,
                  webView.isLoading else { return }
            webView.stopLoading()
            if retryCount == 0 {
                beginLoad(location, generation: generation, retryCount: 1)
            } else {
                isPerformingModelNavigation = false
                if let activeModelNavigationID {
                    navigationLoads.removeValue(forKey: activeModelNavigationID)
                }
                activeModelNavigationID = nil
                isLoading = false
                failureMessage = String(localized: "reader.error.timeout")
            }
        }
    }

    // MARK: - Zoom

    func zoomIn() {
        let next = Self.zoomLevels.first { $0 > webView.pageZoom + 0.001 }
        webView.pageZoom = next ?? Self.zoomLevels[Self.zoomLevels.count - 1]
    }

    func zoomOut() {
        let previous = Self.zoomLevels.last { $0 < webView.pageZoom - 0.001 }
        webView.pageZoom = previous ?? Self.zoomLevels[0]
    }

    func resetZoom() {
        webView.pageZoom = 1.0
    }

    // MARK: - Find in page

    func find(_ text: String, forward: Bool = true) async -> Bool {
        guard !text.isEmpty else { return false }
        let configuration = WKFindConfiguration()
        configuration.backwards = !forward
        configuration.wraps = true
        configuration.caseSensitive = false
        return (try? await webView.find(text, configuration: configuration))?.matchFound ?? false
    }

    // MARK: - Web view observation

    private func observeWebView() {
        observations = [
            webView.observe(\.url, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.webViewURLChanged() }
            },
            webView.observe(\.title, options: [.new]) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.updateTitle(webView.title) }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.isLoading = webView.isLoading }
            },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.loadingProgress = webView.estimatedProgress }
            },
        ]
    }

    /// Records in-page navigations, including fragment changes that never
    /// produce a full page load.
    private func webViewURLChanged() {
        guard let url = webView.url, let location = context?.location(for: url) else { return }
        if isPerformingModelNavigation {
            // A model-driven load already updated history. Keep suppression in
            // place until the matching navigation commits so a late KVO event
            // from a cancelled attempt cannot consume it.
            return
        }
        guard state.current != location else { return }
        state.navigate(to: location)
        tableOfContents = []
    }

    private func updateTitle(_ title: String?) {
        guard let title, !title.isEmpty else { return }
        state.updateCurrentTitle(title)
    }

    fileprivate func navigationDidFinish(_ navigation: WKNavigation?) {
        if let navigation,
           let attempt = loadAttempt(for: navigation) {
            let navigationID = ObjectIdentifier(navigation)
            guard attempt.generation == loadGeneration,
                  activeModelNavigationID == navigationID else { return }
            activeModelNavigationID = nil
        } else {
            // A same-window link initiated by the document is intentionally
            // not in `navigationLoads`. Accept it only when no model-driven
            // load is active, so a late callback cannot overwrite newer state.
            guard !isPerformingModelNavigation else { return }
        }
        loadTimeoutTask?.cancel()
        isPerformingModelNavigation = false
        updateTitle(webView.title)
        scheduleTableOfContentsExtraction()
    }

    fileprivate func navigationDidCommit(_ navigation: WKNavigation?) {
        guard let navigation else { return }
        let navigationID = ObjectIdentifier(navigation)
        guard activeModelNavigationID == navigationID,
              navigationLoads[navigationID]?.generation == loadGeneration else { return }
        isPerformingModelNavigation = false
    }

    fileprivate func navigationDidFail(_ navigation: WKNavigation?, error: any Error) {
        let attempt = loadAttempt(for: navigation)
        if let attempt, let navigation {
            let navigationID = ObjectIdentifier(navigation)
            guard attempt.generation == loadGeneration,
                  activeModelNavigationID == navigationID else { return }
            activeModelNavigationID = nil
        } else {
            guard !isPerformingModelNavigation else { return }
        }
        let nsError = error as NSError
        // A cancelled load is the normal result of the user navigating away.
        guard !(nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled) else { return }
        loadTimeoutTask?.cancel()
        if let attempt,
           nsError.domain == NSURLErrorDomain,
           nsError.code == NSURLErrorTimedOut,
           attempt.retryCount == 0 {
            beginLoad(attempt.location, generation: attempt.generation, retryCount: 1)
            return
        }
        isPerformingModelNavigation = false
        failureMessage = error.localizedDescription
    }

    private func loadAttempt(for navigation: WKNavigation?) -> LoadAttempt? {
        guard let navigation else { return nil }
        return navigationLoads.removeValue(forKey: ObjectIdentifier(navigation))
    }

    // MARK: - Table of contents

    private func scheduleTableOfContentsExtraction() {
        tableOfContentsTask?.cancel()
        tableOfContentsTask = Task { [weak self] in
            guard let self else { return }
            let items = await extractTableOfContents()
            guard !Task.isCancelled else { return }
            tableOfContents = items
        }
    }

    private func extractTableOfContents() async -> [TableOfContentsItem] {
        let script = """
        (function () {
          const headings = document.querySelectorAll("h1, h2, h3, h4");
          const items = [];
          for (const heading of headings) {
            let anchor = heading.id;
            if (!anchor) {
              const marker = heading.querySelector("a[name], a[id]")
                ?? heading.previousElementSibling;
              if (marker && marker.tagName === "A") {
                anchor = marker.getAttribute("id") ?? marker.getAttribute("name") ?? "";
              }
            }
            const title = (heading.textContent ?? "").trim();
            if (!anchor || !title) { continue; }
            items.push({ id: anchor, level: Number(heading.tagName.substring(1)), title: title });
          }
          return items;
        })();
        """

        // The default client world runs app scripts even when page-authored
        // JavaScript is disabled for the docset.
        guard let raw = try? await webView.evaluateJavaScript(
            script,
            in: nil,
            contentWorld: .defaultClient
        ) as? [[String: Any]] else {
            return []
        }

        var seen: Set<String> = []
        return raw.compactMap { entry in
            guard let id = entry["id"] as? String,
                  let title = entry["title"] as? String,
                  let level = entry["level"] as? Int,
                  seen.insert(id).inserted else {
                return nil
            }
            return TableOfContentsItem(id: id, level: level, title: title)
        }
    }

}

/// Applies the reader's navigation policy to the web view.
private final class ReaderNavigator: NSObject, WKNavigationDelegate, WKUIDelegate {
    weak var owner: ReaderTab?
    private weak var context: (any ReaderDocumentContext)?
    private var lastNewWindowRoute: (url: URL, instant: ContinuousClock.Instant)?

    init(context: any ReaderDocumentContext) {
        self.context = context
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences
    ) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        guard let url = navigationAction.request.url else {
            return (.cancel, preferences)
        }

        // WebKit asks its UI delegate to create a view for target=_blank and
        // window.open. Route the request here because policy evaluation is the
        // one callback WebKit consistently delivers even when the view is not
        // attached to an AppKit window (as in integration tests and restores).
        if navigationAction.targetFrame == nil {
            routeNewWindowURL(url)
            return (.cancel, preferences)
        }

        guard let location = context?.location(for: url) else {
            // Anything that is not a served docset page belongs to the browser,
            // which also keeps http:// pages from ever rendering inside Crux.
            if let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                context?.openExternalURL(url)
            }
            return (.cancel, preferences)
        }

        // Apply the parsed docset policy, including explicit script opt-outs.
        preferences.allowsContentJavaScript =
            context?.isJavaScriptEnabled(forDocset: location.docsetIdentifier) ?? false
        return (.allow, preferences)
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // JavaScript `window.open` can arrive here without a separate policy
        // callback, while target=_blank normally arrives in both callbacks.
        // `routeNewWindowURL` coalesces those duplicate notifications.
        if let url = navigationAction.request.url { routeNewWindowURL(url) }
        return nil
    }

    private func routeNewWindowURL(_ url: URL) {
        let now = ContinuousClock().now
        if let lastNewWindowRoute,
           now - lastNewWindowRoute.instant < .milliseconds(250) {
            return
        }
        lastNewWindowRoute = (url, now)
        if let location = context?.location(for: url) {
            context?.openDocument(location, inNewTab: true)
        } else if let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            context?.openExternalURL(url)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        owner?.navigationDidFinish(navigation)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        owner?.navigationDidCommit(navigation)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        owner?.navigationDidFail(navigation, error: error)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: any Error
    ) {
        owner?.navigationDidFail(navigation, error: error)
    }
}

private struct LoadAttempt {
    let generation: UUID
    let location: ReaderLocation
    let retryCount: Int
}
