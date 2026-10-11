import AppKit
import CruxCore
import SwiftUI
import Testing
@testable import Crux

@MainActor
struct CommandMenuTests {
    @Test
    func aboutMenuItemKeepsTheCurrentBrandAndShowsAnIcon() async throws {
        try await withModel { model in
            let menu = NSHostingMenu(rootView: CruxCommands(model: model).aboutMenuItem)
            let item = try await onlyItem(in: menu)
            #expect(item.title.hasSuffix(AppIdentity.current.isBeta ? "Crux Beta" : "Crux"))
            #expect(item.isEnabled)
            let image = try #require(item.image)
            #expect(image.size.width > 0 && image.size.height > 0)
        }
    }

    @Test(arguments: [false, true])
    func updateMenuIconPreservesEnablementAndRoutesTheAction(canCheck: Bool) async throws {
        let updater = MenuTestUpdater(canCheckForUpdates: canCheck)
        try await withModel(updater: updater) { model in
            let menu = NSHostingMenu(rootView: CruxCommands(model: model).updateMenuItem)
            let item = try await onlyItem(in: menu)
            #expect(!item.title.isEmpty)
            #expect(item.isEnabled == canCheck)
            let image = try #require(item.image)
            #expect(image.size.width > 0 && image.size.height > 0)
            if canCheck {
                // Invoke the command directly; no menu popup or input events.
                menu.performActionForItem(at: 0)
                for _ in 0..<30 where updater.checks == 0 {
                    try await Task.sleep(for: .milliseconds(10))
                }
                #expect(updater.checks == 1)
            } else {
                #expect(updater.checks == 0)
            }
        }
    }

    private func onlyItem<Content: View>(in menu: NSHostingMenu<Content>) async throws -> NSMenuItem {
        menu.update()
        try await Task.sleep(for: .milliseconds(50))
        menu.update()
        #expect(menu.items.count == 1)
        return try #require(menu.items.first)
    }

    private func withModel(updater: (any ApplicationUpdating)? = nil,
                           _ body: (AppModel) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "CruxCommandMenu-\(UUID().uuidString)")
        let defaults = try #require(UserDefaults(suiteName: root.lastPathComponent))
        defer {
            defaults.removePersistentDomain(forName: root.lastPathComponent)
            try? FileManager.default.removeItem(at: root)
        }
        let model = AppModel(preferences: ReaderPreferences(defaults: defaults),
                             layout: AppDirectoryLayout(applicationSupportDirectory: root),
                             applicationUpdater: updater)
        do {
            try await body(model)
            await model.shutdown()
        } catch {
            await model.shutdown()
            throw error
        }
    }
}

@MainActor
private final class MenuTestUpdater: ApplicationUpdating {
    let canCheckForUpdates: Bool
    let isConfigured = true
    var automaticallyChecksForUpdates = false
    var automaticallyDownloadsUpdates = false
    private(set) var checks = 0

    init(canCheckForUpdates: Bool) { self.canCheckForUpdates = canCheckForUpdates }
    func start() {}
    func checkForUpdates() { checks += 1 }
}
