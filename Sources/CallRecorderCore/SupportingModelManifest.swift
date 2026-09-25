import Foundation

/// One verified file inside an installed supporting model.
public struct InstalledSupportingFile: Codable, Equatable, Sendable {
    public let path: String
    public let bytes: Int64
    public let sha256: String

    public init(path: String, bytes: Int64, sha256: String) {
        self.path = path
        self.bytes = bytes
        self.sha256 = sha256
    }
}

/// What is on disk for one supporting model, recorded when its files were last verified.
///
/// The record is what an update check compares against the host. Hashing a 200 MB model to
/// answer a question that two short strings can answer would make every check cost seconds.
public struct InstalledSupportingModel: Codable, Equatable, Sendable {
    public let modelID: String
    public let revision: String
    /// The revision kept from before the last update, when there is one to go back to.
    public var previousRevision: String?
    public let installedAt: Date
    public let files: [InstalledSupportingFile]

    public init(
        modelID: String,
        revision: String,
        previousRevision: String? = nil,
        installedAt: Date,
        files: [InstalledSupportingFile]
    ) {
        self.modelID = modelID
        self.revision = revision
        self.previousRevision = previousRevision
        self.installedAt = installedAt
        self.files = files
    }

    public var totalBytes: Int64 {
        files.reduce(0) { $0 + $1.bytes }
    }

    public func file(_ path: String) -> InstalledSupportingFile? {
        files.first { $0.path == path }
    }

}

/// The set of supporting models this Mac has installed and verified.
///
/// Stored beside the models themselves. Files with no record are treated as unverified, which is
/// the honest answer: nothing has confirmed what those bytes are.
public struct SupportingModelManifest: Codable, Equatable, Sendable {
    public private(set) var records: [String: InstalledSupportingModel]

    public init(records: [String: InstalledSupportingModel] = [:]) {
        self.records = records
    }

    public func record(for modelID: String) -> InstalledSupportingModel? {
        records[modelID]
    }

    public mutating func record(_ value: InstalledSupportingModel) {
        records[value.modelID] = value
    }

    public mutating func remove(_ modelID: String) {
        records[modelID] = nil
    }

    /// Reads a manifest, treating a missing or unreadable file as empty rather than failing.
    /// A check must still work on a Mac whose manifest was never written.
    /// The one place the manifest lives, so a reader that is not the manager can find it.
    public static func defaultURL(in applicationDirectory: URL) -> URL {
        applicationDirectory.appending(path: "models/components.json")
    }

    public static func load(from url: URL) -> SupportingModelManifest {
        guard let data = try? Data(contentsOf: url) else { return SupportingModelManifest() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(SupportingModelManifest.self, from: data))
            ?? SupportingModelManifest()
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(self)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Write beside the target and swap, so an interrupted save cannot truncate the manifest.
        let temporary = url.appendingPathExtension("partial")
        try data.write(to: temporary, options: .atomic)
        _ = try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: temporary, to: url)
    }
}
