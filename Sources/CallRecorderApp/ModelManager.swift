import CallRecorderCore
import CryptoKit
import Foundation
import Observation
import OSLog

enum ModelInstallState: Equatable {
    case notInstalled
    case downloading
    case installed
    case failed(String)

    var isInstalled: Bool { self == .installed }
    var isDownloading: Bool { self == .downloading }
}

enum ModelManagerError: LocalizedError {
    case invalidResponse
    case verificationFailed
    case busy

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "The model server returned an invalid response."
        case .verificationFailed: "The downloaded model failed integrity verification."
        case .busy: "Call Recorder is recording or transcribing, so the model was left alone."
        }
    }
}

/// Fetches what a model host publishes for a repository.
struct ModelHostClient: Sendable {
    var session: URLSession = .shared
    var timeout: TimeInterval = 30

    func metadata(repository: String) async throws -> ModelHostMetadata {
        var request = URLRequest(url: ModelHostMetadata.url(repository: repository))
        request.timeoutInterval = timeout
        request.setValue("CallRecorder", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ModelManagerError.invalidResponse
        }
        return try ModelHostMetadata.parse(data)
    }
}

/// Owns the Whisper model files: what is installed, what is newer, and how to change it safely.
///
/// Every change lands the same way: download to a temporary name, verify the bytes against a
/// published hash, move the current file aside, then swap the new one in. A failure at any point
/// leaves the previous model in place, and the copy that was moved aside stays until the next
/// successful update so the user can go back.
@MainActor
@Observable
final class ModelManager {
    let models = WhisperModel.catalog
    private(set) var states: [String: ModelInstallState] = [:]
    /// The result of the last check, per model.
    private(set) var decisions: [String: ModelUpdateDecision] = [:]
    private(set) var lastCheckedAt: Date?
    private(set) var checking = false
    /// Plain-language summary of the last automatic pass, for the settings window.
    private(set) var statusMessage: String?
    private(set) var failingModels: [String: String] = [:]

    /// Set by the app. An update must never move a model file while it is being read.
    var isBusy: () -> Bool = { false }

    private let directory: URL
    private let manifestURL: URL
    private let host: ModelHostClient
    private var manifest: ModelManifest
    private var downloads: [String: Task<Void, Never>] = [:]
    private let logger = Logger(subsystem: "local.callrecorder.app", category: "models")

    init(directory: URL, manifestURL: URL, host: ModelHostClient = ModelHostClient()) {
        self.directory = directory
        self.manifestURL = manifestURL
        self.host = host
        self.manifest = ModelManifest.load(from: manifestURL)
        refresh()
    }

    // MARK: - Reading state

    func state(for model: WhisperModel) -> ModelInstallState {
        states[model.id] ?? .notInstalled
    }

    func fileURL(for model: WhisperModel) -> URL {
        directory.appending(path: model.fileName)
    }

    func decision(for model: WhisperModel) -> ModelUpdateDecision? {
        decisions[model.id]
    }

    /// The copy kept from before the last update, if there is one.
    func previousURL(for model: WhisperModel) -> URL {
        directory.appending(path: model.fileName + ".previous")
    }

    func canRevert(_ model: WhisperModel) -> Bool {
        FileManager.default.fileExists(atPath: previousURL(for: model).path)
    }

    /// The disk space the installed model files occupy, counting copies kept for a revert.
    ///
    /// A revert copy is the same size as the model it replaced, so leaving it out would
    /// understate usage by gigabytes on the largest model.
    var installedBytes: Int64 {
        models.reduce(0) { total, model in
            guard state(for: model).isInstalled else { return total }
            return total
                + Self.fileSize(fileURL(for: model))
                + Self.fileSize(previousURL(for: model))
        }
    }

    private static func fileSize(_ url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    // MARK: - Installing and updating

    func download(_ model: WhisperModel) {
        guard downloads[model.id] == nil, !state(for: model).isInstalled else { return }
        states[model.id] = .downloading
        failingModels[model.id] = nil
        downloads[model.id] = Task { [weak self] in
            guard let self else { return }
            do {
                // A first download uses the hash decided when the app was built, so the file a
                // new install starts from does not depend on what the host says today.
                try await self.install(
                    model,
                    from: model.downloadURL,
                    expecting: RemoteModelFile(
                        fileName: model.fileName,
                        bytes: model.expectedBytes,
                        sha256: model.sha256
                    ),
                    revision: WhisperModel.pinnedRevision
                )
                self.states[model.id] = .installed
            } catch is CancellationError {
                self.states[model.id] = .notInstalled
            } catch {
                self.states[model.id] = .failed(error.localizedDescription)
                self.failingModels[model.id] = error.localizedDescription
            }
            self.downloads[model.id] = nil
        }
    }

    func cancel(_ model: WhisperModel) {
        downloads[model.id]?.cancel()
    }

    func delete(_ model: WhisperModel) throws {
        downloads[model.id]?.cancel()
        // The copy kept from the last update goes too, otherwise deleting a model would leave
        // its previous version taking up the same disk space.
        try ModelFileSwapper.remove(
            destination: fileURL(for: model),
            previous: previousURL(for: model)
        )
        manifest.remove(model.id)
        try? manifest.write(to: manifestURL)
        decisions[model.id] = nil
        states[model.id] = .notInstalled
    }
    
    /// Applies a verified update, keeping the current file so the change can be undone.
    func applyUpdate(_ model: WhisperModel) {
        guard downloads[model.id] == nil else { return }
        guard case .updateAvailable(let remote) = decisions[model.id] else { return }
        guard !isBusy() else {
            failingModels[model.id] = ModelManagerError.busy.localizedDescription
            return
        }
        states[model.id] = .downloading
        failingModels[model.id] = nil
        downloads[model.id] = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.install(
                    model,
                    from: URL(
                        string: "https://huggingface.co/\(model.repository)/resolve/main/\(model.fileName)"
                    )!,
                    expecting: remote,
                    revision: "main"
                )
                self.states[model.id] = .installed
                self.decisions[model.id] = .upToDate
                self.statusMessage = "Updated \(model.displayName)."
            } catch is CancellationError {
                self.states[model.id] = self.states[model.id] == .downloading ? .installed : .notInstalled
            } catch {
                self.states[model.id] = .failed(error.localizedDescription)
                self.failingModels[model.id] = error.localizedDescription
                self.statusMessage = "Could not update \(model.displayName)."
            }
            self.downloads[model.id] = nil
        }
    }

    /// Puts the copy from before the last update back.
    func revert(_ model: WhisperModel) throws {
        let previous = previousURL(for: model)
        try ModelFileSwapper.revert(destination: fileURL(for: model), previous: previous)
        // The restored file is whatever was installed before, so its record is unknown again
        // until it is hashed; the next check reports that rather than guessing.
        manifest.remove(model.id)
        try? manifest.write(to: manifestURL)
        states[model.id] = .installed
        decisions[model.id] = nil
        statusMessage = "Restored the earlier copy of \(model.displayName)."
        Task { await self.rehash(model) }
    }

    // MARK: - Checking for updates

    /// Records hashes for models that were installed before Call Recorder tracked them.
    ///
    /// Without this the first check would report every existing model as unverifiable. Hashing
    /// a large file takes seconds, so it runs once, off the main thread, and lands in the
    /// manifest for every later check to reuse.
    func bootstrapManifest() async {
        for model in models where state(for: model).isInstalled && manifest.record(for: model.id) == nil {
            await rehash(model)
        }
    }

    func checkForUpdates() async {
        guard !checking else { return }
        checking = true
        defer {
            checking = false
            lastCheckedAt = Date()
        }
        var repositories: [String] = []
        for model in models where !repositories.contains(model.repository) {
            repositories.append(model.repository)
        }
        for repository in repositories {
            do {
                let metadata = try await host.metadata(repository: repository)
                for model in models where model.repository == repository {
                    guard state(for: model).isInstalled else {
                        decisions[model.id] = nil
                        continue
                    }
                    decisions[model.id] = ModelUpdateChecker.decision(
                        installed: manifest.record(for: model.id),
                        remote: metadata.files[model.fileName]
                    )
                }
            } catch {
                // A failed check leaves the previous verdict alone. Reporting every model as
                // unverifiable because the network blipped would be worse than saying nothing.
                statusMessage = "Could not reach the model host: \(error.localizedDescription)"
            }
        }
    }

    /// Checks, then applies everything that is safe to apply at once.
    func performAutomaticPass() async {
        logger.notice("model update pass starting, busy=\(self.isBusy(), privacy: .public)")
        guard !isBusy() else {
            statusMessage = "Update check skipped while a call is being recorded or transcribed."
            logger.notice("model update pass skipped: a call is in progress")
            return
        }
        await bootstrapManifest()
        await checkForUpdates()
        let pending = models.filter { decisions[$0.id]?.isUpdateAvailable == true }
        logger.notice("model update pass checked \(self.decisions.count, privacy: .public) models, \(pending.count, privacy: .public) to update")
        guard !pending.isEmpty else {
            if statusMessage?.hasPrefix("Could not reach") != true {
                statusMessage = "All installed models are current."
            }
            return
        }
        for model in pending where !isBusy() {
            applyUpdate(model)
            // Wait for each update so two large downloads never compete for bandwidth.
            while downloads[model.id] != nil {
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    // MARK: - File work

    /// Downloads, verifies, and swaps one model file.
    ///
    /// The published hash is the acceptance test. A file that does not match is deleted, never
    /// installed, so a truncated or substituted download cannot become the model in use.
    private func install(
        _ model: WhisperModel,
        from source: URL,
        expecting remote: RemoteModelFile,
        revision: String
    ) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let partial = directory.appending(path: model.fileName + ".partial")
        _ = try? FileManager.default.removeItem(at: partial)

        let (temporary, response) = try await URLSession.shared.download(from: source)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ModelManagerError.invalidResponse
        }
        _ = try? FileManager.default.removeItem(at: partial)
        try FileManager.default.moveItem(at: temporary, to: partial)
        do {
            let verified = try await Task.detached {
                try ModelFileVerifier.verify(
                    fileAt: partial,
                    expectedBytes: remote.bytes,
                    sha256: remote.sha256
                )
            }.value
            guard verified else { throw ModelManagerError.verificationFailed }
            try Task.checkCancellation()
            try swapIn(partial, for: model, verifiedHash: remote.sha256, revision: revision)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
    }

    /// Moves a verified file into place, keeping the one it replaces.
    private func swapIn(
        _ verified: URL,
        for model: WhisperModel,
        verifiedHash: String,
        revision: String
    ) throws {
        let destination = fileURL(for: model)
        try ModelFileSwapper.swapIn(
            verified: verified,
            destination: destination,
            previous: previousURL(for: model)
        )
        var updated = manifest
        updated.record(
            InstalledModelRecord(
                modelID: model.id,
                fileName: model.fileName,
                sha256: verifiedHash.lowercased(),
                bytes: (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0,
                revision: revision,
                installedAt: Date()
            )
        )
        try? updated.write(to: manifestURL)
        manifest = updated
    }

    /// Hashes an installed file once and records it, so later checks can compare strings.
    private func rehash(_ model: WhisperModel) async {
        let url = fileURL(for: model)
        guard let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) else {
            return
        }
        logger.notice("hashing \(model.id, privacy: .public) to record what is installed")
        guard let digest = await Self.sha256(of: url) else { return }
        logger.notice("recorded \(model.id, privacy: .public) \(digest, privacy: .public)")
        var updated = manifest
        updated.record(
            InstalledModelRecord(
                modelID: model.id,
                fileName: model.fileName,
                sha256: digest,
                bytes: bytes,
                revision: "installed",
                installedAt: Date()
            )
        )
        try? updated.write(to: manifestURL)
        manifest = updated
    }

    nonisolated static func sha256(of url: URL) async -> String? {
        await Task.detached { () -> String? in
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            var hasher = SHA256()
            while let data = try? handle.read(upToCount: 1_048_576), !data.isEmpty {
                hasher.update(data: data)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }

    /// Reads the file sizes on disk and marks what is installed.
    private func refresh() {
        for model in models {
            let url = fileURL(for: model)
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let bytes = (attributes?[.size] as? NSNumber)?.int64Value
            // A recorded model is trusted by its record. One with no record still counts as
            // installed when the size matches the catalog, which is what earlier builds wrote.
            let recorded = manifest.record(for: model.id)
            let matchesCatalog = bytes == model.expectedBytes
            states[model.id] = (recorded != nil || matchesCatalog) ? .installed : .notInstalled
        }
    }
}
