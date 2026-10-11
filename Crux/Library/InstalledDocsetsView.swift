import CruxCore
import Foundation
import SwiftUI

/// Installed docsets: update, uninstall (with confirmation) and offline volume state.
struct InstalledDocsetsView: View {
    @Bindable var model: AppModel
    @State private var pendingUninstall: InstalledDocset?
    @State private var pendingPolicies: [String: DocsetSelectionPolicy] = [:]
    @State private var pendingConfirmation: [DocsetInstallChoice]?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Spacer()
                Button {
                    Task { await model.refreshLibrary() }
                } label: {
                    Label("menu.file.refreshLibrary", systemImage: "arrow.clockwise")
                }
                .labelStyle(.titleAndIcon)

                Button {
                    Task { await model.checkForUpdates() }
                } label: {
                    Label("library.installed.checkUpdates", systemImage: "arrow.triangle.2.circlepath")
                }
                .labelStyle(.titleAndIcon)

                Button {
                    Task { await model.updateAllDocsets() }
                } label: {
                    Label("library.installed.updateAll", systemImage: "arrow.down.circle")
                }
                .labelStyle(.titleAndIcon)
                .disabled(model.availableUpdates.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("installed-action-bar")

            Divider()

            Group {
                if model.installed.isEmpty {
                    LibraryEmptyState(
                        title: "library.installed.empty",
                        systemImage: "books.vertical"
                    )
                } else {
                    List {
                        ForEach(groups) { group in
                            if model.showsInstalledSourceNames {
                                Section {
                                    installedRows(group.items)
                                } header: {
                                    Text(group.name)
                                        .accessibilityIdentifier(SourcePresentation.accessibilityID("installed-source", sourceID: group.id))
                                }
                            } else {
                                installedRows(group.items)
                            }
                        }
                    }
                }
            }
        }
        .modifier(DocsetReplacementConfirmation(choices: $pendingConfirmation) { choices in
            Task {
                for choice in choices {
                    if let item = choice.sourcedEntry { await model.installCatalogEntry(item, selection: choice.policy) }
                    else if model.sourceLibrary == nil { await model.installCatalogEntry(choice.entry, selection: choice.policy) }
                }
            }
        } cancel: { choices in
            for choice in choices {
                if let id = choice.installed?.identifier { pendingPolicies[id] = nil }
            }
        })
        .confirmationDialog(
            "library.uninstall.confirm.title",
            isPresented: Binding(
                get: { pendingUninstall != nil },
                set: { if !$0 { pendingUninstall = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("library.uninstall.confirm", role: .destructive) {
                if let record = pendingUninstall {
                    Task { await model.uninstall(record) }
                }
                pendingUninstall = nil
            }
            Button("library.action.cancel", role: .cancel) {
                pendingUninstall = nil
            }
        } message: {
            Text("library.uninstall.confirm.message \(pendingUninstall.map { model.docsetDisplayName(for: $0.descriptor) } ?? "")")
        }
    }

    private var groups: [SourceDocsetGroup<InstalledDocset>] {
        SourcePresentation.installedGroups(model.installed, sources: model.sources) { model.sourceDisplayName(for: $0) }
    }

    private func installedRows(_ records: [InstalledDocset]) -> some View {
        ForEach(records, id: \.identifier) { record in
            InstalledRow(record: record,
                         title: model.docsetDisplayName(for: record.descriptor),
                         sourceName: model.sourceDisplayName(for: record),
                         item: model.catalogItem(forInstalledDocset: record),
                         usesLegacyTestIDs: model.sourceLibrary == nil,
                         policy: policyBinding(for: record), isBusy: isBusy(record),
                         switchVersion: { if let choice = choice(for: record) { pendingConfirmation = [choice] } },
                         canSwitch: choice(for: record) != nil,
                         hasUpdate: model.availableUpdates[record.identifier] != nil,
                         catalogIconData: model.catalogItem(forInstalledDocset: record)?.entry.iconData) {
                Task { await model.updateDocset(record) }
            } uninstall: {
                pendingUninstall = record
            }
        }
    }

    private func policyBinding(for record: InstalledDocset) -> Binding<DocsetSelectionPolicy> {
        Binding(get: { pendingPolicies[record.identifier] ?? record.selectionPolicy },
                set: { pendingPolicies[record.identifier] = $0 })
    }

    private func isBusy(_ record: InstalledDocset) -> Bool {
        if let item = model.catalogItem(forInstalledDocset: record), model.isTransferring(item) { return true }
        return model.transferJobs.contains { job in
            job.isActive && (job.installationIdentifier == record.identifier
                || (record.installTarget != nil && job.target?.slotKey == record.installTarget?.slotKey))
        }
    }

    private func choice(for record: InstalledDocset) -> DocsetInstallChoice? {
        guard let entry = model.catalogItem(forInstalledDocset: record) else { return nil }
        if model.sourceLibrary == nil {
            return DocsetInstallChoice(entry: entry.entry, policy: policyBinding(for: record).wrappedValue,
                                       installed: record, isBusy: isBusy(record))
        }
        return DocsetInstallChoice(entry: entry, policy: policyBinding(for: record).wrappedValue,
                                   installed: record, isBusy: isBusy(record))
    }
}

private struct InstalledRow: View {
    let record: InstalledDocset
    let title: String
    let sourceName: String
    let item: SourcedCatalogEntry?
    let usesLegacyTestIDs: Bool
    private var entry: CatalogEntry? { item?.entry }
    @Binding var policy: DocsetSelectionPolicy
    let isBusy: Bool
    let switchVersion: () -> Void
    let canSwitch: Bool
    let hasUpdate: Bool
    let catalogIconData: Data?
    let update: () -> Void
    let uninstall: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            DocsetIconView(
                descriptor: record.descriptor,
                catalogData: catalogIconData,
                size: DocsetIconMetrics.compact
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let entry, entry.supportsVersionSelection {
                DocsetVersionPicker(entry: entry, selection: $policy,
                                    installedReleaseID: record.installTarget?.release.id, isBusy: isBusy)
                    .accessibilityIdentifier(usesLegacyTestIDs ? "docset-version-picker-\(entry.id)" : "installed-version-picker-\(record.identifier)")
                Button("library.version.switch", action: switchVersion)
                    .disabled(!canSwitch)
                    .accessibilityIdentifier("docset-switch-\(usesLegacyTestIDs ? entry.id : item?.id ?? record.identifier)")
            } else if record.installTarget != nil {
                Text("library.version.unavailable")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !record.isReachable {
                Text("library.installed.offline")
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                    .accessibilityLabel("library.status.offline")
            }
            if hasUpdate {
                Button("library.installed.update", action: update)
                    .disabled(isBusy)
            }
            Button("library.installed.uninstall", role: .destructive, action: uninstall)
                .disabled(isBusy)
        }
        // Keep the toggle and action buttons as separate VoiceOver targets.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("installed-docset-\(record.identifier)")
    }

    private var subtitle: String {
        var parts: [String] = []
        if let version = record.descriptor.version { parts.append(version) }
        if case .pinnedRelease = record.selectionPolicy { parts.append(String(localized: "library.version.pinned")) }
        parts.append(sourceName)
        return parts.joined(separator: " · ")
    }
}
