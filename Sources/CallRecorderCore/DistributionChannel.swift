import Foundation

/// The rules that differ between the independently distributed and App Store builds.
public enum DistributionChannel: String, Sendable {
    case direct
    case appStore = "app-store"

    public static let infoDictionaryKey = "CRDistributionChannel"

    /// Resolves a channel without consulting process state, so packaging policy is testable.
    public static func resolve(infoDictionary: [String: Any]?) -> DistributionChannel {
        guard
            let value = infoDictionary?[infoDictionaryKey] as? String,
            let channel = DistributionChannel(rawValue: value.lowercased())
        else {
            return .direct
        }
        return channel
    }

    public static var current: DistributionChannel {
        resolve(infoDictionary: Bundle.main.infoDictionary)
    }

    public var allowsSelfUpdate: Bool { self == .direct }
    public var allowsExternalToolSelection: Bool { self == .direct }
    public var allowsDownloadedExecutableRuntime: Bool { self == .direct }
    public var usesSecurityScopedOutputBookmarks: Bool { self == .appStore }
}
