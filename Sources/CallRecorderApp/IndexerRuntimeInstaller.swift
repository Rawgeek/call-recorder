import CallRecorderCore
import Foundation
import Observation

enum IndexerRuntimeError: LocalizedError {
    case nowhereToFetch
    case hashMismatch
    case noUnpacker
    case unpackFailed(String)

    var errorDescription: String? {
        switch self {
        case .nowhereToFetch:
            "This build does not say where to fetch the indexer runtime from."
        case .hashMismatch:
            "The downloaded indexer runtime does not match the hash recorded when the app was built."
        case .noUnpacker:
            "This build has no unpacker for the indexer runtime."
        case .unpackFailed(let message):
            "The indexer runtime could not be unpacked. " + message
        }
    }
}

/// Fetches the JavaScript runtime the transcript indexer and the MCP server both run on.
///
/// The runtime is 36 MB archived and 95 MB unpacked, and 36 MB of the 49 MB the app used to weigh
/// was that one archive. It travels as a release asset now. The app fetches it once with the same
/// byte-counted downloader the models use and keeps the archive in Application Support, where the
/// shim beside the executable unpacks it. Codex can start the MCP server with no app running, so
/// the shim fetches the archive itself when it has to; both paths write the same file, and the hash
/// in the bundle decides whether what arrived is accepted.
///
/// The archive is kept after unpacking. A Mac that has fetched it once can rebuild the runtime
/// without the network, which matters because the runtime is what search and MCP run on.
@MainActor
@Observable
final class IndexerRuntimeInstaller {
    enum State: Equatable {
        /// The unpacked runtime is here and is the one this build expects.
        case ready
        /// Nothing is unpacked yet, and an archive may or may not be here.
        case missing
        case downloading
        case failed(String)

        var isReady: Bool { self == .ready }
        var isDownloading: Bool { self == .downloading }

        /// What went wrong, when something did.
        var failure: String? {
            if case .failed(let message) = self { return message }
            return nil
        }
    }

    private(set) var state: State = .missing
    /// 0 to 1 while the archive is arriving, or nil when its size is not known yet.
    private(set) var progress: Double?
    /// How large the archive is once it is here.
    private(set) var archiveBytes: Int64?

    private let layout: IndexerRuntimeLayout
    private let unpacker: URL?
    private let remoteURL: URL?
    private let expectedHash: String?
    private var work: Task<Void, Never>?

    init(applicationDirectory: URL, unpacker: URL?, remoteURL: URL?, expectedHash: String?) {
        layout = IndexerRuntimeLayout(applicationDirectory: applicationDirectory)
        self.unpacker = unpacker
        self.remoteURL = remoteURL
        self.expectedHash = expectedHash
        refresh()
    }

    /// The runtime the app can start, or nil when it is not here yet.
    var runtimeExecutable: URL? {
        layout.isReady(expectedHash: expectedHash) ? layout.executable : nil
    }

    /// Reads the state from disk. Two file checks, so it can run whenever the pane is drawn.
    func refresh() {
        guard !state.isDownloading else { return }
        state = layout.isReady(expectedHash: expectedHash) ? .ready : .missing
        archiveBytes = Self.fileSize(layout.archive)
    }

    /// Gets the runtime here: unpacks the archive if it is here, and fetches it first if not.
    func install() {
        guard work == nil, !state.isDownloading else { return }
        guard !layout.isReady(expectedHash: expectedHash) else {
            state = .ready
            return
        }
        if !layout.hasArchive, remoteURL == nil {
            state = .failed(IndexerRuntimeError.nowhereToFetch.localizedDescription)
            return
        }
        state = .downloading
        progress = layout.hasArchive ? nil : 0
        work = Task { [weak self] in
            do {
                try await self?.fetchIfNeeded()
                try await self?.unpackArchive()
                self?.progress = nil
                self?.state = .ready
            } catch is CancellationError {
                self?.progress = nil
                self?.state = .missing
            } catch {
                self?.progress = nil
                self?.state = .failed(error.localizedDescription)
            }
            if let self {
                archiveBytes = Self.fileSize(layout.archive)
                work = nil
            }
        }
    }

    func cancel() {
        work?.cancel()
    }

    // MARK: - Work

    /// Downloads the archive unless it is already here, and refuses one that fails its hash.
    private func fetchIfNeeded() async throws {
        guard let remoteURL, let expectedHash else { throw IndexerRuntimeError.nowhereToFetch }
        let destination = layout.archive
        // An archive an earlier version left here is still an archive, and only its hash decides
        // whether it is this version's. Handing a stale one to the shim made the shim refuse the
        // file and leave the runtime missing until someone retried by hand, which is exactly what
        // happened after an update that shipped a different runtime.
        if layout.hasArchive, await Self.archive(destination, matches: expectedHash) {
            return
        }
        try? FileManager.default.removeItem(at: destination)
        var request = URLRequest(url: remoteURL)
        request.setValue("CallRecorder", forHTTPHeaderField: "User-Agent")
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let download = ModelFileDownload(destination: destination) { [weak self] received, expected in
            Task { @MainActor [weak self] in
                self?.progress = ModelManager.fraction(received: received, expected: expected)
            }
        }
        _ = try await download.run(request)
        // The hash is the acceptance test, exactly as it is for a model: a download that does not
        // match is deleted rather than unpacked, so a substituted archive cannot become the code
        // this app runs.
        let actual = await ModelManager.sha256(of: destination)
        guard actual == expectedHash else {
            try? FileManager.default.removeItem(at: destination)
            throw IndexerRuntimeError.hashMismatch
        }
    }

    /// Whether the archive already on disk is the one this build expects.
    ///
    /// The archive is kept between runs, so its presence says nothing about which version it is;
    /// the hash is what says. Hashing 36 MB takes a fraction of a second and is only done when a
    /// copy is already there.
    nonisolated static func archive(_ archive: URL, matches expectedHash: String?) async -> Bool {
        guard let expectedHash else { return false }
        return await ModelManager.sha256(of: archive) == expectedHash
    }

    /// Hands the archive to the shim, which owns the unpacking and the lock that guards it.
    private func unpackArchive() async throws {
        guard let unpacker else { throw IndexerRuntimeError.noUnpacker }
        do {
            try await Task.detached {
                _ = try ProcessRunner.runChecked(
                    executable: unpacker,
                    arguments: ["--ensure-runtime"],
                    cancellation: nil
                )
            }.value
        } catch {
            throw IndexerRuntimeError.unpackFailed(error.localizedDescription)
        }
    }

    private static func fileSize(_ url: URL) -> Int64? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value
    }
}
