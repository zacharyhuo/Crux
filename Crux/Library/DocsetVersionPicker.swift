import CruxCore
import SwiftUI

/// A native popup with view-local pending selection. Never starts a transfer.
struct DocsetVersionPicker: View {
    let entry: CatalogEntry
    @Binding var selection: DocsetSelectionPolicy
    let installedReleaseID: String?
    let isBusy: Bool

    var body: some View {
        Picker("library.version.label", selection: $selection) {
            if let latest = try? entry.resolve(.latest) {
                Text("library.version.latest \(versionLabel(latest))")
                    .tag(DocsetSelectionPolicy.latest)
            }
            ForEach(sortedReleases) { release in
                Text(optionLabel(release))
                    .tag(DocsetSelectionPolicy.pinnedRelease(release.id))
            }
            if case let .pinnedRelease(id) = selection, !entry.releases.contains(where: { $0.id == id }) {
                Text("library.version.unavailable")
                    .tag(selection)
                    .disabled(true)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(width: 230)
        .disabled(isBusy)
        .help("library.version.help")
        .accessibilityLabel("library.version.label")
        .accessibilityIdentifier("docset-version-picker-\(entry.id)")
    }

    private var sortedReleases: [DocsetRelease] {
        entry.releases.sorted {
            if $0.advertisedVersion != $1.advertisedVersion { return $0.advertisedVersion > $1.advertisedVersion }
            return $0.id < $1.id
        }
    }

    private func versionLabel(_ release: DocsetRelease) -> String {
        "\(release.version) · r\(release.revision)"
    }

    private func optionLabel(_ release: DocsetRelease) -> String {
        var parts = [versionLabel(release)]
        if release.support == "archived" { parts.append(String(localized: "library.version.archived")) }
        if release.id == installedReleaseID { parts.append(String(localized: "library.available.installed")) }
        return parts.joined(separator: " · ")
    }
}

/// One confirmation for the entire selection, including mixed new downloads
/// and replacements. Dismissing it also resets pending menus, not installed data.
struct DocsetReplacementConfirmation: ViewModifier {
    @Binding var choices: [DocsetInstallChoice]?
    let confirm: ([DocsetInstallChoice]) -> Void
    let cancel: ([DocsetInstallChoice]) -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog("library.version.replace.title", isPresented: Binding(
            get: { choices != nil },
            set: { if !$0 { cancelPending() } }
        ), titleVisibility: .visible) {
            Button("library.version.replace.confirm") {
                let accepted = choices ?? []
                choices = nil
                confirm(accepted)
            }
            Button("library.action.cancel", role: .cancel) { cancelPending() }
        } message: {
            Text("library.version.replace.message \((choices ?? []).map(\.summary).joined(separator: "\n"))")
        }
    }

    private func cancelPending() {
        let cancelled = choices ?? []
        choices = nil
        cancel(cancelled)
    }
}
