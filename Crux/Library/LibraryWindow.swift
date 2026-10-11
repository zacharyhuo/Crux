import CruxCore
import SwiftUI

/// Docset management embedded in the native Settings scene.
struct DocsetsSettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("library.window.title", selection: $model.docsetsSection) {
                    Label("library.tab.available", systemImage: "square.and.arrow.down")
                        .tag(DocsetsSettingsSection.available)
                    Label("library.tab.installed", systemImage: "books.vertical")
                        .tag(DocsetsSettingsSection.installed)
                    Label("library.tab.sources", systemImage: "network")
                        .tag(DocsetsSettingsSection.sources)
                }
                .pickerStyle(.segmented)
                .labelStyle(.titleOnly)
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("docsets-section-picker")
                Spacer()
                Button {
                    model.presentImportPanel()
                } label: {
                    Label("menu.file.import", systemImage: "square.and.arrow.down.on.square")
                }
                .labelStyle(.titleAndIcon)
                .help("menu.file.import")
                .accessibilityIdentifier("docsets-import-button")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("docsets-action-bar")

            Divider()

            selectedTab

            if let notice = model.libraryNotice {
                HStack {
                    Text(notice).font(.caption)
                    Spacer()
                    Button("library.action.ok") { model.dismissLibraryNotice() }
                }
                .padding(12)
                .background(.bar)
                .accessibilityIdentifier("library-version-notice")
            }

            TransferJobList(model: model)
        }
        // The minimum keeps the shared settings navigation, catalog search and
        // persistent text-labelled actions visible at the same time.
        .frame(minWidth: 820, minHeight: 520)
        .alert("library.error.title", isPresented: errorPresented) {
            Button("library.action.ok", role: .cancel) { model.dismissLibraryError() }
        } message: {
            Text(model.libraryError ?? "")
        }
        .task {
            await model.refreshCatalogIfNeeded()
        }
    }

    @ViewBuilder
    private var selectedTab: some View {
        switch model.docsetsSection {
        case .available:
            AvailableDocsetsView(model: model)
        case .installed:
            InstalledDocsetsView(model: model)
        case .sources:
            SourcesView(model: model)
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { model.libraryError != nil },
            set: { if !$0 { model.dismissLibraryError() } }
        )
    }
}

/// A compact utility-window empty state built from the semantic system label.
///
/// `Label` is comparable to a semantic icon-and-text component on the web:
/// macOS owns alignment and accessibility, while Crux avoids the intentionally
/// oversized empty-page treatment of `ContentUnavailableView`.
struct LibraryEmptyState: View {
    let title: LocalizedStringKey
    let systemImage: String

    var body: some View {
        Label {
            Text(title)
                .font(.headline)
        } icon: {
            Image(systemName: systemImage)
                .font(.title2)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

struct TransferJobList: View {
    @Bindable var model: AppModel

    var body: some View {
        if !model.transferJobs.isEmpty {
            VStack(spacing: 0) {
                // `Divider` maps to the system separator color and remains
                // correct across appearance, contrast and Liquid Glass modes.
                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("library.jobs.title")
                            .font(.headline)
                        Spacer()
                        Button("library.jobs.clear") {
                            Task { await model.clearFinishedJobs() }
                        }
                        .disabled(model.transferJobs.allSatisfy(\.isActive))
                    }
                    ForEach(model.transferJobs) { job in
                        TransferJobRow(job: job, model: model)
                    }
                }
                .padding(12)
            }
            .background(.bar)
        }
    }
}

private struct TransferJobRow: View {
    let job: TransferJob
    let model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.transferDisplayName(for: job))
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(job.status.isFailed ? .red : .secondary)
                    .lineLimit(2)
            }
            Spacer()
            if let fraction = job.progressFraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .frame(width: 120)
            } else if job.isActive {
                ProgressView()
                    .controlSize(.small)
            }
            if job.isActive {
                Button("library.jobs.cancel") {
                    Task { await model.cancelJob(job.id) }
                }
            } else if job.status.isFailed || job.status == .cancelled {
                Button("library.jobs.retry") {
                    Task { await model.retryJob(job.id) }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var statusText: String {
        switch job.status {
        case .queued:
            String(localized: "library.jobs.queued")
        case .downloading:
            String(localized: "library.jobs.downloading")
        case .installing:
            String(localized: "library.jobs.installing")
        case .completed:
            String(localized: "library.jobs.completed")
        case let .failed(message):
            message
        case .cancelled:
            String(localized: "library.jobs.cancelled")
        }
    }
}

private extension TransferJob {
    var progressFraction: Double? {
        switch status {
        case let .downloading(received, expected):
            guard let expected, expected > 0 else { return nil }
            return min(1, Double(received) / Double(expected))
        case .installing:
            return 1
        default:
            return nil
        }
    }
}

private extension TransferJob.Status {
    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}
