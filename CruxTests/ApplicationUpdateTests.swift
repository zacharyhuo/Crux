import Foundation
import CruxCore
import Testing
@testable import Crux

@MainActor
struct ApplicationUpdateTests {
    private let key = Data(repeating: 1, count: 32).base64EncodedString()
    private func info(_ beta: Bool) -> [String: Any] {
        ["CFBundleIdentifier": beta ? "com.zacharyhuo.Crux.Beta" : "com.zacharyhuo.Crux",
         "SUFeedURL": "https://raw.githubusercontent.com/zacharyhuo/Crux/app-updates/\(beta ? "beta" : "stable")/appcast.xml",
         "SUPublicEDKey": key, "SUEnableInstallerLauncherService": true,
         "SURequireSignedFeed": true, "SUVerifyUpdateBeforeExtraction": true]
    }

    @Test
    func builtAppIncludesSparkleSandboxAndSignedFeedPolicy() {
        let info = Bundle.main.infoDictionary ?? [:]
        let channel = AppIdentity.current.isBeta ? "beta" : "stable"
        #expect(info["SUFeedURL"] as? String == "https://raw.githubusercontent.com/zacharyhuo/Crux/app-updates/\(channel)/appcast.xml")
        #expect(info["SUEnableInstallerLauncherService"] as? Bool == true)
        #expect(info["SUEnableDownloaderService"] as? Bool == false)
        #expect(info["SURequireSignedFeed"] as? Bool == true)
        #expect(info["SUVerifyUpdateBeforeExtraction"] as? Bool == true)
        #expect(info["SUShowReleaseNotes"] as? Bool == true)
        #expect(Bundle.main.url(forResource: "Sparkle-LICENSE", withExtension: "txt") != nil)
    }

    @Test
    func updateConfigurationSeparatesBrandAndRejectsCrossChannelOrMissingKeys() {
        for beta in [false, true] {
            let identity = AppIdentity(bundleIdentifier: beta ? "com.zacharyhuo.Crux.Beta" : "com.zacharyhuo.Crux", isBetaBuild: beta)
            let config = AppUpdateConfiguration.resolve(info: info(beta), identity: identity)
            #expect(config?.channel == (beta ? "beta" : "stable"))
            #expect(AppUpdateConfiguration.resolve(info: info(!beta), identity: identity) == nil)
            var changed = info(beta)
            changed["SUPublicEDKey"] = ""
            #expect(AppUpdateConfiguration.resolve(info: changed, identity: identity) == nil)
            changed["SUPublicEDKey"] = key
            changed["SURequireSignedFeed"] = false
            #expect(AppUpdateConfiguration.resolve(info: changed, identity: identity) == nil)
            changed["SURequireSignedFeed"] = true
            changed["SUFeedURL"] = "http://raw.githubusercontent.com/zacharyhuo/Crux/app-updates/stable/appcast.xml"
            #expect(AppUpdateConfiguration.resolve(info: changed, identity: identity) == nil)
        }
    }

    @Test
    func testRuntimeNeverStartsStandardUpdaterOrReadsPersistentSparklePreferences() {
        let updater = SparkleApplicationUpdater(isTesting: true)
        updater.start()
        updater.checkForUpdates()
        #expect(!updater.isConfigured && !updater.canCheckForUpdates)
        #expect(!updater.automaticallyChecksForUpdates && !updater.automaticallyDownloadsUpdates)
    }

    @Test
    func menuUpdateActionUsesInjectedUpdaterWithoutGitHubPolling() async throws {
        let updater = RecordingUpdater()
        let root = FileManager.default.temporaryDirectory.appending(path: "CruxUpdater-\(UUID())")
        let defaults = try #require(UserDefaults(suiteName: root.lastPathComponent))
        defer {
            defaults.removePersistentDomain(forName: root.lastPathComponent)
            try? FileManager.default.removeItem(at: root)
        }
        let model = AppModel(preferences: ReaderPreferences(defaults: defaults),
                             layout: AppDirectoryLayout(applicationSupportDirectory: root), applicationUpdater: updater)
        await model.checkForNewRelease()
        #expect(updater.checks == 1)
    }
}

@MainActor
private final class RecordingUpdater: ApplicationUpdating {
    let canCheckForUpdates = true
    let isConfigured = true
    var automaticallyChecksForUpdates = false
    var automaticallyDownloadsUpdates = false
    var checks = 0
    func start() {}
    func checkForUpdates() { checks += 1 }
}
