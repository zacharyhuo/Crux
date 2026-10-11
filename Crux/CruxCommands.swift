import AppKit
import SwiftUI

/// App-specific additions to the standard macOS menu bar.
///
/// Every reader action is reachable from a menu with a standard shortcut, which
/// is what makes the main flows completable from the keyboard alone.
struct CruxCommands: Commands {
    let model: AppModel

    private let repositoryURL = URL(string: "https://github.com/zacharyhuo/Crux")!

    var aboutMenuItem: some View {
        Button {
            NSApplication.shared.orderFrontStandardAboutPanel(nil)
        } label: {
            Label("menu.app.about \(AppIdentity.current.displayName)", systemImage: "info.circle")
        }
        .labelStyle(.titleAndIcon)
    }

    var updateMenuItem: some View {
        Button {
            Task { await model.checkForNewRelease() }
        } label: {
            Label("menu.help.checkAppUpdates", systemImage: "arrow.triangle.2.circlepath")
        }
        .labelStyle(.titleAndIcon)
        .disabled(model.applicationUpdater?.canCheckForUpdates != true)
    }

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            aboutMenuItem
        }

        CommandGroup(replacing: .newItem) {
            Button("menu.file.newTab") {
                model.openTab()
            }
            .keyboardShortcut("t", modifiers: .command)
            .disabled(model.isBootstrapping)

            Button("menu.file.closeTab") {
                guard let id = model.selectedTabID else { return }
                model.closeTab(id)
            }
            .keyboardShortcut("w", modifiers: .command)
            .disabled(model.isBootstrapping || model.selectedTabID == nil)
        }

        CommandGroup(after: .textEditing) {
            Button("menu.edit.find") {
                NotificationCenter.default.post(name: .cruxToggleFindBar, object: nil)
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(model.isBootstrapping || model.selectedTabID == nil)

            Button("menu.edit.search") {
                NotificationCenter.default.post(name: .cruxFocusSearchField, object: nil)
            }
            .keyboardShortcut("l", modifiers: .command)
            .disabled(model.isBootstrapping)

            Button("menu.edit.copyPageLink") {
                model.copyCurrentPageLink()
            }
            .keyboardShortcut("c", modifiers: [.command, .option])
            .disabled(model.isBootstrapping || model.selectedTab?.currentLocation == nil)
        }

        CommandMenu("menu.navigate.title") {
            Button("menu.navigate.back") { model.selectedTab?.goBack() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(model.isBootstrapping || model.selectedTab?.canGoBack != true)

            Button("menu.navigate.forward") { model.selectedTab?.goForward() }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(model.isBootstrapping || model.selectedTab?.canGoForward != true)

            Button("menu.navigate.reload") { model.selectedTab?.reload() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.isBootstrapping || model.selectedTab?.currentLocation == nil)

            Button("reader.action.home") {
                guard let tab = model.selectedTab else { return }
                model.goHome(in: tab)
            }
            .keyboardShortcut("h", modifiers: [.command, .shift])
            .disabled(model.isBootstrapping)

            Divider()

            Button("menu.navigate.nextTab") { model.selectNextTab(offset: 1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled(model.isBootstrapping || model.tabs.count < 2)

            Button("menu.navigate.previousTab") { model.selectNextTab(offset: -1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled(model.isBootstrapping || model.tabs.count < 2)
        }

        CommandGroup(after: .toolbar) {
            Button("menu.view.zoomIn") { model.selectedTab?.zoomIn() }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(model.isBootstrapping || model.selectedTabID == nil)

            Button("menu.view.zoomOut") { model.selectedTab?.zoomOut() }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(model.isBootstrapping || model.selectedTabID == nil)

            Button("menu.view.actualSize") { model.selectedTab?.resetZoom() }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(model.isBootstrapping || model.selectedTabID == nil)
        }

        CommandGroup(before: .appSettings) {
            updateMenuItem
            Divider()
        }

        CommandGroup(replacing: .help) {
            Link("menu.help.github", destination: repositoryURL)
        }
    }
}
