import AppKit
import CruxCore
import SwiftUI
import Testing
@testable import Crux

@MainActor
struct AppearanceTests {
    @Test(arguments: [false, true])
    func windowAppearanceUpdatesWithoutOpeningAWindow(isReaderWindow: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "CruxAppearance-\(UUID().uuidString)")
        let defaults = try #require(UserDefaults(suiteName: root.lastPathComponent))
        defer {
            defaults.removePersistentDomain(forName: root.lastPathComponent)
            try? FileManager.default.removeItem(at: root)
        }
        let model = AppModel(preferences: ReaderPreferences(defaults: defaults),
                             layout: AppDirectoryLayout(applicationSupportDirectory: root))
        let host = NSHostingView(rootView: Group {
            if isReaderWindow { ContentView(model: model) }
            else { SettingsView(model: model) }
        })
        let window = OffscreenAppearanceWindow(contentRect: NSRect(x: -100_000, y: -100_000, width: 900, height: 620),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        model.preferences.appearance = .dark
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        #expect(window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        model.preferences.appearance = .light
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        #expect(window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua)
        model.preferences.appearance = .system
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        #expect(window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) ==
                NSApplication.shared.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]))
        #expect(!window.isKeyWindow)
        #expect(!window.isMainWindow)
        #expect(!window.isVisible)
        await model.shutdown()
    }

    @Test func appearancePersistsWithoutLeakingIntoAnotherAppDefaultsDomain() throws {
        let name = "CruxAppearancePreferences-\(UUID().uuidString)"
        let betaName = "\(name).Beta"
        let defaults = try #require(UserDefaults(suiteName: name))
        let betaDefaults = try #require(UserDefaults(suiteName: betaName))
        defer {
            defaults.removePersistentDomain(forName: name)
            betaDefaults.removePersistentDomain(forName: betaName)
        }
        let preferences = ReaderPreferences(defaults: defaults)
        #expect(preferences.appearance.colorScheme == nil)
        preferences.appearance = .dark
        #expect(ReaderPreferences(defaults: defaults).appearance.colorScheme == .dark)
        #expect(ReaderPreferences(defaults: betaDefaults).appearance.colorScheme == nil)
        preferences.appearance = .light
        #expect(ReaderPreferences(defaults: defaults).appearance.colorScheme == .light)
        preferences.appearance = .system
        #expect(ReaderPreferences(defaults: defaults).appearance.colorScheme == nil)
        #expect(preferences.allowsRemoteResources)
        #expect(preferences.restoresLastSession)
    }

    @Test func unknownAppearancePreferenceFallsBackToSystem() throws {
        let name = "CruxInvalidAppearance-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("unknown-mode", forKey: "app.appearance")
        #expect(ReaderPreferences(defaults: defaults).appearance.colorScheme == nil)
    }
}

/// Hosting a toolbar may ask AppKit to order its window. Tests must never do so.
@MainActor
private final class OffscreenAppearanceWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
        if place == .out { super.order(place, relativeTo: otherWin) }
    }
}
