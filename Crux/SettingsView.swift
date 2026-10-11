import CruxCore
import SwiftUI

/// The native Settings scene.
///
/// Preferences that change what a page may load are applied to the running
/// document server and to open tabs as soon as they are toggled, so the user
/// never has to reason about when a privacy setting takes effect.
struct SettingsView: View {
    @Bindable var model: AppModel
    @Namespace private var settingsNavigationNamespace

    var body: some View {
        VStack(spacing: 0) {
            settingsNavigation
            Divider()
            selectedSettings
        }
        .frame(width: 900, height: 620)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-root")
        .confirmationDialog(
            "settings.general.storage.trash.title",
            isPresented: Binding(
                get: { !model.pendingTrashItems.isEmpty },
                set: { if !$0 { model.dismissPendingTrash() } }
            ),
            titleVisibility: .visible
        ) {
            Button("settings.general.storage.trash.confirm", role: .destructive) {
                model.trashPendingStorageCopy()
            }
            Button("settings.general.storage.trash.keep", role: .cancel) {
                model.dismissPendingTrash()
            }
        } message: {
            Text("settings.general.storage.trash.message")
        }
        .preferredColorScheme(model.preferences.appearance.colorScheme)
    }

    private var settingsNavigation: some View {
        HStack {
            Spacer()
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    settingsNavigationButton(
                        .general,
                        title: "settings.general.title",
                        systemImage: "gearshape",
                        identifier: "settings-navigation-general"
                    )
                    settingsNavigationButton(
                        .docsets,
                        title: "settings.docsets.title",
                        systemImage: "books.vertical",
                        identifier: "settings-navigation-docsets"
                    )
                    settingsNavigationButton(
                        .privacy,
                        title: "settings.privacy.title",
                        systemImage: "hand.raised",
                        identifier: "settings-navigation-privacy"
                    )
                }
            }
            .frame(width: 420)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-navigation")
    }

    private func settingsNavigationButton(
        _ section: SettingsSection,
        title: LocalizedStringKey,
        systemImage: String,
        identifier: String
    ) -> some View {
        let isSelected = model.settingsSelection == section

        return Button {
            model.settingsSelection = section
        } label: {
            VStack(spacing: 2) {
                Image(systemName: systemImage)
                    .font(.system(size: 22, weight: .medium))
                    .accessibilityHidden(true)
                Text(title)
                    .font(.caption)
            }
            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            .frame(width: 88, height: 56)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .glassEffect(
            isSelected
                ? .regular.tint(.accentColor.opacity(0.12)).interactive()
                : .identity,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .glassEffectID(isSelected ? "settings-navigation-selection" : nil, in: settingsNavigationNamespace)
        .animation(.snappy(duration: 0.2), value: model.settingsSelection)
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }

    @ViewBuilder
    private var selectedSettings: some View {
        switch model.settingsSelection {
        case .general:
            general
        case .docsets:
            DocsetsSettingsView(model: model)
        case .privacy:
            privacy
        }
    }

    private var general: some View {
        Form {
            Section("settings.general.title") {
                Picker("settings.general.appearance", selection: Bindable(model.preferences).appearance) {
                    ForEach(AppAppearance.allCases, id: \.self) { appearance in
                        Text(appearance.titleKey).tag(appearance)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("settings-appearance-picker")
                Toggle(
                    "settings.general.restoreSession",
                    isOn: Bindable(model.preferences).restoresLastSession
                )
                Text("settings.general.restoreSession.help")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("settings.general.storage") {
                LabeledContent("settings.general.storage.location") {
                    Text(model.currentDocsetsDirectory.path(percentEncoded: false))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(3)
                        .truncationMode(.middle)
                }
                Text("settings.general.storage.help")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("settings.general.storage.choose") {
                        model.presentStorageFolderPanel()
                    }
                    if model.librarySettings.customDocsetsPath != nil {
                        Button("settings.general.storage.default") {
                            Task { await model.restoreDefaultStorage() }
                        }
                    }
                    Button("library.action.revealFolder") {
                        model.revealDocsetsDirectoryInFinder()
                    }
                }
            }

            Section("settings.updates.title") {
                Toggle("settings.updates.automaticChecks", isOn: Binding(
                    get: { model.applicationUpdater?.automaticallyChecksForUpdates ?? false },
                    set: { model.applicationUpdater?.automaticallyChecksForUpdates = $0 }
                ))
                Toggle("settings.updates.automaticDownloads", isOn: Binding(
                    get: { model.applicationUpdater?.automaticallyDownloadsUpdates ?? false },
                    set: { model.applicationUpdater?.automaticallyDownloadsUpdates = $0 }
                ))
                Button("menu.help.checkAppUpdates") {
                    Task { await model.checkForNewRelease() }
                }
                .disabled(model.applicationUpdater?.canCheckForUpdates != true)
                Text(model.applicationUpdater?.isConfigured == true
                     ? "settings.updates.help" : "settings.updates.unavailable")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .disabled(model.applicationUpdater?.isConfigured != true)
        }
        .formStyle(.grouped)
    }

    private var privacy: some View {
        Form {
            Section("settings.privacy.remoteResources") {
                Toggle("settings.privacy.allowRemote", isOn: remoteResourcesBinding)
                Text("settings.privacy.allowRemote.help")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Label("settings.privacy.httpBlocked", systemImage: "lock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("settings.privacy.perDocset") {
                if model.docsets.isEmpty {
                    Text("settings.privacy.perDocset.empty")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.docsets, id: \.identifier) { descriptor in
                        Toggle(descriptor.displayName, isOn: binding(for: descriptor))
                            .disabled(!model.preferences.allowsRemoteResources)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var remoteResourcesBinding: Binding<Bool> {
        Binding {
            model.preferences.allowsRemoteResources
        } set: { isAllowed in
            model.preferences.allowsRemoteResources = isAllowed
            model.preferences.hasSeenRemoteResourceNotice = true
            Task { await model.applyRemoteResourcePolicyChange() }
        }
    }

    private func binding(for descriptor: DocsetDescriptor) -> Binding<Bool> {
        Binding {
            model.preferences.allowsRemoteResources(forDocset: descriptor.identifier)
        } set: { isAllowed in
            model.preferences.setAllowsRemoteResources(isAllowed, forDocset: descriptor.identifier)
            Task { await model.applyRemoteResourcePolicyChange() }
        }
    }
}

#Preview {
    SettingsView(model: AppModel())
}
