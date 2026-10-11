import Foundation

/// The distribution's storage and display identity. Keep production paths stable;
/// a Beta build must never silently reuse them, even without bundle metadata.
struct AppIdentity: Sendable {
#if CRUX_BETA
    static let isBetaBuild = true
#else
    static let isBetaBuild = false
#endif

    static let current = AppIdentity()

    let bundleIdentifier: String
    let isBeta: Bool

    init(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        isBetaBuild: Bool = AppIdentity.isBetaBuild
    ) {
        isBeta = isBetaBuild || bundleIdentifier == "com.zacharyhuo.Crux.Beta"
        self.bundleIdentifier = isBeta
            ? "com.zacharyhuo.Crux.Beta"
            : (bundleIdentifier ?? "com.zacharyhuo.Crux")
    }

    var displayName: String { isBeta ? "Crux Beta" : "Crux" }

    var backgroundDownloadIdentifier: String { "\(bundleIdentifier).docset-downloads" }

    static var applicationSupportBaseDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }

    func applicationSupportDirectory(in base: URL = Self.applicationSupportBaseDirectory) -> URL {
        base.appending(path: displayName, directoryHint: .isDirectory)
    }
}
