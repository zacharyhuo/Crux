import Foundation

/// The identity Crux uses to decide whether a docset is out of date.
///
/// Dash publishes both a human version string and an integer revision. The
/// revision changes when the content is rebuilt without a version bump, so both
/// have to participate in the comparison.
public struct DocsetVersion: Codable, Equatable, Comparable, Sendable {
    public let version: String?
    public let revision: Int?

    public init(version: String?, revision: Int?) {
        self.version = version.flatMap { $0.isEmpty ? nil : $0 }
        self.revision = revision
    }

    public init(descriptor: DocsetDescriptor) {
        self.init(version: descriptor.version, revision: descriptor.revision)
    }

    public static func < (lhs: DocsetVersion, rhs: DocsetVersion) -> Bool {
        switch compareVersionStrings(lhs.version, rhs.version) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return (lhs.revision ?? 0) < (rhs.revision ?? 0)
        }
    }

    /// Compares dotted version strings numerically where possible.
    ///
    /// `1.10` must sort above `1.9`, which a plain string comparison gets wrong.
    /// Non-numeric segments fall back to a case-insensitive comparison so tags
    /// such as `2.0-beta` still order deterministically.
    static func compareVersionStrings(_ lhs: String?, _ rhs: String?) -> ComparisonResult {
        switch (lhs, rhs) {
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedAscending
        case (_, nil): return .orderedDescending
        case let (lhs?, rhs?):
            let lhsSegments = segments(of: lhs)
            let rhsSegments = segments(of: rhs)
            for index in 0..<max(lhsSegments.count, rhsSegments.count) {
                let left = index < lhsSegments.count ? lhsSegments[index] : "0"
                let right = index < rhsSegments.count ? rhsSegments[index] : "0"
                if let leftNumber = Int(left), let rightNumber = Int(right) {
                    if leftNumber != rightNumber {
                        return leftNumber < rightNumber ? .orderedAscending : .orderedDescending
                    }
                    continue
                }
                let comparison = left.compare(right, options: [.caseInsensitive])
                if comparison != .orderedSame { return comparison }
            }
            return .orderedSame
        }
    }

    private static func segments(of value: String) -> [String] {
        value
            .split(whereSeparator: { $0 == "." || $0 == "-" || $0 == "_" || $0 == "+" })
            .map(String.init)
    }
}
