import CruxCore
import SwiftUI

/// Source configuration lives in AppModel; sheets hold only unsaved presentation state.
struct SourcesView: View {
    @Bindable var model: AppModel
    @State private var editor: SourceDraft?
    @State private var pendingEnable: DocsetSourceConfiguration?
    @State private var pendingDelete: DocsetSourceConfiguration?
    @State private var changingSources: Set<UUID> = []

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Spacer()
                Button { editor = SourceDraft() } label: {
                    Label("library.sources.add", systemImage: "plus")
                }
                .accessibilityIdentifier("source-add")
                Button { Task { await model.refreshCatalog() } } label: {
                    Label("library.sources.refreshAll", systemImage: "arrow.clockwise")
                }
                .disabled(model.enabledSourceCount == 0)
                .accessibilityIdentifier("sources-refresh-enabled")
            }
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("sources-action-bar")

            Divider()

            List {
                Section("library.sources.builtin") {
                    ForEach(model.sources.filter(\.isBuiltIn)) { source in sourceRow(source) }
                }
                Section("library.sources.custom") {
                    ForEach(model.sources.filter { !$0.isBuiltIn }) { source in sourceRow(source) }
                }
            }
            .accessibilityIdentifier("sources-list")
        }
        .sheet(item: $editor) { draft in
            SourceEditorSheet(draft: draft) { configuration in
                await model.saveSource(configuration)
                return model.sources.contains {
                    $0.id == configuration.id && $0.name == configuration.name && $0.isEnabled == configuration.isEnabled
                }
            }
        }
        .alert("library.sources.zeal.title", isPresented: Binding(
            get: { pendingEnable != nil }, set: { if !$0 { pendingEnable = nil } }
        )) {
            Button("library.sources.zeal.enable") {
                if let source = pendingEnable { setEnabled(source, true) }
                pendingEnable = nil
            }
            Button("library.action.cancel", role: .cancel) { pendingEnable = nil }
        } message: {
            Text("library.sources.zeal.message")
        }
        .confirmationDialog("library.sources.delete.title", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
        ), titleVisibility: .visible) {
            Button("library.sources.delete", role: .destructive) {
                if let source = pendingDelete, SourcePresentation.canDelete(source) {
                    Task { await model.deleteSource(source) }
                }
                pendingDelete = nil
            }
            Button("library.action.cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("library.sources.delete.message")
        }
    }

    private func sourceRow(_ source: DocsetSourceConfiguration) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(source.name)
                    Text(LocalizedStringKey(SourcePresentation.kindKey(source)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let endpoint = source.endpointURL {
                        Text(endpoint.absoluteString)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }
                Spacer()
                Toggle("library.sources.enabled", isOn: enabledBinding(source))
                    .toggleStyle(.switch)
                    .fixedSize()
                    .disabled(source.kind == .unavailable || changingSources.contains(source.id))
                    .accessibilityIdentifier(SourcePresentation.accessibilityID("source-toggle", sourceID: source.id))
                Button("library.sources.edit") { editor = SourceDraft(editing: source) }
                    .disabled(changingSources.contains(source.id))
                    .accessibilityIdentifier(SourcePresentation.accessibilityID("source-edit", sourceID: source.id))
                Button("library.sources.refresh") { Task { await model.refreshSource(source) } }
                    .disabled(!source.canFetch || (model.sourceStates[source.id]?.isRefreshing ?? false) || changingSources.contains(source.id))
                    .accessibilityIdentifier(SourcePresentation.accessibilityID("source-refresh", sourceID: source.id))
                if SourcePresentation.canDelete(source) {
                    Button("library.sources.delete", role: .destructive) { pendingDelete = source }
                        .disabled(changingSources.contains(source.id))
                        .accessibilityIdentifier(SourcePresentation.accessibilityID("source-delete", sourceID: source.id))
                }
            }
            if source.isEnabled {
                SourceRefreshStatus(sourceID: source.id,
                                    isRefreshing: model.sourceStates[source.id]?.isRefreshing ?? false,
                                    message: model.sourceStates[source.id]?.message,
                                    fetchedAt: model.sourceStates[source.id]?.fetchedAt,
                                    isFromCache: model.sourceStates[source.id]?.isFromCache ?? false)
            } else {
                Text("library.sources.disabled").font(.caption).foregroundStyle(.secondary)
            }
            if case .feed = source.kind {
                ForEach(model.availableDocsets.filter { $0.sourceConfigurationID == source.id }) { item in
                    HStack {
                        Text(SourcePresentation.title(item.entry.title, sourceName: item.sourceName, enabledSourceCount: model.enabledSourceCount))
                            .font(.caption)
                        Spacer()
                        if model.installedRecord(for: item) != nil {
                            Text("library.available.installed").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Button("library.feeds.install") { Task { await model.installCatalogEntry(item, selection: .latest) } }
                                .disabled(!source.canFetch || model.isTransferring(item))
                                .accessibilityIdentifier("source-feed-install-\(item.id)")
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(SourcePresentation.accessibilityID("source-row", sourceID: source.id))
    }

    private func enabledBinding(_ source: DocsetSourceConfiguration) -> Binding<Bool> {
        Binding(get: { source.isEnabled }, set: { enabled in
            if enabled, case .zeal = source.kind { pendingEnable = source }
            else { setEnabled(source, enabled) }
        })
    }

    private func setEnabled(_ source: DocsetSourceConfiguration, _ enabled: Bool) {
        changingSources.insert(source.id)
        Task {
            await model.setSourceEnabled(source, enabled: enabled)
            changingSources.remove(source.id)
        }
    }
}

/// Shared by Sources and Available; one source's state never disables another source.
struct SourceRefreshStatus: View {
    let sourceID: UUID
    let isRefreshing: Bool
    let message: String?
    let fetchedAt: Date?
    let isFromCache: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if isRefreshing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("library.sources.loading")
                }
            }
            if let message {
                Text(LocalizedStringKey(message)).textSelection(.enabled)
            }
            if sourceID == DocsetSourceConfiguration.cruxID, fetchedAt == nil {
                Text("library.sources.private")
            }
            if isFromCache { Text("library.sources.cache") }
            if let fetchedAt {
                Text("library.sources.updated \(fetchedAt.formatted(date: .abbreviated, time: .shortened))")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(SourcePresentation.accessibilityID("source-status", sourceID: sourceID))
    }
}

private struct SourceEditorSheet: View {
    @State private var draft: SourceDraft
    @State private var isSaving = false
    @State private var saveFailed = false
    @State private var explainsZeal = false
    @Environment(\.dismiss) private var dismiss
    let save: (DocsetSourceConfiguration) async -> Bool

    init(draft: SourceDraft, save: @escaping (DocsetSourceConfiguration) async -> Bool) {
        _draft = State(initialValue: draft)
        self.save = save
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(LocalizedStringKey(draft.original == nil ? "library.sources.editor.add" : "library.sources.editor.edit"))
                .font(.headline)
            Form {
                TextField("library.sources.editor.name", text: $draft.name)
                    .accessibilityIdentifier(fieldID("name"))
                if let original = draft.original {
                    LabeledContent("library.sources.editor.type") {
                        Text(LocalizedStringKey(SourcePresentation.kindKey(original)))
                    }
                    if let endpoint = original.endpointURL {
                        LabeledContent(draft.kind == .feed ? "library.sources.editor.feedURL" : "library.sources.editor.catalogURL") {
                            Text(endpoint.absoluteString).textSelection(.enabled)
                                .lineLimit(2).truncationMode(.middle)
                        }
                    }
                    if case let .zeal(_, root) = original.kind {
                        LabeledContent("library.sources.editor.downloadRootURL") {
                            Text(root.absoluteString).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                        }
                    }
                    LabeledContent("library.sources.editor.transport") {
                        Text(LocalizedStringKey(original.transportPolicy == .localHTTP
                            ? "library.sources.editor.transport.local" : "library.sources.editor.transport.https"))
                    }
                    Text("library.sources.editor.immutable").font(.caption).foregroundStyle(.secondary)
                } else {
                    Picker("library.sources.editor.type", selection: $draft.kind) {
                        Text("library.sources.type.zeal").tag(SourceDraft.Kind.zeal)
                        Text("library.sources.type.feed").tag(SourceDraft.Kind.feed)
                    }
                    .accessibilityIdentifier(fieldID("type"))
                    TextField(draft.kind == .feed ? "library.sources.editor.feedURL" : "library.sources.editor.catalogURL", text: $draft.catalogURL)
                        .accessibilityIdentifier(fieldID("catalog-url"))
                    if draft.kind == .zeal {
                        TextField("library.sources.editor.downloadRootURL", text: $draft.downloadRootURL)
                            .accessibilityIdentifier(fieldID("download-root-url"))
                    }
                    Toggle("library.sources.editor.http", isOn: $draft.allowsLocalHTTP)
                        .accessibilityIdentifier(fieldID("local-http-consent"))
                    Text("library.sources.editor.httpHelp").font(.caption).foregroundStyle(.secondary)
                }
                Toggle("library.sources.enabled", isOn: editorEnabledBinding)
                    .disabled(draft.original?.kind == .unavailable)
                    .accessibilityIdentifier(fieldID("enabled"))
                if isZeal {
                    Text("library.sources.zeal.message").font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .disabled(isSaving)

            if let key = draft.validationKey, !draft.name.isEmpty {
                Text(LocalizedStringKey(key)).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier(fieldID("validation"))
            }
            if saveFailed {
                Text("library.sources.editor.saveFailure").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                if isSaving { ProgressView().controlSize(.small) }
                Spacer()
                Button("library.action.cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSaving)
                Button("library.sources.editor.save") { saveDraft() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.validationKey != nil || isSaving)
                    .accessibilityIdentifier(fieldID("save"))
            }
        }
        .padding(20)
        .frame(width: 560, height: draft.original == nil ? 520 : 440)
        .interactiveDismissDisabled(isSaving)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(fieldID("sheet"))
        .alert("library.sources.zeal.title", isPresented: $explainsZeal) {
            Button("library.sources.zeal.enable") { draft.isEnabled = true }
            Button("library.action.cancel", role: .cancel) {}
        } message: { Text("library.sources.zeal.message") }
    }

    private var isZeal: Bool {
        if let original = draft.original { if case .zeal = original.kind { return true }; return false }
        return draft.kind == .zeal
    }

    private var editorEnabledBinding: Binding<Bool> {
        Binding(get: { draft.isEnabled }, set: { enabled in
            if enabled && isZeal { explainsZeal = true }
            else { draft.isEnabled = enabled }
        })
    }

    private func fieldID(_ field: String) -> String {
        SourcePresentation.accessibilityID("source-editor-\(field)", sourceID: draft.id)
    }

    private func saveDraft() {
        guard let configuration = try? draft.configuration() else { return }
        isSaving = true
        saveFailed = false
        Task {
            if await save(configuration) { dismiss() }
            else { saveFailed = true }
            isSaving = false
        }
    }
}
