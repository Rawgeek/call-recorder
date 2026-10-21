import AppKit
import CallRecorderCore
import CoreGraphics
import Foundation
import ImageIO
import OSLog
import ScreenCaptureKit
import Observation
import UniformTypeIdentifiers

/// One photograph of the screen, placed on the call's own clock.
struct CallScreenshot: Identifiable, Equatable, Sendable {
    let url: URL
    let offsetMs: Int
    let sequence: Int

    var id: String { url.path }
}

/// One rule shared by both places that change the screenshot preference.
enum ScreenshotPreferenceControl {
    static func isDisabled(enabled: Bool, permissionGranted: Bool) -> Bool {
        !enabled && !permissionGranted
    }
}

/// Whether the screen-photograph timer may run right now.
///
/// A pause or a stop closes the audio and then waits for the screen operation it cancelled. The
/// recorder's phase can still read `.recording` during that wait, so a settings change or a
/// permission refresh arriving then must not start a timer the stop has already given up on.
enum ScreenshotCaptureEligibility {
    static func shouldStart(
        enabled: Bool,
        recording: Bool,
        permissionGranted: Bool,
        hasDirectory: Bool,
        transitioning: Bool
    ) -> Bool {
        enabled && recording && permissionGranted && hasDirectory && !transitioning
    }
}

/// Where a call keeps its screen photographs and how their names carry their place on the clock.
///
/// The names are the index. A photograph is useful the moment it is written, even if the app is
/// killed before it can close the recording, and the timeline can be rebuilt by reading the folder.
enum ScreenshotArchive {
    static let directoryName = "Screenshots"

    static func directory(in callDirectory: URL) -> URL {
        callDirectory.appending(path: directoryName, directoryHint: .isDirectory)
    }

    static func fileURL(in directory: URL, offsetMs: Int, sequence: UInt64) -> URL {
        directory.appending(
            path: String(
                format: "shot-%010d-%016llu-%03d.jpg",
                max(0, offsetMs),
                sequence,
                Int.random(in: 0..<1_000)
            )
        )
    }

    static func read(in callDirectory: URL) -> [CallScreenshot] {
        let directory = directory(in: callDirectory)
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls
            .filter { $0.pathExtension.lowercased() == "jpg" }
            .compactMap { url -> CallScreenshot? in
                guard let (offsetMs, sequence) = parse(url) else { return nil }
                return CallScreenshot(
                    url: url,
                    offsetMs: offsetMs,
                    sequence: sequence
                )
            }
            .sorted {
                ($0.offsetMs, $0.sequence) < ($1.offsetMs, $1.sequence)
            }
    }

    private static func parse(_ url: URL) -> (offsetMs: Int, sequence: Int)? {
        let parts = url.deletingPathExtension().lastPathComponent.split(separator: "-")
        guard parts.count == 4, parts[0] == "shot",
            let offsetMs = Int(parts[1]),
            let sequence = Int(parts[2])
        else { return nil }
        return (offsetMs, sequence)
    }
}

/// Which photograph belongs to a moment on the recording's clock.
enum ScreenshotSelection {
    /// The stored picture closest to the moment. Nil only when the call has no pictures.
    static func nearest(to milliseconds: Int, among screenshots: [CallScreenshot]) -> CallScreenshot? {
        screenshots.min {
            abs($0.offsetMs - milliseconds) < abs($1.offsetMs - milliseconds)
        }
    }
}

/// Takes one screen photograph at a time, on a timer, while a call is being recorded.
///
/// This is deliberately separate from the audio stream. The audio stream is a tiny 2×2 capture
/// whose screen output is ignored, and changing it to full-resolution video would put picture work
/// behind a microphone that must keep arriving in real time. A screenshot request is independent:
/// if it is slow or refused, the call's audio is unaffected.
@MainActor
@Observable
final class ScreenshotCaptureSession {
    typealias Capture = @Sendable () async throws -> CGImage
    typealias PrepareCapture = @Sendable (URL, ScreenshotResolution) async throws -> Capture
    typealias WriteCapture = @Sendable (CGImage, URL) async throws -> Void
    /// How the stop deadline is measured. Production sleeps for the timeout; a test can fire it.
    typealias DeadlineWait = @Sendable (Duration) async -> Void

    private struct CaptureContext: @unchecked Sendable {
        let capture: Capture
        let directory: URL
    }

    private struct SCContext: @unchecked Sendable {
        let filter: SCContentFilter
        let configuration: SCStreamConfiguration
    }

    private let logger = Logger(subsystem: "local.callrecorder.app", category: "screenshots")
    private let prepareCapture: PrepareCapture
    private let writeCapture: WriteCapture
    private let stopTimeout: Duration
    private let deadlineWait: DeadlineWait
    private struct StartRequest {
        let callDirectory: URL
        let interval: ScreenshotInterval
        let resolution: ScreenshotResolution
        let offsetMs: Int
        /// When the request was made. This is the call-clock anchor: a request that waits for a
        /// stuck operation to return keeps the time it spent waiting on the recording's clock.
        let startedAt: Date
    }
    private struct Run {
        let generation: UInt64
        let task: Task<Void, Never>
        let stagingDirectory: URL
    }
    private var run: Run?
    /// A restart asked for while the previous screen operation has not returned yet.
    private var deferredStart: StartRequest?
    private var deferredFailureTask: Task<Void, Never>?
    /// The one screen operation still outstanding. It bounds restarts after a stop deadline.
    private var outstanding: (generation: UInt64, task: Task<Void, Never>)?
    private var generation: UInt64 = 0
    private(set) var lastFailure: String?

    private static let notResponding =
        "Screen capture is still not responding. Screenshots will resume when it does."

    init(
        prepareCapture: PrepareCapture? = nil,
        writeCapture: WriteCapture? = nil,
        stopTimeout: Duration = .seconds(3),
        deadlineWait: DeadlineWait? = nil
    ) {
        self.prepareCapture = prepareCapture ?? Self.livePrepareCapture
        self.writeCapture = writeCapture ?? Self.liveWriteCapture
        self.stopTimeout = stopTimeout
        self.deadlineWait = deadlineWait ?? Self.liveDeadlineWait
    }

    /// Production measures a stop deadline by sleeping for it.
    private static func liveDeadlineWait(_ timeout: Duration) async {
        try? await Task.sleep(for: timeout)
    }

    func start(
        callDirectory: URL,
        interval: ScreenshotInterval,
        resolution: ScreenshotResolution,
        offsetMs: Int
    ) {
        let request = StartRequest(
            callDirectory: callDirectory,
            interval: interval,
            resolution: resolution,
            offsetMs: offsetMs,
            startedAt: Date()
        )
        if let outstanding {
            // One screen operation at a time. A request that arrives while the previous one is
            // still inside the system is remembered and the operation is asked to cancel. If it
            // never comes back, nothing opens a second capture stream and holds another session.
            // The generation it was given is retired, so a frame it was still writing can never
            // reach the archive of the call the new request belongs to.
            generation &+= 1
            outstanding.task.cancel()
            run?.task.cancel()
            run = nil
            deferredStart = request
            scheduleDeferredFailure()
            return
        }
        begin(request)
    }

    private func begin(_ request: StartRequest) {
        lastFailure = nil
        let directory = ScreenshotArchive.directory(in: request.callDirectory)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            lastFailure = "The screenshots folder could not be created."
            logger.error("screenshots folder could not be created: \(error.localizedDescription, privacy: .public)")
            return
        }
        let stagingDirectory = directory.appending(
            path: ".staging-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        do {
            try FileManager.default.createDirectory(
                at: stagingDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            lastFailure = "The screenshots workspace could not be created."
            logger.error("screenshot workspace could not be created: \(error.localizedDescription, privacy: .public)")
            return
        }
        generation &+= 1
        let expectedGeneration = generation
        // The cadence is anchored when the run actually starts, which is later than the request
        // after a deferral. The picture time is anchored on the request instead, below.
        let cadenceStart = Date()
        let task = Task { [weak self] in
            guard let self else { return }
            defer { self.operationFinished(generation: expectedGeneration) }
            defer { try? FileManager.default.removeItem(at: stagingDirectory) }
            var context: CaptureContext?
            var nextDate = cadenceStart
            while !Task.isCancelled {
                do {
                    if context == nil {
                        context = try await Self.prepare(
                            callDirectory: request.callDirectory,
                            resolution: request.resolution,
                            using: prepareCapture
                        )
                    }
                    guard let context else { return }
                    if Task.isCancelled { return }
                    // Read the clock after the prepare and immediately before the shutter, so a
                    // slow first look is not labelled with the moment before it began, and a
                    // deferred request keeps the time it waited for the old operation.
                    let frameOffset = max(
                        0,
                        request.offsetMs + Int(Date().timeIntervalSince(request.startedAt) * 1_000)
                    )
                    let image = try await context.capture()
                    // Stop can arrive while the system is still answering. The folder may be on
                    // its way to Recently Deleted by then, so no new file is created for a call
                    // that is no longer being captured.
                    if Task.isCancelled { return }
                    let fileURL = ScreenshotArchive.fileURL(
                        in: context.directory,
                        offsetMs: frameOffset,
                        sequence: UInt64(Date().timeIntervalSince1970 * 1_000_000)
                    )
                    let stagedURL = stagingDirectory.appending(path: fileURL.lastPathComponent)
                    // A 1080p encode takes long enough to be seen as a hitch if it runs on the
                    // window's actor, so the picture is written beside it.
                    try await Task.detached(priority: .utility) {
                        try await self.writeCapture(image, stagedURL)
                    }.value
                    // Cancellation arriving during the write gets the stop grace period to finish.
                    // A stop that timed out or a replacement run changes the generation and can
                    // never publish this file. The archive sees only the final move below.
                    guard self.generation == expectedGeneration else { return }
                    try FileManager.default.moveItem(at: stagedURL, to: fileURL)
                    try? FileManager.default.setAttributes(
                        [.posixPermissions: 0o600],
                        ofItemAtPath: fileURL.path
                    )
                    self.lastFailure = nil
                } catch {
                    if Task.isCancelled { return }
                    self.lastFailure = error.localizedDescription
                    self.logger.error(
                        "screen photograph failed: \(error.localizedDescription, privacy: .public)"
                    )
                    // A display that went away can be looked up again on the next step. Other
                    // failures keep the timer alive: one refused photograph must not end capture.
                    context = nil
                }
                nextDate = nextDate.addingTimeInterval(request.interval.seconds)
                let delay = nextDate.timeIntervalSinceNow
                if delay > 0 {
                    try? await Task.sleep(for: .seconds(delay))
                } else {
                    // A capture that took longer than the step skips the moments it missed rather
                    // than firing a burst to catch up.
                    nextDate = Date().addingTimeInterval(request.interval.seconds)
                }
            }
        }
        run = Run(
            generation: expectedGeneration,
            task: task,
            stagingDirectory: stagingDirectory
        )
        outstanding = (expectedGeneration, task)
    }

    /// Reports the deferred restart only after it has waited longer than a stop may take.
    private func scheduleDeferredFailure() {
        deferredFailureTask?.cancel()
        let timeout = stopTimeout
        deferredFailureTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self, self.deferredStart != nil else { return }
            self.lastFailure = Self.notResponding
            self.logger.error("screen capture is still not responding; a restart is waiting")
        }
    }

    /// Starts the one remembered request after the outstanding operation finally returns.
    private func operationFinished(generation finished: UInt64) {
        guard outstanding?.generation == finished else { return }
        outstanding = nil
        deferredFailureTask?.cancel()
        deferredFailureTask = nil
        guard let request = deferredStart else { return }
        deferredStart = nil
        begin(request)
    }

    func stop() {
        generation &+= 1
        deferredStart = nil
        deferredFailureTask?.cancel()
        deferredFailureTask = nil
        run?.task.cancel()
        if let run { try? FileManager.default.removeItem(at: run.stagingDirectory) }
        run = nil
    }

    func cancel() {
        run?.task.cancel()
    }

    func waitForStop() async {
        // The caller is settling into a stopped state, so a remembered restart must not begin.
        deferredStart = nil
        deferredFailureTask?.cancel()
        deferredFailureTask = nil
        guard let running = run else { return }
        let finished = await Self.wait(
            for: running.task,
            timeout: stopTimeout,
            deadlineWait: deadlineWait
        )
        guard run?.generation == running.generation else { return }
        generation &+= 1
        run = nil
        if !finished {
            try? FileManager.default.removeItem(at: running.stagingDirectory)
        }
    }

    /// Stops the timer and waits for a frame already being written.
    ///
    /// The stop of a call moves the folder its audio and photographs live in, and a frame that is
    /// still being encoded would land in a folder that has just gone. This is the same bounded
    /// wait the audio stop uses: the last photograph is worth waiting for, and the call cannot wait
    /// for ever.
    func stopAndWait() async {
        cancel()
        await waitForStop()
    }

    /// Waits for a task without making the task group own its completion.
    ///
    /// A task group waits for every child when its scope ends, including the child awaiting a task
    /// that ignores cancellation. This race lets the caller return at the deadline while the old
    /// generation is already unable to publish.
    private static func wait(
        for task: Task<Void, Never>,
        timeout: Duration,
        deadlineWait: @escaping DeadlineWait
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            let waiter = CompletionWait(continuation)
            Task {
                await task.value
                waiter.finish(true)
            }
            Task {
                await deadlineWait(timeout)
                waiter.finish(false)
            }
        }
    }

    private static func prepare(
        callDirectory: URL,
        resolution: ScreenshotResolution,
        using prepareCapture: PrepareCapture
    ) async throws -> CaptureContext {
        let capture = try await prepareCapture(callDirectory, resolution)
        return CaptureContext(capture: capture, directory: ScreenshotArchive.directory(in: callDirectory))
    }

    private static func livePrepareCapture(
        callDirectory: URL,
        resolution: ScreenshotResolution
    ) async throws -> Capture {
        // The process-scoped list is the one the audio stream already uses: it is available
        // without a second consent prompt, and it still names the display and this app's windows.
        // Window titles are redacted here, which is exactly what a picture needs.
        let content = try await SCShareableContent.currentProcess
        guard
            let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
                ?? content.displays.first
        else { throw ScreenshotCaptureError.noDisplay }
        let ownApplication = content.applications.filter {
            $0.processID == ProcessInfo.processInfo.processIdentifier
        }
        let filter = SCContentFilter(
            display: display,
            excludingApplications: ownApplication,
            exceptingWindows: []
        )
        let size = resolution.pixelSize(for: display)
        let configuration = SCStreamConfiguration()
        configuration.width = size.width
        configuration.height = size.height
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        configuration.showsCursor = false
        let context = SCContext(filter: filter, configuration: configuration)
        return { try await captureImage(context) }
    }

    private static func captureImage(_ context: SCContext) async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            let reply = ScreenshotReply(continuation)
            SCScreenshotManager.captureImage(
                contentFilter: context.filter,
                configuration: context.configuration
            ) { image, error in
                if let error {
                    reply.finish(.failure(error))
                } else if let image {
                    reply.finish(.success(image))
                } else {
                    reply.finish(.failure(ScreenshotCaptureError.emptyImage))
                }
            }
            // A screenshot request that never answers must not become a task that lives for the
            // rest of the call. The next timer step can try again.
            Task {
                try? await Task.sleep(for: .seconds(10))
                reply.finish(.failure(ScreenshotCaptureError.timedOut))
            }
        }
    }

    private static func liveWriteCapture(_ image: CGImage, to destination: URL) async throws {
        try writeJPEG(image, to: destination)
    }

    nonisolated private static func writeJPEG(_ image: CGImage, to destination: URL) throws {
        guard
            let writer = CGImageDestinationCreateWithURL(
                destination as CFURL,
                UTType.jpeg.identifier as CFString,
                1,
                nil
            )
        else { throw ScreenshotCaptureError.couldNotWrite }
        let options = [kCGImageDestinationLossyCompressionQuality: 0.86] as CFDictionary
        CGImageDestinationAddImage(writer, image, options)
        guard CGImageDestinationFinalize(writer) else {
            throw ScreenshotCaptureError.couldNotWrite
        }
    }
}

private enum ScreenshotCaptureError: LocalizedError {
    case noDisplay
    case emptyImage
    case couldNotWrite
    case timedOut

    var errorDescription: String? {
        switch self {
        case .noDisplay: "No display was found for the screenshot."
        case .emptyImage: "The screen capture produced no image."
        case .couldNotWrite: "The screenshot could not be written to disk."
        case .timedOut: "The screen capture did not answer in time."
        }
    }
}

/// Carries one screenshot answer from the system's callback or the timer, whichever comes first.
private final class ScreenshotReply: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<CGImage, any Error>?

    init(_ continuation: CheckedContinuation<CGImage, any Error>) {
        self.continuation = continuation
    }

    func finish(_ result: Result<CGImage, any Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

/// Carries the one answer from either a finished task or its deadline.
private final class CompletionWait: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func finish(_ completed: Bool) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: completed)
    }
}

extension ScreenshotResolution {
    /// The size at which a display is captured, in its own pixels.
    func pixelSize(for display: SCDisplay) -> (width: Int, height: Int) {
        let nativeWidth = CGDisplayPixelsWide(display.displayID)
        let nativeHeight = CGDisplayPixelsHigh(display.displayID)
        // A display that answers nothing is described in points alone. Using its point size is
        // better than asking for a one-pixel picture, and the filter still fits the real screen.
        let width = max(1, nativeWidth > 0 ? nativeWidth : display.width)
        let height = max(1, nativeHeight > 0 ? nativeHeight : display.height)
        return targetSize(nativeWidth: width, nativeHeight: height)
    }

    /// The saved size for a display, as a pure function of its physical pixels.
    func targetSize(nativeWidth: Int, nativeHeight: Int) -> (width: Int, height: Int) {
        let width = max(1, nativeWidth)
        let height = max(1, nativeHeight)
        guard self != .native else { return (width, height) }
        // The setting is a ceiling, not a promise to enlarge a smaller display: upscaling adds no
        // detail and only makes the JPEG bigger. The display's own aspect ratio is kept, so a
        // 16:10 MacBook is saved at 1920×1200-ish rather than letterboxed into 1920×1080.
        // Full HD is read as a 1920-pixel ceiling, with 1200 pixels of height so a 16:10 MacBook
        // screen keeps its whole frame. A 16:9 display, which is what most external monitors are,
        // lands on exactly 1920×1080.
        let maximum = self == .hd ? (width: 1280.0, height: 800.0) : (width: 1920.0, height: 1200.0)
        let scale = min(1, min(maximum.width / Double(width), maximum.height / Double(height)))
        return (
            max(1, Int((Double(width) * scale).rounded())),
            max(1, Int((Double(height) * scale).rounded()))
        )
    }
}
