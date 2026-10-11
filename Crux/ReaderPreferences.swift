import Foundation
import Observation

/// User-visible reading preferences, persisted in `UserDefaults`.
///
/// Remote-resource control is deliberately two-level: a global switch plus a
/// per-docset exception list, so a single noisy docset can be muted without
/// giving up remote content everywhere.
@MainActor
@Observable
final class ReaderPreferences {
    private enum Key {
        static let appearance = "app.appearance"
        static let allowsRemoteResources = "reader.allowsRemoteResources"
        static let restoresLastSession = "reader.restoresLastSession"
        static let docsetsBlockingRemoteResources = "reader.docsetsBlockingRemoteResources"
        static let hasSeenRemoteResourceNotice = "reader.hasSeenRemoteResourceNotice"
    }

    private let defaults: UserDefaults

    var appearance: AppAppearance {
        didSet { defaults.set(appearance.rawValue, forKey: Key.appearance) }
    }

    var allowsRemoteResources: Bool {
        didSet { defaults.set(allowsRemoteResources, forKey: Key.allowsRemoteResources) }
    }

    var restoresLastSession: Bool {
        didSet { defaults.set(restoresLastSession, forKey: Key.restoresLastSession) }
    }

    /// Docsets the user explicitly opted out of, even while the global switch is on.
    private(set) var docsetsBlockingRemoteResources: Set<String> {
        didSet {
            defaults.set(Array(docsetsBlockingRemoteResources).sorted(), forKey: Key.docsetsBlockingRemoteResources)
        }
    }

    /// Whether the privacy explanation has already been acknowledged.
    var hasSeenRemoteResourceNotice: Bool {
        didSet { defaults.set(hasSeenRemoteResourceNotice, forKey: Key.hasSeenRemoteResourceNotice) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.appearance: AppAppearance.system.rawValue,
            Key.allowsRemoteResources: true,
            Key.restoresLastSession: true,
        ])
        appearance = defaults.string(forKey: Key.appearance).flatMap(AppAppearance.init(rawValue:)) ?? .system
        allowsRemoteResources = defaults.bool(forKey: Key.allowsRemoteResources)
        restoresLastSession = defaults.bool(forKey: Key.restoresLastSession)
        docsetsBlockingRemoteResources = Set(
            defaults.stringArray(forKey: Key.docsetsBlockingRemoteResources) ?? []
        )
        hasSeenRemoteResourceNotice = defaults.bool(forKey: Key.hasSeenRemoteResourceNotice)
    }

    func allowsRemoteResources(forDocset identifier: String) -> Bool {
        allowsRemoteResources && !docsetsBlockingRemoteResources.contains(identifier)
    }

    func setAllowsRemoteResources(_ isAllowed: Bool, forDocset identifier: String) {
        if isAllowed {
            docsetsBlockingRemoteResources.remove(identifier)
        } else {
            docsetsBlockingRemoteResources.insert(identifier)
        }
    }
}
