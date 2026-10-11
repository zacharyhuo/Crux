import Foundation
import Testing
#if !BETA_RUNTIME_STANDALONE
import CruxCore
import WebKit
#endif
@testable import Crux

@MainActor
struct BetaIsolationTests {
    private let supportBase = URL(fileURLWithPath: "/fixture/Application Support", isDirectory: true)

    @Test
    func bundleIdentitySeparatesPersistentStorageAndDownloads() {
        let production = AppIdentity(bundleIdentifier: "com.zacharyhuo.Crux", isBetaBuild: false)
        let beta = AppIdentity(bundleIdentifier: "com.zacharyhuo.Crux.Beta", isBetaBuild: false)
        #expect(production.applicationSupportDirectory(in: supportBase).path == "/fixture/Application Support/Crux")
        #expect(beta.applicationSupportDirectory(in: supportBase).path == "/fixture/Application Support/Crux Beta")
        #expect(production.backgroundDownloadIdentifier == "com.zacharyhuo.Crux.docset-downloads")
        #expect(beta.backgroundDownloadIdentifier == "com.zacharyhuo.Crux.Beta.docset-downloads")
        #expect(production.displayName == "Crux")
        #expect(beta.displayName == "Crux Beta")
    }

    @Test
    func betaCompilationCannotFallBackToProductionIdentity() {
        for bundleIdentifier in [nil, "com.zacharyhuo.Crux"] as [String?] {
            let identity = AppIdentity(bundleIdentifier: bundleIdentifier, isBetaBuild: true)
            #expect(identity.applicationSupportDirectory(in: supportBase).lastPathComponent == "Crux Beta")
            #expect(identity.backgroundDownloadIdentifier == "com.zacharyhuo.Crux.Beta.docset-downloads")
        }
        let productionFallback = AppIdentity(bundleIdentifier: nil, isBetaBuild: false)
        #expect(productionFallback.backgroundDownloadIdentifier == "com.zacharyhuo.Crux.docset-downloads")
    }

    @Test
    func downloadNamespaceHonorsExplicitBundleIdentity() {
        let identity = AppIdentity(bundleIdentifier: "dev.crux.fixture", isBetaBuild: false)
        #expect(identity.backgroundDownloadIdentifier == "dev.crux.fixture.docset-downloads")
    }

    @Test
    func ordinaryBetaRuntimeKeepsFeaturesAndUsesItsOwnStorage() {
        let runtime = CruxAppRuntimeConfiguration.resolve(
            arguments: ["Crux Beta"], environment: [:],
            identity: AppIdentity(bundleIdentifier: "com.zacharyhuo.Crux.Beta", isBetaBuild: false),
            applicationSupportBaseDirectory: supportBase
        )
        #expect(runtime.applicationSupportDirectory?.path == "/fixture/Application Support/Crux Beta")
        // nil selects .standard, which belongs to the Beta app bundle. Never add the production suite.
        #expect(runtime.userDefaultsSuiteName == nil)
        #expect(runtime.backgroundDownloadIdentifier == "com.zacharyhuo.Crux.Beta.docset-downloads")
        #expect(runtime.usesBackgroundDownloads)
        #expect(!runtime.isUITesting)
    }

    @Test
    func productionRuntimeRetainsExistingDefaults() {
        let runtime = CruxAppRuntimeConfiguration.resolve(
            arguments: ["Crux"], environment: [:],
            identity: AppIdentity(bundleIdentifier: "com.zacharyhuo.Crux", isBetaBuild: false)
        )
        #expect(runtime.applicationSupportDirectory == nil)
        #expect(runtime.userDefaultsSuiteName == nil)
        #expect(runtime.backgroundDownloadIdentifier == "com.zacharyhuo.Crux.docset-downloads")
        #expect(runtime.usesBackgroundDownloads)
        #expect(!runtime.isUITesting)
    }

    @Test
    func betaTestHostStillUsesDisposableStorage() {
#if DEBUG
        let runtime = CruxAppRuntimeConfiguration.resolve(
            arguments: ["Crux Beta"], environment: ["XCTestBundlePath": "fixture"],
            fallbackIdentifier: "beta-fixture",
            identity: AppIdentity(bundleIdentifier: "com.zacharyhuo.Crux.Beta", isBetaBuild: false),
            applicationSupportBaseDirectory: supportBase
        )
        #expect(runtime.isUITesting)
        #expect(runtime.applicationSupportDirectory?.lastPathComponent == "CruxTests-beta-fixture")
        #expect(runtime.userDefaultsSuiteName == "com.zacharyhuo.CruxTests.beta-fixture")
        #expect(!runtime.usesBackgroundDownloads)
#endif
    }

    @Test
    func releaseBuildDoesNotAcceptTestRuntimeOverrides() {
#if !DEBUG
        let runtime = CruxAppRuntimeConfiguration.resolve(
            arguments: ["Crux Beta", "-crux-ui-testing"],
            environment: ["XCTestBundlePath": "fixture"],
            identity: AppIdentity(bundleIdentifier: "com.zacharyhuo.Crux.Beta", isBetaBuild: false),
            applicationSupportBaseDirectory: supportBase
        )
        #expect(!runtime.isUITesting)
        #expect(runtime.applicationSupportDirectory?.path == "/fixture/Application Support/Crux Beta")
        #expect(runtime.userDefaultsSuiteName == nil)
        #expect(runtime.usesBackgroundDownloads)
#endif
    }

    @Test
    func betaBuildDoesNotFallBackToProductionSupportDirectory() {
#if CRUX_BETA
        let runtime = CruxAppRuntimeConfiguration.resolve(arguments: ["Crux Beta"], environment: [:])
        #expect(runtime.applicationSupportDirectory?.lastPathComponent == "Crux Beta")
        #expect(!runtime.isUITesting)
        #expect(runtime.usesBackgroundDownloads)
#endif
    }

#if !BETA_RUNTIME_STANDALONE
    @Test
    @MainActor
    func injectedModelStorageAndDownloadIdentityArePreserved() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "CruxBetaIsolation-\(UUID().uuidString)", directoryHint: .isDirectory)
        let suiteName = "dev.crux.beta-isolation.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }
        let preferences = ReaderPreferences(defaults: defaults)
        let layout = AppDirectoryLayout(applicationSupportDirectory: root)
        let model = AppModel(
            preferences: preferences, layout: layout,
            backgroundDownloadIdentifier: "dev.crux.beta-isolation.docset-downloads"
        )
        #expect(model.layout == layout)
        #expect(model.currentDocsetsDirectory == layout.defaultDocsetsDirectory)
        #expect(model.backgroundDownloadIdentifier == "dev.crux.beta-isolation.docset-downloads")
        let tab = ReaderTab(state: ReaderTabState(), context: model)
        #expect(!tab.webView.configuration.websiteDataStore.isPersistent)
        #expect(tab.currentLocation == nil)
        await model.shutdown()
    }

    @Test
    @MainActor
    func modelDefaultLayoutIsBetaAwareWithoutOpeningUserData() {
        let layout = AppModel.defaultLayout(
            identity: AppIdentity(bundleIdentifier: "com.zacharyhuo.Crux.Beta", isBetaBuild: false),
            applicationSupportBaseDirectory: supportBase
        )
        #expect(layout.databaseURL.path == "/fixture/Application Support/Crux Beta/Crux.sqlite")
        #expect(layout.fullTextIndexURL.path == "/fixture/Application Support/Crux Beta/FullText.sqlite")
        #expect(layout.sessionDirectory.path == "/fixture/Application Support/Crux Beta/Session")
        #expect(layout.cacheDirectory.path == "/fixture/Application Support/Crux Beta/Cache")
        #expect(layout.downloadsDirectory.path == "/fixture/Application Support/Crux Beta/Downloads")
        #expect(LibrarySettings.default.bookmarkData == nil)
        #expect(LibrarySettings.default.resolvedDocsetsDirectory(layout: layout).path
            == "/fixture/Application Support/Crux Beta/Docsets")
    }
#endif
}
