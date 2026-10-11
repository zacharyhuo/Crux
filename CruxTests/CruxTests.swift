import AppKit
import CruxCore
import Foundation
import SwiftUI
import Testing
@testable import Crux

@MainActor
struct DocsetIconViewTests {
    @Test
    func nativeControlsReceiveTheCompactLogicalImageSize() throws {
        let icon = DocsetIconView(descriptor: nil, catalogData: nil,
                                  fallbackName: "Java SE25", size: DocsetIconMetrics.compact)
        let image = try #require(icon.resolvedImage)
        #expect(
            image.size == NSSize(width: 18, height: 18),
            "Native controls receive the underlying image, so a surrounding SwiftUI frame cannot substitute for its logical size."
        )
    }
}

struct SymbolTypeBadgeTests {
    @Test
    @MainActor
    func commonSymbolKindsUseDifferentBackgroundPalettes() {
        let types = [
            "Class", "Constant", "Constructor", "Element", "Field", "Interface",
            "Method", "Module", "Package", "Property", "Section",
        ]
        let palettes = types.map { SymbolTypeBadgePalette.token(for: $0) }

        #expect(Set(palettes).count == types.count)
        #expect(SymbolTypeBadgePalette.token(for: "class") == SymbolTypeBadgePalette.token(for: "Class"))
        #expect(
            SymbolTypeBadgePalette.token(for: "HTTP Header")
                == SymbolTypeBadgePalette.token(for: "http header")
        )
    }
}

private final class LocalizationBundleAnchor: NSObject {}

@MainActor
struct AppRuntimeIsolationTests {
    @Test
    func appHostedXCTestProcessAlwaysUsesAnIsolatedRuntime() {
        let runtime = CruxAppRuntimeConfiguration.resolve()

        #expect(
            runtime.isUITesting,
            "App-hosted tests must never fall through to the production Crux runtime."
        )
        #expect(runtime.applicationSupportDirectory != nil)
        #expect(runtime.userDefaultsSuiteName != nil)
        #expect(!runtime.usesBackgroundDownloads)
    }

    @Test
    func testOverridesAreIgnoredWithoutTheExplicitUITestingMarker() {
        let runtime = CruxAppRuntimeConfiguration.resolve(
            arguments: ["/Applications/Crux.app/Contents/MacOS/Crux"],
            environment: [
                "CRUX_UI_TEST_APPLICATION_SUPPORT_DIRECTORY": "/tmp/should-not-be-used",
                "CRUX_UI_TEST_USER_DEFAULTS_SUITE": "com.zacharyhuo.CruxUITests.should-not-be-used",
            ],
            fallbackIdentifier: "unit-test",
            identity: AppIdentity(bundleIdentifier: "com.zacharyhuo.Crux", isBetaBuild: false)
        )

        #expect(runtime.applicationSupportDirectory == nil)
        #expect(runtime.userDefaultsSuiteName == nil)
        #expect(runtime.usesBackgroundDownloads)
    }

    @Test
    func explicitUITestingModeIsolatesAllPersistentAndBackgroundState() {
        let expectedRoot = FileManager.default.temporaryDirectory.appending(
            path: "CruxTests-unit-test",
            directoryHint: .isDirectory
        )
        let runtime = CruxAppRuntimeConfiguration.resolve(
            arguments: ["Crux", "-crux-ui-testing"],
            environment: [
                "CRUX_UI_TEST_APPLICATION_SUPPORT_DIRECTORY": "/Users/example/Library/Application Support/Crux",
                "CRUX_UI_TEST_USER_DEFAULTS_SUITE": "com.zacharyhuo.Crux",
            ],
            fallbackIdentifier: "unit-test"
        )

        #expect(runtime.applicationSupportDirectory == expectedRoot)
        #expect(runtime.userDefaultsSuiteName == "com.zacharyhuo.CruxTests.unit-test")
        #expect(!runtime.usesBackgroundDownloads)
    }

    @Test
    func uiTestingModeFailsClosedWhenIsolationEnvironmentIsMissing() {
        let runtime = CruxAppRuntimeConfiguration.resolve(
            arguments: ["Crux", "-crux-ui-testing"],
            environment: [:],
            fallbackIdentifier: "unit-test"
        )

        #expect(
            runtime.applicationSupportDirectory
                == FileManager.default.temporaryDirectory
                    .appending(path: "CruxTests-unit-test", directoryHint: .isDirectory)
        )
        #expect(runtime.userDefaultsSuiteName == "com.zacharyhuo.CruxTests.unit-test")
        #expect(!runtime.usesBackgroundDownloads)
    }
}

struct LocalizationTests {
    @Test
    func aboutMenuNamesBothBrandsInEnglishAndSimplifiedChinese() throws {
        let english = try localizedString(forKey: "menu.app.about %@", language: "en")
        let chinese = try localizedString(forKey: "menu.app.about %@", language: "zh-Hans")
        #expect(String(format: english, "Crux") == "About Crux")
        #expect(String(format: english, "Crux Beta") == "About Crux Beta")
        #expect(String(format: chinese, "Crux") == "关于 Crux")
        #expect(String(format: chinese, "Crux Beta") == "关于 Crux Beta")
    }

    @Test
    func welcomeTitleIsAvailableInEnglishAndSimplifiedChinese() throws {
        let english = try localizedString(forKey: "app.welcome.title", language: "en")
        let simplifiedChinese = try localizedString(
            forKey: "app.welcome.title",
            language: "zh-Hans"
        )

        #expect(english == "Welcome to Crux")
        #expect(simplifiedChinese == "欢迎使用 Crux")
    }

    @Test
    func stageFiveControlsAreLocalizedInBothSupportedLanguages() throws {
        let keys = [
            "fullText.enable",
            "fullText.enabled",
            "fullText.resume",
            "fullText.status.indexing",
            "search.section.symbols",
            "search.section.pages",
            "search.panel.docsets",
            "search.panel.similarResults",
            "reader.remoteNotice.title",
            "reader.action.home",
            "release.available.title",
            "menu.edit.copyPageLink",
            "settings.docsets.title",
        ]

        for language in ["en", "zh-Hans"] {
            for key in keys {
                #expect(try localizedString(forKey: key, language: language) != key)
            }
        }
    }

    @Test
    func scopedSearchPlaceholderNamesTheSelectedDocsetNaturally() throws {
        let englishFormat = try localizedString(
            forKey: "search.field.scopedPlaceholder",
            language: "en"
        )
        let simplifiedChineseFormat = try localizedString(
            forKey: "search.field.scopedPlaceholder",
            language: "zh-Hans"
        )

        #expect(String(format: englishFormat, "Java SE25") == "Search symbols in Java SE25")
        #expect(String(format: simplifiedChineseFormat, "Java SE25") == "在 Java SE25 中搜索符号")
    }

    /// Loads one compiled `.lproj` directly so this test is independent of the
    /// language selected in the developer's System Settings. App-hosted tests
    /// find these resources through `Bundle.main`; the fallback also supports
    /// invoking the built XCTest bundle directly when Xcode's test-log service
    /// is unavailable.
    private func localizedString(forKey key: String, language: String) throws -> String {
        let resourceBundle: Bundle
        if Bundle.main.path(forResource: language, ofType: "lproj") != nil {
            resourceBundle = Bundle.main
        } else {
            let testBundle = Bundle(for: LocalizationBundleAnchor.self)
            let appURL = testBundle.bundleURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            resourceBundle = try #require(Bundle(url: appURL))
        }
        let resourcePath = try #require(
            resourceBundle.path(forResource: language, ofType: "lproj")
        )
        let localizedBundle = try #require(Bundle(path: resourcePath))

        return localizedBundle.localizedString(forKey: key, value: nil, table: nil)
    }
}

@MainActor
struct ReaderSearchToolbarTests {
    @Test
    func beginningEditingDoesNotPresentAnAlreadyOpenPanelAgain() async throws {
        try await withIsolatedModel { model in
            let tab = model.openTab()
            var presentationWrites: [Bool] = []
            let host = NSHostingView(
                rootView: ReaderSearchToolbar(
                    model: model,
                    tab: tab,
                    isActive: true,
                    focusRequest: 0,
                    isPanelPresented: Binding(
                        get: { true },
                        set: { presentationWrites.append($0) }
                    ),
                    onSubmit: {}
                )
            )
            host.frame = NSRect(x: 0, y: 0, width: 520, height: 44)
            host.layoutSubtreeIfNeeded()
            let field = try #require(findSearchField(in: host))
            let delegate = try #require(field.delegate)
            for _ in 0..<3 {
                delegate.controlTextDidBeginEditing?(
                    Notification(name: NSControl.textDidBeginEditingNotification, object: field)
                )
            }
            // Drain any deferred presentation requests before checking writes.
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
            #expect(presentationWrites.isEmpty)
        }
    }

    @Test
    func typingIsNotConfiguredAsAnImmediateSearchSubmission() async throws {
        try await withIsolatedModel { model in
            let tab = model.openTab()
            var submissionCount = 0
            let host = NSHostingView(
                rootView: ReaderSearchToolbar(
                    model: model,
                    tab: tab,
                    isActive: true,
                    focusRequest: 0,
                    isPanelPresented: .constant(false),
                    onSubmit: { submissionCount += 1 }
                )
            )
            host.frame = NSRect(x: 0, y: 0, width: 720, height: 60)
            host.layoutSubtreeIfNeeded()

            let searchField = try #require(findSearchField(in: host))
            #expect(
                searchField.sendsSearchStringImmediately == false,
                "Editing actions must never be promoted to result-opening submissions."
            )

            searchField.stringValue = "equals"
            let delegate = try #require(searchField.delegate)
            delegate.controlTextDidChange?(
                Notification(name: NSControl.textDidChangeNotification, object: searchField)
            )
            #expect(submissionCount == 0)

            let handledReturn = delegate.control?(
                searchField,
                textView: NSTextView(),
                doCommandBy: #selector(NSResponder.insertNewline(_:))
            )
            #expect(handledReturn == true)
            #expect(submissionCount == 1)
        }
    }

    @Test
    func inactiveTabDisablesItsNativeSearchField() async throws {
        try await withIsolatedModel { model in
            let tab = model.openTab()
            let host = NSHostingView(
                rootView: ReaderSearchToolbar(
                    model: model,
                    tab: tab,
                    isActive: false,
                    focusRequest: 0,
                    isPanelPresented: .constant(false),
                    onSubmit: {}
                )
            )
            host.frame = NSRect(x: 0, y: 0, width: 720, height: 60)
            host.layoutSubtreeIfNeeded()

            let searchField = try #require(findSearchField(in: host))
            #expect(!searchField.isEnabled)
        }
    }

    @Test
    func nativeSearchFieldPreservesItsNativeContentLayout() async throws {
        try await withIsolatedModel { model in
            let tab = model.openTab()
            let host = NSHostingView(
                rootView: ReaderSearchToolbar(
                    model: model,
                    tab: tab,
                    isActive: true,
                    focusRequest: 0,
                    isPanelPresented: .constant(false),
                    onSubmit: {}
                )
            )
            host.frame = NSRect(x: 0, y: 0, width: 520, height: 44)
            host.layoutSubtreeIfNeeded()

            let searchField = try #require(findSearchField(in: host))
            #expect(
                searchField.isBezeled,
                "The native bezel must remain responsible for spacing the search icon and text."
            )
        }
    }

    @Test
    func nativeSearchFieldWrapperDoesNotDemandAFixedWidth() async throws {
        try await withIsolatedModel { model in
            let tab = model.openTab()
            let host = NSHostingView(
                rootView: ReaderSearchToolbar(
                    model: model,
                    tab: tab,
                    isActive: true,
                    focusRequest: 0,
                    isPanelPresented: .constant(false),
                    onSubmit: {}
                )
            )
            host.frame = NSRect(x: 0, y: 0, width: 320, height: 44)
            host.layoutSubtreeIfNeeded()

            let searchField = try #require(findSearchField(in: host))
            let wrapper = try #require(searchField.superview)
            #expect(
                wrapper.intrinsicContentSize.width == NSView.noIntrinsicMetric,
                "The native wrapper must accept the width left after the scope menu instead of overflowing it."
            )
        }
    }

    /// Each toolbar test owns its database, session files and preferences.
    /// Drain openTab's pending session save before removing the disposable root.
    private func withIsolatedModel(_ body: (AppModel) async throws -> Void) async throws {
        let identifier = UUID().uuidString
        let root = FileManager.default.temporaryDirectory
            .appending(path: "CruxToolbarTests-\(identifier)", directoryHint: .isDirectory)
        let suiteName = "dev.crux.toolbar-tests.\(identifier)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }
        let model = AppModel(
            preferences: ReaderPreferences(defaults: defaults),
            layout: AppDirectoryLayout(applicationSupportDirectory: root)
        )
        do {
            try await body(model)
        } catch {
            await model.shutdown()
            throw error
        }
        await model.shutdown()
    }

    private func findSearchField(in view: NSView) -> NSSearchField? {
        if let searchField = view as? NSSearchField {
            return searchField
        }
        for subview in view.subviews {
            if let searchField = findSearchField(in: subview) {
                return searchField
            }
        }
        return nil
    }
}
