import Foundation

/// One file attached to a release.
public struct AppReleaseAsset: Equatable, Sendable {
    public let name: String
    public let bytes: Int64
    public let downloadURL: URL
    /// The digest the host publishes for this file, as `sha256:<hex>`, when it publishes one.
    public let digest: String?

    public init(name: String, bytes: Int64, downloadURL: URL, digest: String?) {
        self.name = name
        self.bytes = bytes
        self.downloadURL = downloadURL
        self.digest = digest
    }

    /// The hex digest with the algorithm prefix removed, or nil when the host published none.
    ///
    /// A digest that is not a sha256 is refused rather than compared against something else: the
    /// only promise this app can keep is the one the host actually made.
    public var sha256: String? {
        guard let digest else { return nil }
        let prefix = "sha256:"
        guard digest.lowercased().hasPrefix(prefix) else { return nil }
        let value = String(digest.dropFirst(prefix.count)).lowercased()
        guard value.count == 64, value.allSatisfy(\.isHexDigit) else { return nil }
        return value
    }
}

/// One release of this app, as the host describes it.
public struct AppRelease: Equatable, Sendable {
    public let tag: String
    /// The tag with a leading `v` removed: what the bundle inside the archive must call itself.
    public let version: String
    public let pageURL: URL
    public let publishedAt: Date?
    /// The archive for this Mac, or nil when the release carries none.
    ///
    /// A release without one is kept rather than dropped, so a version that is published before
    /// its archive is reported as unofferable instead of silently looking current.
    public let asset: AppReleaseAsset?

    public init(
        tag: String,
        version: String,
        pageURL: URL,
        publishedAt: Date?,
        asset: AppReleaseAsset?
    ) {
        self.tag = tag
        self.version = version
        self.pageURL = pageURL
        self.publishedAt = publishedAt
        self.asset = asset
    }
}

/// What a check against the host concluded.
public enum AppReleaseDecision: Equatable, Sendable {
    case upToDate(version: String)
    case update(AppRelease)
    /// The check could not reach a verdict, and says why rather than guessing.
    case cannotVerify(reason: String)

    public var isUpdateAvailable: Bool {
        if case .update = self { return true }
        return false
    }
}

/// How often the app looks for a newer release of itself while it stays open.
///
/// The check is one request to the release list, so the short steps cost little and are there for
/// someone who is waiting for a release; the long ones are for a Mac that would rather not hear
/// about one until it is next opened. Six steps, roughly doubled, are enough to cover both without
/// asking anyone to type a number.
public enum AppUpdateInterval: String, CaseIterable, Codable, Sendable, Identifiable {
    case everyThirtyMinutes = "30m"
    case hourly = "1h"
    case everyTwoHours = "2h"
    case everySixHours = "6h"
    case everyTwelveHours = "12h"
    case daily = "24h"

    public var id: String { rawValue }

    /// What the app shipped with, and the step a settings blob written before the choice existed
    /// lands on.
    public static let `default` = AppUpdateInterval.everySixHours

    /// The seconds between two checks.
    public var seconds: TimeInterval {
        switch self {
        case .everyThirtyMinutes: 30 * 60
        case .hourly: 60 * 60
        case .everyTwoHours: 2 * 60 * 60
        case .everySixHours: 6 * 60 * 60
        case .everyTwelveHours: 12 * 60 * 60
        case .daily: 24 * 60 * 60
        }
    }

    /// The menu item, which stands on its own.
    public var title: String {
        switch self {
        case .everyThirtyMinutes: "Every 30 minutes"
        case .hourly: "Every hour"
        case .everyTwoHours: "Every 2 hours"
        case .everySixHours: "Every 6 hours"
        case .everyTwelveHours: "Every 12 hours"
        case .daily: "Once a day"
        }
    }

    /// The same step inside a sentence: "Checked at launch and every 6 hours."
    public var phrase: String {
        switch self {
        case .everyThirtyMinutes: "every 30 minutes"
        case .hourly: "every hour"
        case .everyTwoHours: "every 2 hours"
        case .everySixHours: "every 6 hours"
        case .everyTwelveHours: "every 12 hours"
        case .daily: "once a day"
        }
    }
}

/// Orders the dotted version numbers the app is built with.
public enum AppVersionOrder {
    /// `v0.1.4` and `0.1.4` both read as `[0, 1, 4]`; anything else reads as nil.
    ///
    /// A tag the app cannot read, such as the `runtime-<hash>` tags the indexer runtime is
    /// published under, is not a version and is left out of every comparison.
    public static func numbers(in raw: String) -> [Int]? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        guard !text.isEmpty else { return nil }
        var numbers: [Int] = []
        for component in text.split(separator: ".", omittingEmptySubsequences: false) {
            guard !component.isEmpty, component.allSatisfy(\.isNumber) else { return nil }
            // A component too long for an Int is not a version this app should act on.
            guard let value = Int(component) else { return nil }
            numbers.append(value)
        }
        return numbers.isEmpty ? nil : numbers
    }

    /// Whether `candidate` names a later version than `current`.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard
            let left = numbers(in: candidate),
            let right = numbers(in: current)
        else { return false }
        let width = max(left.count, right.count)
        for index in 0..<width {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a > b }
        }
        return false
    }
}

/// The published releases, read from the host's own description of them.
public enum AppReleaseCatalog {
    /// The archive a release offers is named for the version it contains, which is also what makes
    /// the runtime releases harmless here: `CallRecorder-runtime-<hash>.zip` matches no version.
    public static func assetName(for version: String) -> String { "CallRecorder-\(version).zip" }

    /// The endpoint that lists the releases, newest first.
    public static func url(repository: String) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.github.com"
        components.path = "/repos/\(repository)/releases"
        components.queryItems = [URLQueryItem(name: "per_page", value: "20")]
        return components.url!
    }

    /// Reads the host's release list.
    ///
    /// Drafts and pre-releases are left out: neither is something to install without being asked.
    public static func parse(_ data: Data) throws -> [AppRelease] {
        let decoder = JSONDecoder()
        let entries: [Entry]
        do {
            entries = try decoder.decode([Entry].self, from: data)
        } catch {
            throw AppUpdateReadingError.malformedReleaseList(error.localizedDescription)
        }
        var releases: [AppRelease] = []
        for entry in entries {
            guard !entry.draft, !entry.prerelease else { continue }
            guard let version = version(fromTag: entry.tagName), let page = URL(string: entry.htmlURL) else {
                continue
            }
            let wanted = assetName(for: version)
            let match = entry.assets.first { $0.name == wanted }
            let asset = match.flatMap { asset in
                URL(string: asset.browserDownloadURL).map { url in
                    AppReleaseAsset(
                        name: asset.name,
                        bytes: asset.size,
                        downloadURL: url,
                        digest: asset.digest
                    )
                }
            }
            releases.append(
                AppRelease(
                    tag: entry.tagName,
                    version: version,
                    pageURL: page,
                    publishedAt: entry.publishedAt.flatMap(Self.date(from:)),
                    asset: asset
                )
            )
        }
        return releases
    }

    /// The latest release, when one is newer than what is installed.
    public static func newest(in releases: [AppRelease], newerThan current: String) -> AppRelease? {
        releases
            .filter { AppVersionOrder.isNewer($0.version, than: current) }
            .max { left, right in
                AppVersionOrder.isNewer(right.version, than: left.version)
            }
    }

    /// Reads the list and decides what this Mac should do about it.
    public static func decision(releases: [AppRelease], currentVersion: String) -> AppReleaseDecision {
        guard AppVersionOrder.numbers(in: currentVersion) != nil else {
            return .cannotVerify(
                reason: "The version this copy of Call Recorder reports (\(currentVersion)) is not a version number."
            )
        }
        guard let newest = newest(in: releases, newerThan: currentVersion) else {
            return .upToDate(version: currentVersion)
        }
        guard newest.asset != nil else {
            return .cannotVerify(
                reason: "Version \(newest.version) is published without an app archive to install."
            )
        }
        return .update(newest)
    }

    /// The part of a tag that names a version, or nil for a tag that names something else.
    static func version(fromTag tag: String) -> String? {
        var text = tag
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        guard AppVersionOrder.numbers(in: text) != nil else { return nil }
        return text
    }

    /// The host writes ISO-8601 timestamps, without fractional seconds at this endpoint.
    static func date(from text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let value = plain.date(from: text) { return value }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }

    private struct Entry: Decodable {
        let tagName: String
        let htmlURL: String
        let draft: Bool
        let prerelease: Bool
        let publishedAt: String?
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case draft
            case prerelease
            case publishedAt = "published_at"
            case assets
        }

        struct Asset: Decodable {
            let name: String
            let size: Int64
            let browserDownloadURL: String
            let digest: String?

            enum CodingKeys: String, CodingKey {
                case name
                case size
                case browserDownloadURL = "browser_download_url"
                case digest
            }
        }
    }
}

public enum AppUpdateReadingError: LocalizedError, Equatable, Sendable {
    case malformedReleaseList(String)

    public var errorDescription: String? {
        switch self {
        case .malformedReleaseList(let detail):
            "The release list could not be read. " + detail
        }
    }
}
