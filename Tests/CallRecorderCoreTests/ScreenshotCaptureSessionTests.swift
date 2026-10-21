import CoreGraphics
import Foundation
import Testing
@testable import CallRecorderApp

@Suite("Screenshot capture cancellation")
struct ScreenshotCaptureSessionTests {
    @Test("a pause or stop transaction keeps the timer from restarting")
    func transitionBlocksRestart() {
        // The phase still reads .recording while the audio segment is closing, so a settings
        // change or permission refresh in that window must not start a timer the stop cancelled.
        #expect(
            ScreenshotCaptureEligibility.shouldStart(
                enabled: true,
                recording: true,
                permissionGranted: true,
                hasDirectory: true,
                transitioning: false
            )
        )
        #expect(
            !ScreenshotCaptureEligibility.shouldStart(
                enabled: true,
                recording: true,
                permissionGranted: true,
                hasDirectory: true,
                transitioning: true
            )
        )
        #expect(
            !ScreenshotCaptureEligibility.shouldStart(
                enabled: false,
                recording: true,
                permissionGranted: true,
                hasDirectory: true,
                transitioning: false
            )
        )
        #expect(
            !ScreenshotCaptureEligibility.shouldStart(
                enabled: true,
                recording: true,
                permissionGranted: true,
                hasDirectory: false,
                transitioning: false
            )
        )
    }

    @Test("a hung capture stops at its deadline, not when the system answers")
    @MainActor
    func hungCaptureIsBounded() async throws {
        let fixture = try ShotFixture()
        defer { fixture.remove() }
        let captureStarted = Gate()
        let captureRelease = Gate()
        let captureFinished = Marker()
        let stopFinished = Marker()
        let deadline = ManualDeadline()
        let session = ScreenshotCaptureSession(
            prepareCapture: { _, _ in
                {
                    captureStarted.open()
                    await captureRelease.wait()
                    captureFinished.set()
                    throw ScreenshotTestError.hung
                }
            },
            writeCapture: { _, _ in throw ScreenshotTestError.unexpectedWrite },
            stopTimeout: .milliseconds(50),
            deadlineWait: { await deadline.sleep($0) }
        )

        session.start(
            callDirectory: fixture.callDirectory,
            interval: .twoSeconds,
            resolution: .hd,
            offsetMs: 0
        )
        await captureStarted.wait()
        session.cancel()
        let stopTask = Task {
            await session.waitForStop()
            stopFinished.set()
        }

        // The wait arms the requested deadline and races it with the held capture.
        #expect(await waitUntil { deadline.isArmed })
        #expect(deadline.requested == [.milliseconds(50)])
        // Neither branch has answered, so a correct stop is still waiting.
        #expect(!stopFinished.isSet)
        #expect(!captureFinished.isSet)

        deadline.fire.open()
        #expect(await waitUntil { stopFinished.isSet })
        // The deadline released the stop while the capture was still inside the system.
        #expect(!captureFinished.isSet)

        captureRelease.open()
        await stopTask.value
        #expect(ScreenshotArchive.read(in: fixture.callDirectory).isEmpty)
    }

    @Test("a hung write cannot hold stop past its deadline or publish later")
    @MainActor
    func hungWriteIsBoundedAndDiscarded() async throws {
        let fixture = try ShotFixture()
        defer { fixture.remove() }
        let writeStarted = Gate()
        let writeRelease = Gate()
        let writeFinished = Marker()
        let stopFinished = Marker()
        let deadline = ManualDeadline()
        let session = ScreenshotCaptureSession(
            prepareCapture: { _, _ in { try fixture.image() } },
            writeCapture: { _, destination in
                writeStarted.open()
                await writeRelease.wait()
                defer { writeFinished.set() }
                try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: destination)
            },
            stopTimeout: .milliseconds(50),
            deadlineWait: { await deadline.sleep($0) }
        )

        session.start(
            callDirectory: fixture.callDirectory,
            interval: .twoSeconds,
            resolution: .hd,
            offsetMs: 0
        )
        await writeStarted.wait()
        session.cancel()
        let stopTask = Task {
            await session.waitForStop()
            stopFinished.set()
        }

        #expect(await waitUntil { deadline.isArmed })
        #expect(deadline.requested == [.milliseconds(50)])
        #expect(!stopFinished.isSet)

        deadline.fire.open()
        #expect(await waitUntil { stopFinished.isSet })
        // The deadline released the stop while the write was still inside the system.
        #expect(!writeFinished.isSet)

        writeRelease.open()
        await stopTask.value
        #expect(await waitUntil { writeFinished.isSet })
        // A write that returns after the deadline must not reach the archive.
        try? await Task.sleep(for: .milliseconds(100))
        #expect(ScreenshotArchive.read(in: fixture.callDirectory).isEmpty)
    }

    @Test("a write already underway can finish during the stop grace period")
    @MainActor
    func inFlightWriteIsPreserved() async throws {
        let fixture = try ShotFixture()
        defer { fixture.remove() }
        let started = Gate()
        let release = Gate()
        let session = ScreenshotCaptureSession(
            prepareCapture: { _, _ in { try fixture.image() } },
            writeCapture: { _, destination in
                started.open()
                await release.wait()
                try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: destination)
            },
            stopTimeout: .seconds(1)
        )

        session.start(
            callDirectory: fixture.callDirectory,
            interval: .twoSeconds,
            resolution: .hd,
            offsetMs: 0
        )
        await started.wait()
        let releaseTask = Task {
            try? await Task.sleep(for: .milliseconds(100))
            release.open()
        }

        session.cancel()
        await session.waitForStop()
        await releaseTask.value

        #expect(ScreenshotArchive.read(in: fixture.callDirectory).count == 1)
    }

    @Test("restarting invalidates an older writer that finishes later")
    @MainActor
    func restartBlocksTheOlderGeneration() async throws {
        let fixture = try ShotFixture()
        defer { fixture.remove() }
        let writer = BlockingWriter()
        let session = ScreenshotCaptureSession(
            prepareCapture: { _, _ in { try fixture.image() } },
            writeCapture: { image, destination in
                try await writer.write(image, to: destination)
            },
            stopTimeout: .milliseconds(50)
        )

        session.start(
            callDirectory: fixture.callDirectory,
            interval: .twoSeconds,
            resolution: .hd,
            offsetMs: 0
        )
        await writer.firstStarted.wait()
        session.start(
            callDirectory: fixture.callDirectory,
            interval: .twoSeconds,
            resolution: .hd,
            offsetMs: 2_000
        )
        try? await Task.sleep(for: .milliseconds(100))
        #expect(ScreenshotArchive.read(in: fixture.callDirectory).isEmpty)
        #expect(session.lastFailure?.contains("still not responding") == true)
        writer.releaseFirst.open()
        let current = await waitForShots(in: fixture.callDirectory, atLeast: 1)
        try? await Task.sleep(for: .milliseconds(150))
        let afterOldWriter = ScreenshotArchive.read(in: fixture.callDirectory)
        session.cancel()
        await session.waitForStop()

        #expect(current.count == 1)
        #expect(afterOldWriter.count == 1)
        #expect(afterOldWriter.allSatisfy { $0.offsetMs >= 1_500 })
    }

    @Test("a held operation is single-flight across repeated restarts")
    @MainActor
    func heldOperationBoundsRepeatedRestarts() async throws {
        let fixture = try ShotFixture()
        defer { fixture.remove() }
        let held = HeldCapture()
        let session = ScreenshotCaptureSession(
            prepareCapture: { _, _ in
                held.prepare()
                return {
                    try await held.capture(image: fixture.image())
                }
            },
            writeCapture: { _, destination in
                try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: destination)
            },
            stopTimeout: .milliseconds(50)
        )

        session.start(
            callDirectory: fixture.callDirectory,
            interval: .twoSeconds,
            resolution: .hd,
            offsetMs: 0
        )
        await held.firstStarted.wait()
        session.cancel()
        await session.waitForStop()
        for offset in stride(from: 1_000, through: 5_000, by: 1_000) {
            session.start(
                callDirectory: fixture.callDirectory,
                interval: .twoSeconds,
                resolution: .hd,
                offsetMs: offset
            )
        }
        try? await Task.sleep(for: .milliseconds(100))

        #expect(ScreenshotArchive.read(in: fixture.callDirectory).isEmpty)
        #expect(session.lastFailure?.contains("still not responding") == true)
        #expect(held.captureCount == 1)
        #expect(held.maximumConcurrent == 1)

        held.releaseFirst.open()
        let shots = await waitForShots(in: fixture.callDirectory, atLeast: 1)
        session.cancel()
        await session.waitForStop()

        #expect(shots.count == 1)
        #expect(shots.first?.offsetMs ?? 0 >= 4_500)
        #expect(held.captureCount == 2)
        #expect(held.maximumConcurrent == 1)
    }

    @Test("a held prepare is single-flight across repeated restarts")
    @MainActor
    func heldPrepareBoundsRepeatedRestarts() async throws {
        let fixture = try ShotFixture()
        defer { fixture.remove() }
        let held = HeldPrepare(image: { try fixture.image() })
        let session = ScreenshotCaptureSession(
            prepareCapture: { _, _ in await held.prepare() },
            writeCapture: { _, destination in
                try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: destination)
            },
            stopTimeout: .milliseconds(50)
        )

        session.start(
            callDirectory: fixture.callDirectory,
            interval: .twoSeconds,
            resolution: .hd,
            offsetMs: 0
        )
        await held.firstStarted.wait()
        session.cancel()
        await session.waitForStop()
        for offset in stride(from: 1_000, through: 4_000, by: 1_000) {
            session.start(
                callDirectory: fixture.callDirectory,
                interval: .twoSeconds,
                resolution: .hd,
                offsetMs: offset
            )
        }
        try? await Task.sleep(for: .milliseconds(100))

        #expect(ScreenshotArchive.read(in: fixture.callDirectory).isEmpty)
        #expect(session.lastFailure?.contains("still not responding") == true)
        let preparesWhileHeld = await held.prepareCount
        #expect(preparesWhileHeld == 1)

        held.releaseFirst.open()
        let shots = await waitForShots(in: fixture.callDirectory, atLeast: 1)
        session.cancel()
        await session.waitForStop()

        #expect(shots.count == 1)
        #expect(shots.first?.offsetMs ?? 0 >= 3_500)
        let preparesAfterRelease = await held.prepareCount
        #expect(preparesAfterRelease == 2)
    }

    @Test("a deferred restart keeps the call clock and the time spent waiting")
    @MainActor
    func deferredRestartKeepsTheCallClock() async throws {
        let fixture = try ShotFixture()
        defer { fixture.remove() }
        let held = HeldPrepare(image: { try fixture.image() }, laterDelay: .milliseconds(250))
        let session = ScreenshotCaptureSession(
            prepareCapture: { _, _ in await held.prepare() },
            writeCapture: { _, destination in
                try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: destination)
            },
            stopTimeout: .milliseconds(50)
        )

        session.start(
            callDirectory: fixture.callDirectory,
            interval: .twoSeconds,
            resolution: .hd,
            offsetMs: 0
        )
        await held.firstStarted.wait()
        session.cancel()
        await session.waitForStop()

        let requestedAt = Date()
        session.start(
            callDirectory: fixture.callDirectory,
            interval: .twoSeconds,
            resolution: .hd,
            offsetMs: 4_000
        )
        try? await Task.sleep(for: .milliseconds(400))
        let releasedAt = Date()
        held.releaseFirst.open()
        let shots = await waitForShots(in: fixture.callDirectory, atLeast: 1)
        session.cancel()
        await session.waitForStop()

        let waitedMs = Int(releasedAt.timeIntervalSince(requestedAt) * 1_000)
        #expect(waitedMs >= 350)
        #expect(shots.count == 1)
        // The frame is taken after the wait and after its own prepare, and still carries the call
        // offset the request was made with. The old clock lost both stretches.
        #expect((shots.first?.offsetMs ?? 0) >= 4_000 + waitedMs + 250 - 50)
    }

    @MainActor
    private func waitForShots(
        in callDirectory: URL,
        atLeast count: Int,
        timeout: Duration = .seconds(2)
    ) async -> [CallScreenshot] {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let shots = ScreenshotArchive.read(in: callDirectory)
            if shots.count >= count { return shots }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return ScreenshotArchive.read(in: callDirectory)
    }

    /// A failure watchdog for a gate that a regression left closed, never the correctness test.
    @MainActor
    private func waitUntil(
        _ condition: @MainActor () -> Bool,
        timeout: Duration = .seconds(5)
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}

private struct ShotFixture {
    let root: URL
    let callDirectory: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "screenshot-session-\(UUID().uuidString)", directoryHint: .isDirectory)
        callDirectory = root.appending(path: "call", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: callDirectory, withIntermediateDirectories: true)
    }

    func image() throws -> CGImage {
        guard
            let context = CGContext(
                data: nil,
                width: 2,
                height: 2,
                bitsPerComponent: 8,
                bytesPerRow: 8,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ),
            let image = context.makeImage()
        else { throw ScreenshotTestError.noImage }
        return image
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private actor BlockingWriter {
    let firstStarted = Gate()
    let releaseFirst = Gate()
    private var calls = 0

    func write(_ image: CGImage, to destination: URL) async throws {
        calls += 1
        let call = calls
        if call == 1 {
            firstStarted.open()
            await releaseFirst.wait()
        }
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: destination)
    }
}

private final class HeldCapture: @unchecked Sendable {
    let firstStarted = Gate()
    let releaseFirst = Gate()
    private let lock = NSLock()
    private var prepares = 0
    private var captures = 0
    private var active = 0
    private var maximum = 0

    var captureCount: Int {
        lock.withLock { captures }
    }

    var maximumConcurrent: Int {
        lock.withLock { maximum }
    }

    func prepare() {
        lock.withLock { prepares += 1 }
    }

    func capture(image: CGImage) async throws -> CGImage {
        let isFirst = lock.withLock {
            captures += 1
            active += 1
            maximum = max(maximum, active)
            return captures == 1
        }
        defer { lock.withLock { active -= 1 } }
        if isFirst {
            firstStarted.open()
            await releaseFirst.wait()
        }
        return image
    }
}

private actor HeldPrepare {
    let firstStarted = Gate()
    let releaseFirst = Gate()
    private let image: @Sendable () throws -> CGImage
    private let laterDelay: Duration
    private var prepares = 0

    init(image: @escaping @Sendable () throws -> CGImage, laterDelay: Duration = .zero) {
        self.image = image
        self.laterDelay = laterDelay
    }

    var prepareCount: Int { prepares }

    func prepare() async -> @Sendable () async throws -> CGImage {
        prepares += 1
        if prepares == 1 {
            firstStarted.open()
            await releaseFirst.wait()
        } else if laterDelay > .zero {
            try? await Task.sleep(for: laterDelay)
        }
        let image = self.image
        return { try image() }
    }
}

private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        lock.lock()
        guard !isOpen else {
            lock.unlock()
            return
        }
        isOpen = true
        let waiters = self.waiters
        self.waiters = []
        lock.unlock()
        for waiter in waiters { waiter.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isOpen {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}

/// A stop deadline a test fires on purpose instead of waiting for the scheduler's clock.
private final class ManualDeadline: @unchecked Sendable {
    let armed = Gate()
    let fire = Gate()
    private let lock = NSLock()
    private var durations: [Duration] = []
    private var isArmedStorage = false

    var requested: [Duration] { lock.withLock { durations } }
    var isArmed: Bool { lock.withLock { isArmedStorage } }

    func sleep(_ duration: Duration) async {
        lock.withLock {
            durations.append(duration)
            isArmedStorage = true
        }
        armed.open()
        await fire.wait()
    }
}

private final class Marker: @unchecked Sendable {
    private let lock = NSLock()
    private var isSetStorage = false

    var isSet: Bool { lock.withLock { isSetStorage } }

    func set() {
        lock.withLock { isSetStorage = true }
    }
}

private enum ScreenshotTestError: Error {
    case hung
    case unexpectedWrite
    case noImage
}
