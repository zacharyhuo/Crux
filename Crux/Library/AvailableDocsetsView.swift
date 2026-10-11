import CruxCore
import SwiftUI

/// Enabled sources: search, multi-select and source-scoped installation choices.
struct AvailableDocsetsView: View {
    @Bindable var model: AppModel
    @State private var filter = ""
    @State private var selection: Set<String> = []
    @State private var pendingPolicies: [String: DocsetSelectionPolicy] = [:]
    @State private var pendingConfirmation: [DocsetInstallChoice]?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("library.available.search", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 220, maxWidth: 340)
                Spacer()
                Button {
                    Task { await model.refreshCatalog() }
                } label: {
                    Label("library.available.refresh", systemImage: "arrow.clockwise")
                }
                .labelStyle(.titleAndIcon)
                .help("library.available.refresh")
                .disabled(model.enabledSourceCount == 0)
                .accessibilityIdentifier("catalog-refresh-enabled-sources")

                Button {
                    let choices = selectedChoices
                    if choices.contains(where: \.requiresReplacement) { pendingConfirmation = choices }
                    else { install(choices) }
                } label: {
                    Label(
                        LocalizedStringKey(selectedChoices.contains(where: \.requiresReplacement) ? "library.version.switch" : "library.available.download"),
                        systemImage: "arrow.down.circle"
                    )
                }
                .labelStyle(.titleAndIcon)
                .help(LocalizedStringKey(selectedChoices.contains(where: \.requiresReplacement) ? "library.version.switch" : "library.available.download"))
                .disabled(selectedChoices.isEmpty)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("catalog-install-selection")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("available-action-bar")

            Divider()

            if model.sourceLibrary == nil, model.catalogIsFromCache, !model.catalog.isEmpty {
                Text("library.available.cached")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }

            if model.sourceLibrary == nil {
                // Explicitly injected test catalogs have no persisted source configurations.
                if filtered.isEmpty {
                    LibraryEmptyState(title: "library.available.empty", systemImage: "square.and.arrow.down")
                } else {
                    List(selection: $selection) { catalogRows(filtered) }
                }
            } else if groups.isEmpty {
                LibraryEmptyState(
                    title: "library.sources.noEnabled",
                    systemImage: "square.and.arrow.down"
                )
            } else {
                List(selection: $selection) {
                    ForEach(groups) { group in
                        if model.enabledSourceCount > 1 {
                            Section {
                                sourceContents(group)
                            } header: {
                                Text(group.name)
                                    .accessibilityIdentifier(SourcePresentation.accessibilityID("catalog-source", sourceID: group.id))
                            }
                        } else {
                            sourceContents(group)
                        }
                    }
                }
            }
        }
        .modifier(DocsetReplacementConfirmation(choices: $pendingConfirmation, confirm: install) { choices in
            for choice in choices { pendingPolicies[choice.id] = nil }
        })
    }

    private var filtered: [SourcedCatalogEntry] {
        let enabledIDs = Set(model.sources.filter(\.canFetch).map(\.id))
        let entries = model.availableDocsets.filter {
            model.sourceLibrary == nil || enabledIDs.contains($0.sourceConfigurationID)
        }
        let needle = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return entries }
        return entries.filter { item in
            item.entry.title.localizedCaseInsensitiveContains(needle)
                || item.entry.name.localizedCaseInsensitiveContains(needle)
                || item.sourceName.localizedCaseInsensitiveContains(needle)
                || item.entry.keywords.contains { $0.localizedCaseInsensitiveContains(needle) }
        }
    }

    private var groups: [SourceDocsetGroup<SourcedCatalogEntry>] {
        SourcePresentation.availableGroups(sources: model.sources, entries: filtered)
    }

    @ViewBuilder
    private func sourceContents(_ group: SourceDocsetGroup<SourcedCatalogEntry>) -> some View {
        if let source = model.sources.first(where: { $0.id == group.id }) {
            HStack(alignment: .top) {
                SourceRefreshStatus(sourceID: source.id,
                                    isRefreshing: model.sourceStates[source.id]?.isRefreshing ?? false,
                                    message: model.sourceStates[source.id]?.message,
                                    fetchedAt: model.sourceStates[source.id]?.fetchedAt,
                                    isFromCache: model.sourceStates[source.id]?.isFromCache ?? false)
                Spacer()
                Button("library.sources.refresh") { Task { await model.refreshSource(source) } }
                    .disabled(model.sourceStates[source.id]?.isRefreshing ?? false)
                    .accessibilityIdentifier(SourcePresentation.accessibilityID("catalog-source-refresh", sourceID: source.id))
            }
            .selectionDisabled()
        }
        if group.items.isEmpty {
            Text(LocalizedStringKey(filter.isEmpty ? "library.sources.noEntries" : "library.available.empty"))
                .foregroundStyle(.secondary)
                .selectionDisabled()
        }
        catalogRows(group.items)
    }

    private func rowID(_ item: SourcedCatalogEntry) -> String {
        model.sourceLibrary == nil ? item.entry.id : item.id
    }

    private func catalogRows(_ items: [SourcedCatalogEntry]) -> some View {
        ForEach(items) { item in
            CatalogRow(item: item, id: rowID(item),
                       title: SourcePresentation.title(item.entry.title, sourceName: item.sourceName, enabledSourceCount: model.enabledSourceCount),
                       installed: model.installedRecord(for: item), selection: policyBinding(for: item), isBusy: model.isTransferring(item))
                .tag(rowID(item))
        }
    }

    private func policyBinding(for entry: SourcedCatalogEntry) -> Binding<DocsetSelectionPolicy> {
        Binding(
            get: { pendingPolicies[rowID(entry)] ?? model.installedRecord(for: entry)?.selectionPolicy ?? .latest },
            set: { pendingPolicies[rowID(entry)] = $0 }
        )
    }

    private var selectedChoices: [DocsetInstallChoice] {
        filtered.filter { selection.contains(rowID($0)) }.compactMap { entry in
            let policy = policyBinding(for: entry).wrappedValue
            let installed = model.installedRecord(for: entry)
            let isBusy = model.isTransferring(entry)
            if model.sourceLibrary == nil {
                return DocsetInstallChoice(entry: entry.entry, policy: policy, installed: installed, isBusy: isBusy)
            }
            return DocsetInstallChoice(entry: entry, policy: policy, installed: installed, isBusy: isBusy)
        }
    }

    private func install(_ choices: [DocsetInstallChoice]) {
        Task {
            for choice in choices {
                if let item = choice.sourcedEntry { await model.installCatalogEntry(item, selection: choice.policy) }
                else if model.sourceLibrary == nil { await model.installCatalogEntry(choice.entry, selection: choice.policy) }
            }
        }
    }
}

private struct CatalogRow: View {
    let item: SourcedCatalogEntry
    let id: String
    let title: String
    let installed: InstalledDocset?
    @Binding var selection: DocsetSelectionPolicy
    let isBusy: Bool
    private var entry: CatalogEntry { item.entry }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            DocsetIconView(
                descriptor: nil,
                catalogData: entry.iconData,
                fallbackName: entry.title,
                size: DocsetIconMetrics.compact
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if entry.supportsVersionSelection {
                DocsetVersionPicker(entry: entry, selection: $selection,
                                    installedReleaseID: installed?.installTarget?.release.id, isBusy: isBusy)
                    .accessibilityIdentifier("docset-version-picker-\(id)")
            }
            if let installed {
                Text("library.version.installed \(installed.descriptor.version ?? "—")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("catalog-docset-\(id)")
    }

    private var subtitle: String {
        var parts = [entry.name]
        if let version = entry.version { parts.append(version) }
        return parts.joined(separator: " · ")
    }
}
