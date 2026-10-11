import AppKit
import CruxCore
import SwiftUI

private enum MainWindowMetrics {
    static let minimumFrameSize = NSSize(width: 856, height: 692)
    static let minimumContentSize = NSWindow.contentRect(
        forFrameRect: NSRect(origin: .zero, size: minimumFrameSize),
        styleMask: [.titled, .closable, .miniaturizable, .resizable]
    ).size
}

/// Separates automation from the real user's database, session, preferences,
/// docsets and background URLSession. The override is intentionally available
/// only in Debug builds and only behind an explicit process marker.
struct CruxAppRuntimeConfiguration {
    let isUITesting: Bool
    let applicationSupportDirectory: URL?
    let userDefaultsSuiteName: String?
    let usesBackgroundDownloads: Bool
    let backgroundDownloadIdentifier: String

    static func resolve(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fallbackIdentifier: String = UUID().uuidString,
        identity: AppIdentity = .current,
        applicationSupportBaseDirectory: URL = AppIdentity.applicationSupportBaseDirectory
    ) -> Self {
#if DEBUG
        let isXCTestHost = environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
        if arguments.contains("-crux-ui-testing") || isXCTestHost {
            // Never accept a filesystem path or defaults domain from the
            // environment. A test process always receives a fresh internal
            // namespace rooted under the system temporary directory.
            let supportDirectory = FileManager.default.temporaryDirectory.appending(
                path: "CruxTests-\(fallbackIdentifier)",
                directoryHint: .isDirectory
            )
            let suiteName = "com.zacharyhuo.CruxTests.\(fallbackIdentifier)"

            return Self(
                isUITesting: true,
                applicationSupportDirectory: supportDirectory,
                userDefaultsSuiteName: suiteName,
                usesBackgroundDownloads: false,
                backgroundDownloadIdentifier: "\(suiteName).docset-downloads"
            )
        }
#endif

        return Self(
            isUITesting: false,
            applicationSupportDirectory: identity.isBeta
                ? identity.applicationSupportDirectory(in: applicationSupportBaseDirectory) : nil,
            userDefaultsSuiteName: nil,
            usesBackgroundDownloads: true,
            backgroundDownloadIdentifier: identity.backgroundDownloadIdentifier
        )
    }
}

/// The process entry point for Crux.
///
/// The scenes declared here define the windows and commands that macOS owns
/// for the lifetime of the process.
@main
struct CruxApp: App {
    @State private var model: AppModel
    @State private var applicationUpdater: SparkleApplicationUpdater

    init() {
        let runtime = CruxAppRuntimeConfiguration.resolve()
        let applicationUpdater = SparkleApplicationUpdater(isTesting: runtime.isUITesting)
        _applicationUpdater = State(initialValue: applicationUpdater)
        let defaults: UserDefaults
        if let suiteName = runtime.userDefaultsSuiteName {
            guard let isolatedDefaults = UserDefaults(suiteName: suiteName) else {
                preconditionFailure("Unable to create the isolated UI-test defaults suite")
            }
            defaults = isolatedDefaults
        } else {
            defaults = .standard
        }

        let preferences = ReaderPreferences(defaults: defaults)
        if runtime.isUITesting {
            preferences.hasSeenRemoteResourceNotice = true
            preferences.restoresLastSession = false
        }

        var catalogClient: (any CatalogClient)?
        var downloadClient: (any DownloadClient)?
#if DEBUG
        do {
            if let fixture = try VersionedLibraryUITestConfiguration.resolve(runtime: runtime) {
                catalogClient = fixture.catalog
                downloadClient = fixture.downloads
            }
        } catch {
            preconditionFailure("Unable to prepare isolated version UI fixtures: \(error)")
        }
#endif

        _model = State(initialValue: AppModel(
            preferences: preferences,
            layout: runtime.applicationSupportDirectory.map {
                AppDirectoryLayout(applicationSupportDirectory: $0)
            },
            catalogClient: catalogClient,
            downloadClient: downloadClient,
            usesBackgroundDownloads: runtime.usesBackgroundDownloads,
            backgroundDownloadIdentifier: runtime.backgroundDownloadIdentifier,
            applicationUpdater: applicationUpdater
        ))

        // Crux owns document tabs inside its SwiftUI workspace. AppKit's second,
        // window-level tab system would duplicate that model and reintroduce
        // Show Tab Bar / Show All Tabs in View, so opt out before any window is
        // created.
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    var body: some Scene {
        WindowGroup(AppIdentity.current.displayName) {
            ContentView(model: model)
                .task { applicationUpdater.start() }
                .frame(
                    minWidth: MainWindowMetrics.minimumContentSize.width,
                    minHeight: MainWindowMetrics.minimumContentSize.height
                )
                .onReceive(
                    NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
                ) { _ in
                    // Termination notifications do not wait for asynchronous
                    // work. Persist the visible tab/history state inline, then
                    // drain background services on a best-effort task.
                    model.saveSessionBeforeTermination()
                    Task { await model.shutdown() }
                }
        }
        .defaultSize(width: 1_180, height: 760)
        .windowResizability(.contentMinSize)
        .windowStyle(.titleBar)
        .windowBackgroundDragBehavior(.disabled)
        .commands {
            CruxCommands(model: model)
        }

        Settings {
            SettingsView(model: model)
        }
    }
}
