import CruxCore
import SwiftUI

/// The main window is a top-level tab workspace.
///
/// All reader views remain alive in the stack so each tab preserves its own
/// search panel, find state and WebKit instance while another tab is selected.
struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        Group {
            if model.tabs.isEmpty {
                // A lightweight root lets WindowGroup create and activate its
                // NSWindow before bootstrap constructs the first WKWebView.
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ZStack {
                    ForEach(model.tabs) { tab in
                        ReaderView(model: model, tab: tab)
                            .opacity(model.selectedTabID == tab.id ? 1 : 0)
                            .allowsHitTesting(model.selectedTabID == tab.id)
                            .disabled(model.selectedTabID != tab.id)
                            .accessibilityHidden(model.selectedTabID != tab.id)
                            .zIndex(model.selectedTabID == tab.id ? 1 : 0)
                    }
                }
                // Session restoration replaces the provisional Welcome tab.
                // Prevent user actions in that brief interval from being lost.
                .disabled(model.isBootstrapping)
            }
        }
        .safeAreaBar(edge: .top, spacing: 0) {
            if model.tabs.count > 1 {
                workspaceTitleBar
            }
        }
        // A clear fill preserves the native titlebar's event handling. Hiding
        // the entire background also removes its double-click hit region.
        .toolbarBackground(.clear, for: .windowToolbar)
        .toolbar(removing: .title)
        .task { await model.bootstrap() }
        .alert(
            "reader.remoteNotice.title",
            isPresented: Binding(
                get: { model.shouldPresentRemoteResourceNotice },
                set: { _ in }
            )
        ) {
            Button("reader.remoteNotice.continue") {
                Task { await model.resolveRemoteResourceNotice(keepEnabled: true) }
            }
            Button("reader.remoteNotice.disable", role: .cancel) {
                Task { await model.resolveRemoteResourceNotice(keepEnabled: false) }
            }
        } message: {
            Text("reader.remoteNotice.message")
        }
        .preferredColorScheme(model.preferences.appearance.colorScheme)
    }

    private var workspaceTitleBar: some View {
        HStack(spacing: 12) {
            WorkspaceTabStrip(model: model)
            Spacer(minLength: 12)
            WorkspaceNewTabButton(model: model)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .frame(height: 50)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspace-titlebar")
    }
}

#Preview {
    ContentView(model: AppModel())
}
