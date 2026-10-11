import CruxCore
import Foundation
import SwiftUI

/// The Dash-style search panel, populated as a small navigation hierarchy
/// rather than a flat completion list.
struct SearchSuggestionsView: View {
    @Bindable var model: AppModel
    @Bindable var tab: ReaderTab
    let dismiss: () -> Void

    @ViewBuilder
    var body: some View {
        switch tab.search.currentRoute {
        case .docsets:
            docsets
        case let .docset(identifier):
            docset(identifier)
        case let .symbolType(identifier, type):
            symbolType(identifier: identifier, type: type)
        case .results:
            results
        case let .nested(key):
            nested(key)
        }
    }

    private var docsets: some View {
        Group {
            panelHeader(String(localized: "search.panel.docsets"), canGoBack: false)
            if model.docsets.isEmpty {
                Label("library.installed.empty", systemImage: "books.vertical")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.docsets.filter { tab.search.prefixChoiceIdentifiers.isEmpty || tab.search.prefixChoiceIdentifiers.contains($0.identifier) }, id: \.identifier) { descriptor in
                    Button {
                        tab.search.showDocset(descriptor.identifier)
                    } label: {
                        HStack(spacing: 9) {
                            DocsetLabel(
                                descriptor: descriptor,
                                catalogData: model.catalogIconData(forDocset: descriptor.identifier),
                                displayName: model.docsetDisplayName(for: descriptor)
                            )
                            Spacer(minLength: 24)
                            Text(descriptor.keywords.first.map { "\($0):" } ?? "")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.forward")
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("search-docset-\(descriptor.identifier)")
                }
            }
        }
    }

    @ViewBuilder
    private func docset(_ identifier: String) -> some View {
        let descriptor = model.docsets.first { $0.identifier == identifier }
        panelHeader(descriptor.map { model.docsetDisplayName(for: $0) } ?? identifier, canGoBack: true)

        if let descriptor {
            if descriptor.indexPagePath != nil {
                Button {
                    model.openLandingPage(for: descriptor)
                    dismiss()
                } label: {
                    Label("search.panel.mainPage", systemImage: "doc.richtext")
                }
                .buttonStyle(.plain)
            }

            fullTextAction(for: descriptor)

            ForEach(tab.search.symbolTypeSummaries, id: \.self) { summary in
                Button {
                    tab.search.showSymbolType(summary.type, in: identifier)
                } label: {
                    HStack(spacing: 9) {
                        SymbolTypeBadge(type: summary.type)
                        Text(summary.type)
                        Spacer(minLength: 24)
                        Text("\(summary.count) \(summary.type.lowercased())")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.forward")
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }

            if tab.search.isBrowsing {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private func symbolType(identifier: String, type: String) -> some View {
        panelHeader(type, canGoBack: true)
        if tab.search.isBrowsing {
            ProgressView()
                .controlSize(.small)
        }
        ForEach(Array(tab.search.browsedSymbols.prefix(250)), id: \.self) { result in
            leafButton(result)
        }
    }

    @ViewBuilder
    private var results: some View {
        panelHeader(
            String(localized: "search.panel.results") + " \"\(tab.search.query)\"",
            canGoBack: true
        )

        if !tab.search.groupedResults.isEmpty {
            Section("search.section.symbols") {
                ForEach(Array(tab.search.groupedResults.prefix(100))) { group in
                    if group.hasSimilarResults {
                        Button {
                            tab.search.showNestedResults(for: group.key)
                        } label: {
                            SearchResultRow(
                                result: group.representative,
                                descriptor: descriptor(for: group.representative),
                                catalogIconData: model.catalogIconData(
                                    forDocset: group.representative.docsetIdentifier
                                ),
                                similarResultCount: group.similarResultCount,
                                docsetTitle: descriptor(for: group.representative).flatMap { model.searchDocsetTitle(for: $0) }
                            )
                        }
                        .buttonStyle(.plain)
                        .contextMenu { openInNewTabButton(group.representative) }
                    } else {
                        leafButton(group.representative)
                    }
                }
            }
        }

        if !tab.search.fullTextResults.isEmpty {
            Section("search.section.pages") {
                ForEach(Array(tab.search.fullTextResults.prefix(40)), id: \.self) { result in
                    Button {
                        model.open(result)
                        dismiss()
                    } label: {
                        FullTextResultRow(
                            result: result,
                            descriptor: model.docsets.first { $0.identifier == result.docsetIdentifier },
                            catalogIconData: model.catalogIconData(forDocset: result.docsetIdentifier),
                            docsetTitle: model.docsets.first { $0.identifier == result.docsetIdentifier }.flatMap { model.searchDocsetTitle(for: $0) }
                        )
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("search.action.openInNewTab") {
                            model.open(result, inNewTab: true)
                            dismiss()
                        }
                    }
                }
            }
        }

        if tab.search.isSearching {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("search.field.accessibilityLabel")
        } else if tab.search.results.isEmpty && tab.search.fullTextResults.isEmpty {
            Label("search.empty.noMatches.title", systemImage: "magnifyingglass")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func nested(_ key: SymbolSearchGroupKey) -> some View {
        if let group = tab.search.nestedGroup(for: key) {
            panelHeader(
                String(localized: "search.panel.similarResults") + " \(group.similarResultCount)",
                canGoBack: true
            )
            ForEach(group.results, id: \.self) { result in
                leafButton(result)
            }
        } else {
            panelHeader(String(localized: "search.panel.results"), canGoBack: true)
        }
    }

    private func panelHeader(_ title: String, canGoBack: Bool) -> some View {
        HStack {
            if canGoBack {
                Button {
                    tab.search.goBack()
                } label: {
                    Image(systemName: "chevron.backward")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("reader.action.back")
            }
            Spacer()
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
                .accessibilityLabel(title)
                .accessibilityIdentifier("search-panel-title")
            Spacer()
            if canGoBack {
                Image(systemName: "chevron.backward")
                    .hidden()
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 3)
    }

    private func leafButton(_ result: SymbolSearchResult) -> some View {
        Button {
            model.open(result)
            dismiss()
        } label: {
            SearchResultRow(
                result: result,
                descriptor: descriptor(for: result),
                catalogIconData: model.catalogIconData(forDocset: result.docsetIdentifier),
                docsetTitle: descriptor(for: result).flatMap { model.searchDocsetTitle(for: $0) }
            )
        }
        .buttonStyle(.plain)
        .contextMenu { openInNewTabButton(result) }
    }

    private func openInNewTabButton(_ result: SymbolSearchResult) -> some View {
        Button("search.action.openInNewTab") {
            model.open(result, inNewTab: true)
            dismiss()
        }
    }

    @ViewBuilder
    private func fullTextAction(for descriptor: DocsetDescriptor) -> some View {
        let state = model.fullTextStates[descriptor.identifier]
        switch state?.phase ?? .disabled {
        case .disabled:
            Button {
                Task { await model.enableFullTextSearch(for: descriptor) }
            } label: {
                Label("fullText.enable", systemImage: "doc.text.magnifyingglass")
            }
            .buttonStyle(.plain)
        case .pending, .indexing:
            HStack {
                ProgressView(
                    value: Double(state?.indexedDocumentCount ?? 0),
                    total: Double(max(state?.totalDocumentCount ?? 1, 1))
                )
                Text("fullText.status.indexing")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("fullText.cancel") {
                    model.cancelFullTextIndexing(for: descriptor.identifier)
                }
                .controlSize(.small)
            }
        case .interrupted, .failed:
            Button {
                Task { await model.enableFullTextSearch(for: descriptor) }
            } label: {
                Label("fullText.resume", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.plain)
        case .ready:
            Label("fullText.enabled", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.secondary)
        }
    }

    private func descriptor(for result: SymbolSearchResult) -> DocsetDescriptor? {
        model.docsets.first { $0.identifier == result.docsetIdentifier }
    }
}

private struct FullTextResultRow: View {
    let result: FullTextSearchResult
    let descriptor: DocsetDescriptor?
    let catalogIconData: Data?
    var docsetTitle: String?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            DocsetIconView(
                descriptor: descriptor,
                catalogData: catalogIconData,
                size: DocsetIconMetrics.compact
            )
            Image(systemName: "doc.text")
                .frame(width: 18, height: 18)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(result.title).lineLimit(1)
                if let docsetTitle { Text(docsetTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                Text(result.excerpt)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(result.title), \(docsetTitle ?? result.docsetName)")
    }
}

private struct SearchResultRow: View {
    let result: SymbolSearchResult
    let descriptor: DocsetDescriptor?
    let catalogIconData: Data?
    var similarResultCount: Int?
    var docsetTitle: String?

    init(
        result: SymbolSearchResult,
        descriptor: DocsetDescriptor?,
        catalogIconData: Data?,
        similarResultCount: Int? = nil, docsetTitle: String? = nil
    ) {
        self.result = result
        self.descriptor = descriptor
        self.catalogIconData = catalogIconData
        self.similarResultCount = similarResultCount
        self.docsetTitle = docsetTitle
    }

    var body: some View {
        HStack(spacing: 8) {
            DocsetIconView(
                descriptor: descriptor,
                catalogData: catalogIconData,
                size: DocsetIconMetrics.compact
            )
            SymbolTypeBadge(type: result.type)
            highlightedName
                .lineLimit(1)
            if let contextName = result.contextName, !contextName.isEmpty {
                Text(contextName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            if let docsetTitle { Text(docsetTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            if let similarResultCount, similarResultCount > 1 {
                Text("\(similarResultCount) \(String(localized: "search.panel.similarResults"))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.forward")
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var highlightedName: Text {
        let matches = Set(result.matchPositions)
        var attributed = AttributedString()
        for (offset, character) in result.name.enumerated() {
            var segment = AttributedString(String(character))
            if matches.contains(offset) {
                segment.foregroundColor = .accentColor
                segment.underlineStyle = .single
            }
            attributed.append(segment)
        }
        return Text(attributed)
    }

    private var accessibilityLabel: String {
        [docsetTitle ?? result.docsetName, result.type, result.name, result.contextName]
            .compactMap { $0 }
            .joined(separator: ", ")
    }
}

enum SymbolTypeBadgePalette: String, CaseIterable {
    case blue
    case orange
    case purple
    case teal
    case green
    case indigo
    case pink
    case cyan
    case brown
    case mint
    case yellow

    static func token(for type: String) -> Self {
        let normalized = type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return switch normalized {
        case "class": .blue
        case "constant": .orange
        case "constructor": .purple
        case "element": .teal
        case "field": .green
        case "interface": .indigo
        case "method": .pink
        case "module": .cyan
        case "package": .brown
        case "property": .mint
        case "section": .yellow
        default:
            allCases[normalized.unicodeScalars.reduce(0) {
                ($0 &* 31 &+ Int($1.value)) % allCases.count
            }]
        }
    }

    var color: Color {
        switch self {
        case .blue: .blue
        case .orange: .orange
        case .purple: .purple
        case .teal: .teal
        case .green: .green
        case .indigo: .indigo
        case .pink: .pink
        case .cyan: .cyan
        case .brown: .brown
        case .mint: .mint
        case .yellow: .yellow
        }
    }
}

private struct SymbolTypeBadge: View {
    let type: String

    var body: some View {
        let palette = SymbolTypeBadgePalette.token(for: type)
        Text(type.prefix(1).uppercased())
            .font(.caption2.monospaced().weight(.semibold))
            .frame(width: DocsetIconMetrics.compact, height: DocsetIconMetrics.compact)
            .foregroundStyle(.primary)
            .background(palette.color.opacity(0.24), in: .rect(cornerRadius: 4))
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(palette.color.opacity(0.35), lineWidth: 0.5)
            }
            .accessibilityHidden(true)
    }
}

extension Notification.Name {
    static let cruxFocusSearchField = Notification.Name("dev.crux.focusSearchField")
    static let cruxToggleFindBar = Notification.Name("dev.crux.toggleFindBar")
}
