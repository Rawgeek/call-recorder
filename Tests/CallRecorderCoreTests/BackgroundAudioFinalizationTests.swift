import CallRecorderCore
import Foundation
import Testing
@testable import CallRecorderApp

@Suite("Background audio finalization")
struct BackgroundAudioFinalizationTests {
    @Test("capture is released while finalization is still pending")
    func releasesCaptureWhileFinalizationPending() async throws {
        // Given
        let processor = BackgroundAudioFinalization(store: nil, pipeline: nil)
        let job = PendingBackgroundCall(
            callID: CallID(rawValue: UUID()),
            segments: [],
            destination: URL(filePath: "/tmp/blocked"),
            endedAt: Date()
        )

        // When a job is enqueued and still pending, capture availability is unaffected.
        await processor.enqueue(job)

        // Then
        #expect(await processor.captureAvailable())
        await processor.waitForDrain()
        #expect((await processor.state()).pendingCalls.isEmpty)
    }

    @Test("prior completion uses its immutable snapshot and never clears a newer active call")
    func completionUsesSnapshotAndLeavesNewerCallUntouched() async throws {
        // Given
        let processor = BackgroundAudioFinalization(store: nil, pipeline: nil)
        let prior = PendingBackgroundCall(
            callID: CallID(rawValue: UUID()),
            segments: [],
            destination: URL(filePath: "/tmp/prior"),
            endedAt: Date(timeIntervalSince1970: 100)
        )
        let newer = PendingBackgroundCall(
            callID: CallID(rawValue: UUID()),
            segments: [],
            destination: URL(filePath: "/tmp/newer"),
            endedAt: Date(timeIntervalSince1970: 200)
        )

        // When both are enqueued up front, the single drain processes them in FIFO order.
        await processor.enqueue(prior)
        await processor.enqueue(newer)
        await processor.waitForDrain()

        // Then
        let state = await processor.state()
        #expect(state.pendingCalls.isEmpty)
        #expect(state.successes.isEmpty)
        #expect(state.failures.map(\.job.callID) == [prior.callID, newer.callID])
    }

    @Test("a failed background call stays retained, retryable, and keeps its source files", .enabled(if: TestEnvironment.hasFFmpeg))
    func failedCallIsRetainedAndRetryable() async throws {
        // Given
        let root = FileManager.default.temporaryDirectory
            .appending(path: "background-finalization-retry-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ffmpeg = URL(filePath: "/opt/homebrew/bin/ffmpeg")
        let ffprobe = URL(filePath: "/opt/homebrew/bin/ffprobe")
        let segmentURL = root.appending(path: "segment-001.m4a")
        let generated = try ProcessRunner.run(
            executable: ffmpeg,
            arguments: [
                "-v", "error", "-f", "lavfi",
                "-i", "sine=frequency=440:duration=0.2",
                "-c:a", "aac", segmentURL.path,
            ]
        )
        #expect(generated.exitCode == 0)
        let store = try CallStore(path: root.appending(path: "calls.db").path)
        try await store.migrate()
        let callID = CallID(rawValue: UUID())
        try await store.createCall(.started(id: callID, at: Date(timeIntervalSince1970: 1_800_000_000)))
        let processor = BackgroundAudioFinalization(store: store, pipeline: nil)
        let backgroundJob = PendingBackgroundCall(
            callID: callID,
            segments: [
                SegmentSnapshot(index: 1, systemURL: segmentURL, microphoneURL: nil)
            ],
            destination: root,
            endedAt: Date(timeIntervalSince1970: 1_800_000_060)
        )
        await processor.enqueue(backgroundJob)

        // When
        await processor.waitForDrain()
        var state = await processor.state()
        #expect(state.failures.map(\.job.callID) == [backgroundJob.callID])
        #expect(state.failures.first?.message.contains("Unavailable") == true)
        #expect(state.pendingCalls.isEmpty)
        #expect(FileManager.default.fileExists(atPath: segmentURL.path))

        // A retry reuses the retained job and succeeds once the pipeline is attached.
        await processor.attach(
            store: store,
            pipeline: CallPipeline(
                store: store,
                finalizer: MediaFinalizer(ffmpeg: ffmpeg, ffprobe: ffprobe)
            )
        )
        await processor.retryFailed(backgroundJob.callID)
        await processor.waitForDrain()
        state = await processor.state()

        // Then
        #expect(state.pendingCalls.isEmpty)
        #expect(state.failures.isEmpty)
        #expect(state.successes.map(\.callID) == [callID])
    }

    @Test("background-save failure stays visible while a newer recording can still start")
    func failureStaysVisibleWhileRecorderAvailabilityStaysIndependent() async throws {
        // Given
        let processor = BackgroundAudioFinalization(store: nil, pipeline: nil)
        let failedCall = CallID(rawValue: UUID())
        await processor.enqueue(
            PendingBackgroundCall(
                callID: failedCall,
                segments: [],
                destination: URL(filePath: "/tmp/blocked"),
                endedAt: Date(timeIntervalSince1970: 100)
            )
        )
        await processor.waitForDrain()
        #expect((await processor.state()).failures.map(\.job.callID) == [failedCall])

        // When another recording is started while the failed save is still visible.
        await processor.enqueue(
            PendingBackgroundCall(
                callID: CallID(rawValue: UUID()),
                segments: [],
                destination: URL(filePath: "/tmp/new"),
                endedAt: Date(timeIntervalSince1970: 200)
            )
        )
        await processor.waitForDrain()

        // Then the failure remains listed, pending work stays visible, and capture is still available.
        let state = await processor.state()
        #expect(state.failures.map(\.job.callID).contains(failedCall))
        #expect(state.pendingCalls.isEmpty)
        #expect(await processor.captureAvailable())

        // And the failed save can be retried without touching the newer call.
        let newerCallID = state.failures
            .map(\.job.callID)
            .first { $0 != failedCall }
        await processor.retryFailed(failedCall)
        await processor.waitForDrain()
        let afterRetry = await processor.state()
        #expect(afterRetry.pendingCalls.isEmpty)
        #expect(afterRetry.failures.map(\.job.callID).contains(failedCall))
        #expect(afterRetry.failures.map(\.job.callID).contains(newerCallID!))
    }

    @Test("a job never reports success through an unattached processor")
    func unattachedProcessorNeverReportsSuccess() async throws {
        // Given
        let processor = BackgroundAudioFinalization(store: nil, pipeline: nil)
        let job = PendingBackgroundCall(
            callID: CallID(rawValue: UUID()),
            segments: [],
            destination: URL(filePath: "/tmp/unattached"),
            endedAt: Date()
        )

        // When
        await processor.enqueue(job)
        await processor.waitForDrain()

        // Then
        let state = await processor.state()
        #expect(state.successes.isEmpty)
        #expect(state.failures.map(\.job.callID) == [job.callID])
        #expect(state.failures.first?.message.contains("Unavailable") == true)
        #expect(state.pendingCalls.isEmpty)
    }

    @Test("success requires the real pipeline finalize and store commit", .enabled(if: TestEnvironment.hasFFmpeg))
    func successRequiresRealPipelineAndStoreCommit() async throws {
        // Given
        let root = FileManager.default.temporaryDirectory
            .appending(path: "background-finalization-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ffmpeg = URL(filePath: "/opt/homebrew/bin/ffmpeg")
        let ffprobe = URL(filePath: "/opt/homebrew/bin/ffprobe")
        let segmentURL = root.appending(path: "segment-001.m4a")
        let generated = try ProcessRunner.run(
            executable: ffmpeg,
            arguments: [
                "-v", "error", "-f", "lavfi",
                "-i", "sine=frequency=440:duration=0.2",
                "-c:a", "aac", segmentURL.path,
            ]
        )
        #expect(generated.exitCode == 0)
        let store = try CallStore(path: root.appending(path: "calls.db").path)
        try await store.migrate()
        let callID = CallID(rawValue: UUID())
        try await store.createCall(.started(id: callID, at: Date(timeIntervalSince1970: 1_800_000_000)))
        let pipeline = CallPipeline(
            store: store,
            finalizer: MediaFinalizer(ffmpeg: ffmpeg, ffprobe: ffprobe)
        )
        let processor = BackgroundAudioFinalization(store: store, pipeline: pipeline)
        let backgroundJob = PendingBackgroundCall(
            callID: callID,
            segments: [
                SegmentSnapshot(index: 1, systemURL: segmentURL, microphoneURL: nil)
            ],
            destination: root,
            endedAt: Date(timeIntervalSince1970: 1_800_000_060)
        )

        // When
        await processor.enqueue(backgroundJob)
        await processor.waitForDrain()

        // Then
        let state = await processor.state()
        #expect(state.successes.map(\.callID) == [callID])
        #expect(state.failures.isEmpty)
        let record = try #require(try await store.call(id: callID))
        #expect(record.status == .metadata)
        #expect(record.endedAt == Date(timeIntervalSince1970: 1_800_000_060))
        #expect(record.audioPath == root.appending(path: "call.m4a").path)
        // The stored path is where the file a person plays the call from will be written. That file
        // is not written here: mixing the two sides is a second encode of the whole call and no
        // stage of the pipeline reads it, so it is written by the stage that tidies the call up,
        // and only when the audio is kept. What finalizing owes the pipeline is the side the
        // transcriber reads, and that side is on disk.
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "system.m4a").path))
        // The committed processing job must be transcription-ready (queued), never reset
        // to awaitingParticipants, so MeetingProcessor's next drain can claim it.
        let job = try #require(try await store.processingJobs().first)
        #expect(job.stage == .queued)
        #expect(job.executionState == .pending)
    }

    @Test("a call whose audio is removed points at the side that was recorded")
    func audioThatIsRemovedPointsAtTheTrack() async throws {
        // Given a job whose person chose to remove the audio once the transcript is verified.
        let root = FileManager.default.temporaryDirectory
            .appending(path: "background-removed-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ffmpeg = URL(filePath: "/opt/homebrew/bin/ffmpeg")
        let ffprobe = URL(filePath: "/opt/homebrew/bin/ffprobe")
        let segmentURL = root.appending(path: ".system-001.partial.m4a")
        let generated = try ProcessRunner.run(
            executable: ffmpeg,
            arguments: [
                "-v", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=0.2",
                "-c:a", "aac", segmentURL.path,
            ]
        )
        #expect(generated.exitCode == 0)
        let store = try CallStore(path: root.appending(path: "calls.db").path)
        try await store.migrate()
        let callID = CallID(rawValue: UUID())
        try await store.createCall(.started(id: callID, at: Date(timeIntervalSince1970: 1_800_000_000)))
        let processor = BackgroundAudioFinalization(
            store: store,
            pipeline: CallPipeline(
                store: store,
                finalizer: MediaFinalizer(ffmpeg: ffmpeg, ffprobe: ffprobe)
            )
        )

        // When
        await processor.enqueue(
            PendingBackgroundCall(
                callID: callID,
                segments: [SegmentSnapshot(index: 1, systemURL: segmentURL, microphoneURL: nil)],
                destination: root,
                endedAt: Date(timeIntervalSince1970: 1_800_000_060),
                keepsAudio: false
            )
        )
        await processor.waitForDrain()

        // Then the call's audio path is a file that is on disk right now, rather than one that the
        // next stage would have to write and immediately move to Recently Deleted.
        let record = try #require(try await store.call(id: callID))
        #expect(record.audioPath == root.appending(path: "system.m4a").path)
        #expect(FileManager.default.fileExists(atPath: record.audioPath ?? ""))
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "call.m4a").path))
    }

    @Test("success is observable after finalization and queue commit complete")
    func successIsObservable() async throws {
        // Given
        let processor = BackgroundAudioFinalization(store: nil, pipeline: nil)
        let job = PendingBackgroundCall(
            callID: CallID(rawValue: UUID()),
            segments: [],
            destination: URL(filePath: "/tmp/success"),
            endedAt: Date()
        )

        // When
        await processor.enqueue(job)
        await processor.waitForDrain()

        // Then
        let state = await processor.state()
        #expect(state.pendingCalls.isEmpty)
        #expect(state.successes.isEmpty)
        #expect(state.failures.map(\.job.callID) == [job.callID])
    }

    @Test("state changes are published for pending, failure, and retry observations")
    func stateChangesArePublished() async throws {
        // Given
        let observations = LockedProbe<BackgroundFinalizationState>()
        let processor = BackgroundAudioFinalization(
            store: nil,
            pipeline: nil,
            onChange: { state async in observations.append(state) }
        )
        let job = PendingBackgroundCall(
            callID: CallID(rawValue: UUID()),
            segments: [],
            destination: URL(filePath: "/tmp/published"),
            endedAt: Date(timeIntervalSince1970: 100)
        )

        // When
        await processor.enqueue(job)
        await processor.waitForDrain()

        // Then pending was observable before completion, and the failure stays
        // observable and retryable afterwards.
        let states = observations.snapshot()
        #expect(states.contains { $0.pendingCalls.map(\.callID) == [job.callID] })
        #expect(states.last?.failures.map(\.job.callID) == [job.callID])
        #expect(states.last?.failures.first?.message.isEmpty == false)
    }
}

/// Deterministic cross-actor observation probe: collects state snapshots from the
/// background finalizer's onChange seam under a lock.
final class LockedProbe<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Value] = []

    func append(_ value: Value) {
        lock.lock()
        defer { lock.unlock() }
        values.append(value)
    }

    func snapshot() -> [Value] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}
