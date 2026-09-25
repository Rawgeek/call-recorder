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

enum ModelDownloadError: LocalizedError {
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

    /// How far along the transfer is, as a share, or nil while the size is not known yet.
    var fraction: Double? {
        guard expected > 0 else { return nil }
        return min(1, max(0, Double(received) / Double(expected)))
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
            throw ModelDownloadError.invalidResponse
        }
        return try ModelHostMetadata.parse(data)
    }
}

/// One file, downloaded with its byte count reported while it arrives.
///
/// `URLSession.download(from:)` is a black box: it says nothing until the whole file has landed.
/// The largest model this app fetches is two and a half gigabytes, so the row that showed it held
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
