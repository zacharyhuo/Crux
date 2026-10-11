import Foundation
import Observation
import Sparkle

@MainActor
protocol ApplicationUpdating: AnyObject {
    var canCheckForUpdates: Bool { get }
    var isConfigured: Bool { get }
    var automaticallyChecksForUpdates: Bool { get set }
    var automaticallyDownloadsUpdates: Bool { get set }
    func start()
    func checkForUpdates()
}

struct AppUpdateConfiguration: Equatable, Sendable {
    let feedURL: URL
    let publicKey: String
    let channel: String
    let bundleIdentifier: String

    static func resolve(info: [String: Any], identity: AppIdentity) -> Self? {
        guard info["CFBundleIdentifier"] as? String == identity.bundleIdentifier,
              info["SUEnableInstallerLauncherService"] as? Bool == true,
              info["SURequireSignedFeed"] as? Bool == true,
              info["SUVerifyUpdateBeforeExtraction"] as? Bool == true,
              let value = info["SUFeedURL"] as? String, let url = URL(string: value),
              url.scheme == "https", url.host == "raw.githubusercontent.com", url.port == nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              let publicKey = info["SUPublicEDKey"] as? String,
              let bytes = Data(base64Encoded: publicKey), bytes.count == 32,
              bytes.base64EncodedString() == publicKey, bytes.contains(where: { $0 != 0 }) else { return nil }
        let channel = identity.isBeta ? "beta" : "stable"
        guard url.path == "/zacharyhuo/Crux/app-updates/\(channel)/appcast.xml" else { return nil }
        return Self(feedURL: url, publicKey: publicKey, channel: channel, bundleIdentifier: identity.bundleIdentifier)
    }
}

/// One shared updater implementation; branding selects a different feed/key and
/// Sparkle's preferences remain in the current bundle's own defaults domain.
@MainActor
@Observable
final class SparkleApplicationUpdater: NSObject, ApplicationUpdating, SPUUpdaterDelegate {
    private(set) var canCheckForUpdates = false
    private(set) var isConfigured = false
    private(set) var checksAutomatically = false
    private(set) var downloadsAutomatically = false

    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private let configuration: AppUpdateConfiguration?
    @ObservationIgnored private let isTesting: Bool
    @ObservationIgnored private var started = false

    init(bundle: Bundle = .main, identity: AppIdentity = .current, isTesting: Bool) {
        configuration = AppUpdateConfiguration.resolve(info: bundle.infoDictionary ?? [:], identity: identity)
        self.isTesting = isTesting
        super.init()
        isConfigured = configuration != nil && !isTesting
    }

    var automaticallyChecksForUpdates: Bool {
        get { checksAutomatically }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    var automaticallyDownloadsUpdates: Bool {
        get { downloadsAutomatically }
        set { controller?.updater.automaticallyDownloadsUpdates = newValue }
    }

    func start() {
        guard !started, isConfigured, !isTesting else { return }
        started = true
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        let updater = controller.updater
        let sync: @Sendable (SPUUpdater, NSKeyValueObservedChange<Bool>) -> Void = { [weak self] updater, _ in
            Task { @MainActor [weak self] in
                self?.canCheckForUpdates = updater.canCheckForUpdates
                self?.checksAutomatically = updater.automaticallyChecksForUpdates
                self?.downloadsAutomatically = updater.automaticallyDownloadsUpdates
            }
        }
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.initial, .new], changeHandler: sync),
            updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new], changeHandler: sync),
            updater.observe(\.automaticallyDownloadsUpdates, options: [.initial, .new], changeHandler: sync)
        ]
        controller.startUpdater()
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        controller?.checkForUpdates(nil)
    }

    func feedURLString(for updater: SPUUpdater) -> String? { configuration?.feedURL.absoluteString }
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        configuration?.channel == "beta" ? ["beta"] : []
    }
}
