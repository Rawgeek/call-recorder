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

/// What a download has received, and how large the server said the file is.
struct DownloadByteCount: Equatable, Sendable {
    var received: Int64
    var expected: Int64
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

    /// How many bytes of each download have arrived.
    ///
    /// A model is up to three gigabytes, and the row that shows it used to hold an indeterminate
    /// spinner for the minutes that takes. The count is kept per model so a first download and an
    /// update can be told apart while both are running.
    private(set) var downloadBytes: [String: DownloadByteCount] = [:]

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

    /// How far along a download is, from 0 to 1, or nil when the size is not yet known.
    func progress(for model: WhisperModel) -> Double? {
        guard let counted = downloadBytes[model.id] else { return nil }
        return Self.fraction(received: counted.received, expected: counted.expected)
    }

    /// Draws a model as if it were arriving, so a render can show the ring that fills.
    ///
    /// Nothing is fetched and nothing on disk is touched: the state and the byte count are the two
    /// things the row reads, and both are set here. A picture of a download is otherwise
    /// impossible to take, because it needs a model of two gigabytes and a slow line.
    func enterPreviewDownloading(_ modelID: String, fraction: Double) {
        guard let model = models.first(where: { $0.id == modelID }) else { return }
        states[model.id] = .downloading
        downloadBytes[model.id] = DownloadByteCount(
            received: Int64(Double(model.expectedBytes) * min(max(fraction, 0), 1)),
            expected: model.expectedBytes
        )
    }

    /// Puts back the state the render borrowed, and never touches a real download.
    func leavePreviewDownloading() {
        for model in models where downloads[model.id] == nil {
            guard states[model.id] == .downloading else { continue }
            states[model.id] = stateOnDisk(for: model)
            downloadBytes[model.id] = nil
        }
    }

    /// The share of a file that has arrived, or nil when the server did not name its size.
    ///
    /// A host that sends no length leaves nothing to divide by, and an empty ring would claim
    /// that nothing had arrived rather than that the size is unknown, so the answer is nil and
    /// the ring spins instead.
    nonisolated static func fraction(received: Int64, expected: Int64) -> Double? {
        guard expected > 0 else { return nil }
        return min(1, max(0, Double(received) / Double(expected)))
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
        downloadBytes[model.id] = DownloadByteCount(received: 0, expected: model.expectedBytes)
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
            self.downloadBytes[model.id] = nil
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
        downloadBytes[model.id] = DownloadByteCount(received: 0, expected: remote.bytes)
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
            self.downloadBytes[model.id] = nil
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

        // The bytes are counted as they land, so the row can draw how much is left. The file is
        // written straight to the partial name: the downloader is handed the path, because the
        // location a download delegate is given is deleted the moment its callback returns.
        var request = URLRequest(url: source)
        request.timeoutInterval = 60
        request.setValue("CallRecorder", forHTTPHeaderField: "User-Agent")
        let download = ModelFileDownload(destination: partial) { [weak self] received, expected in
            Task { @MainActor [weak self] in
                self?.downloadBytes[model.id] = DownloadByteCount(
                    received: received,
                    expected: expected
                )
            }
        }
        let response = try await download.run(request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ModelManagerError.invalidResponse
        }
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
            states[model.id] = stateOnDisk(for: model)
        }
    }

    /// What the file for one model says, with no regard for a transfer in flight.
    private func stateOnDisk(for model: WhisperModel) -> ModelInstallState {
        let url = fileURL(for: model)
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let bytes = (attributes?[.size] as? NSNumber)?.int64Value
        // A recorded model is trusted by its record. One with no record still counts as installed
        // when the size matches the catalog, which is what earlier builds wrote.
        let recorded = manifest.record(for: model.id)
        let matchesCatalog = bytes == model.expectedBytes
        return (recorded != nil || matchesCatalog) ? .installed : .notInstalled
    }
}

/// One file, downloaded with its byte count reported while it arrives.
///
/// `URLSession.download(from:)` is a black box: it says nothing until the whole file has landed.
/// The largest Whisper model is three gigabytes, so the row that showed it held an indeterminate
/// spinner for minutes, and a person could not tell a slow download from a stopped one. This owns
/// its session and its delegate, counts every chunk, and moves the finished file to the path the
/// caller named, because the location a download delegate is handed is deleted as soon as the
/// callback returns.
///
/// Cancelling the surrounding task cancels the transfer, and the caller sees a
/// `CancellationError` rather than the URL loading error underneath it.
final class ModelFileDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    typealias ProgressHandler = @Sendable (_ received: Int64, _ expected: Int64) -> Void

    /// How much has to arrive before a count is worth reporting.
    ///
    /// A transfer reports in whatever size the network hands it, and each report crosses to the
    /// main thread. Two hundred of them describe a ring that fills; a caller that asked for one
    /// report per chunk would get thousands. A host that never named a size gets one report every
    /// four megabytes instead, which is still a ring that moves.
    struct ReportStep: Equatable, Sendable {
        let size: Int64

        init(expected: Int64) {
            size = expected > 0 ? max(1, expected / 200) : 4 * 1_048_576
        }

        /// Whether this count is worth reporting, given the last one that was.
        ///
        /// The first bytes always count: a ring that waited for its first two-hundredth would show
        /// an empty circle for the seconds before a large file starts to move.
        func isDue(totalBytesWritten: Int64, reported: Int64) -> Bool {
            reported == 0 || totalBytesWritten - reported >= size
        }
    }

    private let destination: URL
    private let configuration: URLSessionConfiguration
    private let onProgress: ProgressHandler
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var continuation: CheckedContinuation<URLResponse, any Error>?
    private var reportedBytes: Int64 = 0
    private var reportStep: ReportStep?
    private var isCancelled = false
    private var isSettled = false

    init(
        destination: URL,
        configuration: URLSessionConfiguration = .ephemeral,
        onProgress: @escaping ProgressHandler
    ) {
        self.destination = destination
        self.configuration = configuration
        self.onProgress = onProgress
    }

    /// Downloads the request and leaves the file at the destination.
    ///
    /// - Returns: the server's response, so the caller can refuse a status that is not a success.
    func run(_ request: URLRequest) async throws -> URLResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                self.continuation = continuation
                configuration.timeoutIntervalForRequest = 60
                // A three-gigabyte file over a slow line is minutes of legitimate work, and the
                // resource timeout must not end it early.
                configuration.timeoutIntervalForResource = 60 * 60
                let session = URLSession(
                    configuration: configuration,
                    delegate: self,
                    delegateQueue: nil
                )
                self.session = session
                let task = session.downloadTask(with: request)
                self.task = task
                let alreadyCancelled = isCancelled
                lock.unlock()
                if alreadyCancelled {
                    task.cancel()
                } else {
                    task.resume()
                }
            }
        } onCancel: {
            cancel()
        }
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let task = task
        lock.unlock()
        task?.cancel()
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        lock.lock()
        let expected = max(totalBytesExpectedToWrite, 0)
        let step = reportStep ?? ReportStep(expected: expected)
        reportStep = step
        let due = step.isDue(totalBytesWritten: totalBytesWritten, reported: reportedBytes)
        if due { reportedBytes = totalBytesWritten }
        lock.unlock()
        guard due else { return }
        onProgress(totalBytesWritten, expected)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            let manager = FileManager.default
            _ = try? manager.removeItem(at: destination)
            try manager.moveItem(at: location, to: destination)
        } catch {
            settle(.failure(error))
            return
        }
        settle(.success(downloadTask.response ?? URLResponse()))
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        guard let error else { return }
        let cocoa = error as NSError
        if isCancelled || (cocoa.domain == NSURLErrorDomain && cocoa.code == NSURLErrorCancelled) {
            settle(.failure(CancellationError()))
            return
        }
        settle(.failure(error))
    }

    private func settle(_ result: Result<URLResponse, any Error>) {
        lock.lock()
        guard !isSettled else {
            lock.unlock()
            return
        }
        isSettled = true
        let continuation = self.continuation
        self.continuation = nil
        let session = self.session
        self.session = nil
        lock.unlock()
        // A session holds its delegate until it is invalidated, and a model of three gigabytes
        // must not keep this object alive behind the manager that finished with it.
        session?.invalidateAndCancel()
        switch result {
        case .success(let response): continuation?.resume(returning: response)
        case .failure(let error): continuation?.resume(throwing: error)
        }
    }
}
