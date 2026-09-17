import Foundation

/// One model file exactly as the host publishes it.
public struct RemoteModelFile: Codable, Equatable, Sendable {
    public let fileName: String
    public let bytes: Int64
    public let sha256: String

    public init(fileName: String, bytes: Int64, sha256: String) {
        self.fileName = fileName
        self.bytes = bytes
        self.sha256 = sha256
    }
}

/// What is on disk for one model, recorded when the file was last verified.
///
/// The record exists so an update check never has to re-read a multi-gigabyte file. Hashing
/// whisper's medium model takes seconds; comparing two short strings does not.
public struct InstalledModelRecord: Codable, Equatable, Sendable {
    public let modelID: String
    public let fileName: String
    public let sha256: String
    public let bytes: Int64
    /// The host revision the file was fetched from, for diagnostics only.
    public let revision: String
    public let installedAt: Date

    public init(
        modelID: String,
        fileName: String,
        sha256: String,
        bytes: Int64,
        revision: String,
        installedAt: Date
    ) {
        self.modelID = modelID
        self.fileName = fileName
        self.sha256 = sha256
        self.bytes = bytes
        self.revision = revision
        self.installedAt = installedAt
    }
}

/// The outcome of comparing an installed model with the host's current copy.
public enum ModelUpdateDecision: Equatable, Sendable {
    case upToDate
    case updateAvailable(RemoteModelFile)
    /// The check could not reach a verdict. Call Recorder reports this instead of guessing,
    /// because replacing a working model with an unverified one is worse than staying behind.
    case cannotVerify(reason: String)

    public var isUpdateAvailable: Bool {
        if case .updateAvailable = self { return true }
        return false
    }

    public var hasVerdict: Bool {
        if case .cannotVerify = self { return false }
        return true
    }
}

public enum ModelUpdateChecker {
    /// Compares what is installed with what the host offers.
    ///
    /// A verdict needs both sides to publish a hash. Anything less returns cannotVerify, so a
    /// host that stops publishing hashes, or a model installed before records existed, is
    /// reported as unknown rather than silently treated as current.
    public static func decision(
        installed: InstalledModelRecord?,
        remote: RemoteModelFile?
    ) -> ModelUpdateDecision {
        guard let remote else {
            return .cannotVerify(reason: "The host does not publish a hash for this model.")
        }
        guard let installed else {
            return .cannotVerify(reason: "Call Recorder has not verified this model copy yet.")
        }
        let installedHash = installed.sha256.lowercased()
        let remoteHash = remote.sha256.lowercased()
        guard !remoteHash.isEmpty, !installedHash.isEmpty else {
            return .cannotVerify(reason: "One of the hashes is empty.")
        }
        if installedHash == remoteHash { return .upToDate }
        return .updateAvailable(remote)
    }
}

/// The set of models this Mac has installed and verified.
///
/// Stored beside the models themselves. A model file with no record is treated as unverified,
/// which is the honest answer: nothing has confirmed what that file contains.
public struct ModelManifest: Codable, Equatable, Sendable {
    public private(set) var records: [String: InstalledModelRecord]

    public init(records: [String: InstalledModelRecord] = [:]) {
        self.records = records
    }

    public func record(for modelID: String) -> InstalledModelRecord? {
        records[modelID]
    }

    public mutating func record(_ value: InstalledModelRecord) {
        records[value.modelID] = value
    }

    public mutating func remove(_ modelID: String) {
        records[modelID] = nil
    }

    /// Reads a manifest, treating a missing or unreadable file as empty rather than failing.
    /// An update check must still work on a Mac whose manifest was never written.
    public static func load(from url: URL) -> ModelManifest {
        guard let data = try? Data(contentsOf: url) else { return ModelManifest() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(ModelManifest.self, from: data)) ?? ModelManifest()
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

/// The published file list for one model repository.
public struct ModelHostMetadata: Equatable, Sendable {
    public let revision: String
    public let files: [String: RemoteModelFile]

    public init(revision: String, files: [String: RemoteModelFile]) {
        self.revision = revision
        self.files = files
    }

    /// The metadata endpoint for one repository, asking the host to include file sizes and
    /// hashes. Without `blobs=true` the response omits both.
    public static func url(repository: String) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "huggingface.co"
        components.path = "/api/models/\(repository)"
        components.queryItems = [URLQueryItem(name: "blobs", value: "true")]
        return components.url!
    }

    /// Parses the host's repository description.
    ///
    /// Files without a published SHA-256 are left out, so a later comparison reports
    /// cannotVerify instead of offering an unverifiable download.
    public static func parse(_ data: Data) throws -> ModelHostMetadata {
        let decoder = JSONDecoder()
        let document = try decoder.decode(HostDocument.self, from: data)
        var files: [String: RemoteModelFile] = [:]
        for sibling in document.siblings {
            guard let hash = sibling.lfs?.sha256, !hash.isEmpty else { continue }
            guard let size = sibling.size else { continue }
            files[sibling.rfilename] = RemoteModelFile(
                fileName: sibling.rfilename,
                bytes: size,
                sha256: hash
            )
        }
        return ModelHostMetadata(revision: document.sha, files: files)
    }

    private struct HostDocument: Decodable {
        let sha: String
        let siblings: [Sibling]

        struct Sibling: Decodable {
            let rfilename: String
            let size: Int64?
            let lfs: LargeFile?
        }

        struct LargeFile: Decodable {
            let sha256: String?
        }
    }
}
