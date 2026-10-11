import CruxCore
import Foundation
import SwiftUI

/// One tab's complete workspace: action bar, search panel, welcome page,
/// reader content and transient find/TOC controls.
struct ReaderView: View {
    @Bindable var model: AppModel
    @Bindable var tab: ReaderTab
    @Environment(\.openSettings) private var openSettings
    @State private var searchFocusRequest = 0
    @State private var isSearchPanelPresented = false
    @State private var isFindBarVisible = false
    @State private var findText = ""
    @State private var hasFindMatch = true
    @State private var isTableOfContentsVisible = false

    var body: some View {
        VStack(spacing: 0) {
            if isFindBarVisible, !tab.isWelcome {
                findBar
                Divider()
            }

            if tab.isWelcome {
                welcome
            } else {
                document
            }
        }
        .safeAreaBar(edge: .top, spacing: 0) { workspaceBar }
        .onReceive(NotificationCenter.default.publisher(for: .cruxFocusSearchField)) { _ in
            if model.selectedTabID == tab.id {
                searchFocusRequest &+= 1
                isSearchPanelPresented = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .cruxToggleFindBar)) { _ in
            if model.selectedTabID == tab.id { isFindBarVisible.toggle() }
        }
        .onChange(of: tab.currentLocation) { _, _ in
            model.scheduleSessionSave()
        }
        .onChange(of: model.selectedTabID) { _, selectedID in
            if selectedID != tab.id { isSearchPanelPresented = false }
        }
        .onDisappear { isSearchPanelPresented = false }
    }

    private var welcome: some View {
        VStack(spacing: 16) {
            Image(systemName: "books.vertical")
                .font(.system(size: 52, weight: .regular))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            Text("app.welcome.title")
                .font(.largeTitle)
                .fontWeight(.semibold)
                .accessibilityElement()
                .accessibilityLabel("app.welcome.title")
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("welcome-title")

            Text("app.welcome.description")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)

            HStack(spacing: 12) {
                welcomeButton(
                    title: "app.welcome.downloadDocsets",
                    systemImage: "arrow.down.circle",
                    section: .available
                )
                welcomeButton(
                    title: "app.welcome.manageDocsets",
                    systemImage: "books.vertical.fill",
                    section: .installed
                )
            }
            .padding(.top, 8)

            if let startupError = model.startupError {
                Label(startupError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.top, 8)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func welcomeButton(
        title: LocalizedStringKey,
        systemImage: String,
        section: DocsetsSettingsSection
    ) -> some View {
        Button {
            model.selectDocsetSettings(section)
            openSettings()
        } label: {
            Label(title, systemImage: systemImage)
                .frame(minWidth: 180, minHeight: 34)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    private var document: some View {
        HStack(spacing: 0) {
            DocumentWebView(tab: tab)
                .overlay(alignment: .top) {
                    if tab.isLoading {
                        ProgressView(value: tab.loadingProgress)
                            .progressViewStyle(.linear)
                            .accessibilityLabel("reader.progress.accessibilityLabel")
                    }
                }
                .overlay(alignment: .bottom) {
                    if let failureMessage = tab.failureMessage {
                        HStack(spacing: 10) {
                            Label(failureMessage, systemImage: "exclamationmark.triangle")
                            Button("reader.action.retry") { tab.retryAfterFailure() }
                        }
                        .font(.callout)
                        .padding(10)
                        .background(.regularMaterial, in: .rect(cornerRadius: 8))
                        .padding(12)
                    }
                }

            if isTableOfContentsVisible, !tab.tableOfContents.isEmpty {
                Divider()
                TableOfContentsView(tab: tab)
                    .frame(width: 220)
            }
        }
    }

    private var findBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("reader.find.placeholder", text: $findText)
                .textFieldStyle(.plain)
                .onSubmit { performFind(forward: true) }
                .accessibilityIdentifier("find-field")
            if !hasFindMatch, !findText.isEmpty {
                Text("reader.find.noMatches")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("reader.find.previous") { performFind(forward: false) }
            Button("reader.find.next") { performFind(forward: true) }
            Button("reader.find.done") { isFindBarVisible = false }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private func performFind(forward: Bool) {
        Task { hasFindMatch = await tab.find(findText, forward: forward) }
    }

    private var workspaceBar: some View {
        ViewThatFits(in: .horizontal) {
            wideWorkspaceBar
                .frame(minWidth: 800)
            compactWorkspaceBar
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reader-workspace-bar")
    }

    private var wideWorkspaceBar: some View {
        ZStack {
            HStack(spacing: 12) {
                navigationActions
                Spacer(minLength: 560)
                readerActions
            }

            searchControl
                .frame(width: 520)
        }
    }

    private var compactWorkspaceBar: some View {
        HStack(spacing: 8) {
            navigationActions

            searchControl
                .layoutPriority(1)

            Menu {
                Button {
                    tab.reload()
                } label: {
                    Label("reader.action.reload", systemImage: "arrow.clockwise")
                }
                .disabled(tab.currentLocation == nil)

                Button {
                    isTableOfContentsVisible.toggle()
                } label: {
                    Label("reader.action.tableOfContents", systemImage: "list.bullet.indent")
                }
                .disabled(tab.tableOfContents.isEmpty)

                Button {
                    isFindBarVisible.toggle()
                } label: {
                    Label("reader.action.find", systemImage: "text.magnifyingglass")
                }
                .disabled(tab.isWelcome)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(width: 28, height: 28)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .glassEffect(.regular.interactive(), in: Circle())
            .help("reader.action.tableOfContents")
        }
    }

    private var searchControl: some View {
        ReaderSearchToolbar(
            model: model,
            tab: tab,
            isActive: model.selectedTabID == tab.id,
            focusRequest: searchFocusRequest,
            isPanelPresented: $isSearchPanelPresented,
            onSubmit: submitSearch
        )
        .frame(height: 36)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reader-search-control")
    }

    private var navigationActions: some View {
        HStack(spacing: 4) {
            Button {
                tab.goBack()
            } label: {
                Label("reader.action.back", systemImage: "chevron.backward")
                    .labelStyle(.iconOnly)
                    .frame(width: 34, height: 32)
            }
            .disabled(!tab.canGoBack)
            .frame(width: 34, height: 32)
            .contentShape(Rectangle())
            .help("reader.action.back")

            Button {
                tab.goForward()
            } label: {
                Label("reader.action.forward", systemImage: "chevron.forward")
                    .labelStyle(.iconOnly)
                    .frame(width: 34, height: 32)
            }
            .disabled(!tab.canGoForward)
            .frame(width: 34, height: 32)
            .contentShape(Rectangle())
            .help("reader.action.forward")

            Button {
                model.goHome(in: tab)
            } label: {
                Label("reader.action.home", systemImage: "house")
                    .labelStyle(.iconOnly)
                    .frame(width: 34, height: 32)
            }
            .frame(width: 34, height: 32)
            .contentShape(Rectangle())
            .help("reader.action.home")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 4)
        .frame(height: 36)
        .glassEffect(.regular, in: Capsule())
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reader-navigation-actions")
    }

    private var readerActions: some View {
        HStack(spacing: 4) {
            Button {
                tab.reload()
            } label: {
                Label("reader.action.reload", systemImage: "arrow.clockwise")
                    .labelStyle(.iconOnly)
                    .frame(width: 34, height: 32)
            }
            .disabled(tab.currentLocation == nil)
            .frame(width: 34, height: 32)
            .contentShape(Rectangle())
            .help("reader.action.reload")

            Button {
                isTableOfContentsVisible.toggle()
            } label: {
                Label("reader.action.tableOfContents", systemImage: "list.bullet.indent")
                    .labelStyle(.iconOnly)
                    .frame(width: 34, height: 32)
            }
            .disabled(tab.tableOfContents.isEmpty)
            .frame(width: 34, height: 32)
            .contentShape(Rectangle())
            .help("reader.action.tableOfContents")

            Button {
                isFindBarVisible.toggle()
            } label: {
                Label("reader.action.find", systemImage: "text.magnifyingglass")
                    .labelStyle(.iconOnly)
                    .frame(width: 34, height: 32)
            }
            .disabled(tab.isWelcome)
            .frame(width: 34, height: 32)
            .contentShape(Rectangle())
            .help("reader.action.find")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 4)
        .frame(height: 36)
        .glassEffect(.regular, in: Capsule())
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reader-actions")
    }

    private func submitSearch() {
        guard let first = tab.search.groupedResults.first?.representative
                ?? tab.search.results.first else {
            if let page = tab.search.fullTextResults.first {
                model.open(page)
                isSearchPanelPresented = false
            }
            return
        }
        model.open(first)
        isSearchPanelPresented = false
    }
}
