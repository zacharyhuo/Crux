import Foundation

/// Persisted only after a successful install or explicit policy change.
/// A pin names one immutable build, including its revision, not a floating line.
public enum DocsetSelectionPolicy: Codable, Equatable, Hashable, Sendable {
    case latest
    case pinnedRelease(String)
}
