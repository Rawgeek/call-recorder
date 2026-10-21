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
    private struct CaptureContext {
        let filter: SCContentFilter
        let configuration: SCStreamConfiguration
        let directory: URL
    }

    private let logger = Logger(subsystem: "local.callrecorder.app", category: "screenshots")
    private var task: Task<Void, Never>?
    private(set) var lastFailure: String?

    func start(
        callDirectory: URL,
        interval: ScreenshotInterval,
        resolution: ScreenshotResolution,
        offsetMs: Int
    ) {
        stop()
        lastFailure = nil
        let directory = ScreenshotArchive.directory(in: callDirectory)
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
        let wallStart = Date()
        task = Task { [weak self] in
            guard let self else { return }
            var context: CaptureContext?
            var nextDate = wallStart
            while !Task.isCancelled {
                let now = Date()
                let currentOffset = max(0, offsetMs + Int(now.timeIntervalSince(wallStart) * 1_000))
                do {
                    if context == nil {
                        context = try await Self.prepare(
                            callDirectory: callDirectory,
                            resolution: resolution
                        )
                    }
                    guard let context else { return }
                    let image = try await Self.captureImage(context)
                    // Stop can arrive while the system is still answering. The folder may be on
                    // its way to Recently Deleted by then, so no new file is created for a call
                    // that is no longer being captured.
                    if Task.isCancelled { return }
                    let fileURL = ScreenshotArchive.fileURL(
                        in: context.directory,
                        offsetMs: currentOffset,
                        sequence: UInt64(Date().timeIntervalSince1970 * 1_000_000)
                    )
                    // A 1080p encode takes long enough to be seen as a hitch if it runs on the
                    // window's actor, so the picture is written beside it.
                    try await Task.detached(priority: .utility) {
                        try Self.writeJPEG(image, to: fileURL)
                    }.value
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
                nextDate = nextDate.addingTimeInterval(interval.seconds)
                let delay = nextDate.timeIntervalSinceNow
                if delay > 0 {
                    try? await Task.sleep(for: .seconds(delay))
                } else {
                    // A capture that took longer than the step skips the moments it missed rather
                    // than firing a burst to catch up.
                    nextDate = Date().addingTimeInterval(interval.seconds)
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// Stops the timer and waits for a frame already being written.
    ///
    /// The stop of a call moves the folder its audio and photographs live in, and a frame that is
    /// still being encoded would land in a folder that has just gone. This is the same bounded
    /// wait the audio stop uses: the last photograph is worth waiting for, and the call cannot wait
    /// for ever.
    func stopAndWait() async {
        let running = task
        task?.cancel()
        task = nil
        guard let running else { return }
        // A picture already being encoded is worth a moment, and the stop of a call belongs to the
        // person who pressed it. Three seconds covers a JPEG write; a screenshot request stuck in
        // the system is left behind, because the audio stop must not wait on the picture path.
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await running.value }
            group.addTask { try? await Task.sleep(for: .seconds(3)) }
            await group.next()
            group.cancelAll()
        }
    }

    private static func prepare(
        callDirectory: URL,
        resolution: ScreenshotResolution
    ) async throws -> CaptureContext {
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
        return CaptureContext(
            filter: filter,
            configuration: configuration,
            directory: ScreenshotArchive.directory(in: callDirectory)
        )
    }

    private static func captureImage(_ context: CaptureContext) async throws -> CGImage {
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

    nonisolated private static func writeJPEG(_ image: CGImage, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent().appending(
            path: ".\(destination.lastPathComponent).\(UUID().uuidString).partial"
        )
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard
            let writer = CGImageDestinationCreateWithURL(
                temporary as CFURL,
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
        try FileManager.default.moveItem(at: temporary, to: destination)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: destination.path
        )
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
