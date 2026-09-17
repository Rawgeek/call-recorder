import CallRecorderCore
import Foundation
import Testing
@testable import CallRecorderApp

@Suite("Meeting processor")
struct MeetingProcessorTests {
    @Test("a work request during an active drain schedules one more drain")
    func preservesWakeupDuringIdleTransition() {
        // Given
        var demand = ProcessorDemand()
        let startsInitialDrain = demand.request()
        #expect(startsInitialDrain)

        // When
        let startsConcurrentDrain = demand.request()

        // Then
        #expect(!startsConcurrentDrain)
        let startsRequestedRerun = demand.finish()
        let stopsAfterRerun = demand.finish()
        #expect(startsRequestedRerun)
        #expect(!stopsAfterRerun)
    }

    @Test("indexer uses explicit local database, call, and model-cache arguments")
    func indexerArgumentsAreBounded() {
        let callID = CallID(rawValue: UUID())
        let client = IndexerClient(
            executable: URL(filePath: "/usr/bin/env"),
            argumentPrefix: ["bun", "/app/index-call.ts"],
            database: URL(filePath: "/tmp/calls.db"),
            cache: URL(filePath: "/tmp/models")
        )

        #expect(
            client.arguments(for: callID) == [
                "bun", "/app/index-call.ts", "index",
                "--database", "/tmp/calls.db",
                "--call-id", callID.rawValue.uuidString,
                "--cache", "/tmp/models",
            ]
        )
    }

    @Test("startup returns an interrupted stage to pending")
    func resumesInterruptedRunningJobAtSameStage() async throws {
        // Given
        let fixture = try await processorFixture()
        _ = try #require(try await fixture.store.claimNextProcessingJob(executableOnly: true))
        let processor = MeetingProcessor(store: fixture.store) { _ in
            throw CancellationError()
        }

        // When
        await processor.start()
        await processor.waitUntilIdle()

        // Then
        let job = try #require(try await fixture.store.processingJobs().first)
        #expect(job.stage == .queued)
        #expect(job.executionState == .pending)
    }

    @Test("a failed background stage retains audio and records a redacted diagnostic")
    func failedStageRetainsAudioAndRecordsDiagnostic() async throws {
        // Given
        let fixture = try await processorFixture()
        let processor = MeetingProcessor(store: fixture.store) { _ in
            throw FixtureProcessingError(message: "transcript=private words token=secret")
        }

        // When
        await processor.processNext()
        await processor.waitUntilIdle()

        // Then
        #expect(FileManager.default.fileExists(atPath: fixture.audio.path))
        let job = try #require(try await fixture.store.processingJobs().first)
        #expect(job.executionState == .failed)
        let event = try #require(try await fixture.store.processingEvents(for: fixture.callID).last)
        #expect(event.details?.contains("private words") == false)
        #expect(event.details?.contains("token=secret") == false)
    }

    @Test("one trigger drains every durable stage to ready")
    func oneTriggerDrainsQueuedWork() async throws {
        // Given
        let fixture = try await processorFixture()
        let processor = MeetingProcessor(store: fixture.store) { job in
            switch job.stage {
            case .queued: .transcribing
            case .transcribing: .diarizing
            case .diarizing: .attributing
            case .attributing: .indexing
            case .indexing: .finalizingArtifacts
            case .finalizingArtifacts: .ready
            case .awaitingParticipants, .ready:
                throw FixtureProcessingError(message: "unexpected stage")
            }
        }

        // When
        await processor.processNext()
        await processor.waitUntilIdle()

        // Then
        let job = try #require(try await fixture.store.processingJobs().first)
        #expect(job.stage == .ready)
        #expect(job.executionState == .complete)
        #expect(try await fixture.store.call(id: fixture.callID)?.status == .ready)
    }

    @Test("an indexing stage succeeding in the runner advances without a redundant status read")
    func indexingRunnerSuccessAdvancesDirectly() async throws {
        // Given
        let fixture = try await processorFixture()
        var stage = ProcessingStage.queued
        for nextStage in [
            ProcessingStage.transcribing,
            .diarizing,
            .attributing,
            .indexing,
        ] {
            _ = try #require(try await fixture.store.claimNextProcessingJob(executableOnly: true))
            _ = try await fixture.store.advanceProcessingJob(
                callID: fixture.callID,
                from: stage,
                to: nextStage
            )
            stage = nextStage
        }

        // When: the stage runner succeeds for indexing even though the immediate
        // calls.status read still returns the stale 'indexing' value.
        let processor = MeetingProcessor(store: fixture.store) { job in
            switch job.stage {
            case .indexing: .finalizingArtifacts
            case .finalizingArtifacts: throw CancellationError()
            default: throw FixtureProcessingError(message: "unexpected stage")
            }
        }
        await processor.processNext()
        await processor.waitUntilIdle()

        // Then
        // The drain reclaims the finalizingArtifacts job after the intended
        // advance; CancellationError returns it to pending without failing it.
        let job = try #require(try await fixture.store.processingJobs().first)
        #expect(job.stage == .finalizingArtifacts)
        #expect(job.executionState == .pending)
        #expect(try await fixture.store.call(id: fixture.callID)?.status == .indexing)
        #expect(try await fixture.store.indexIsReady(for: fixture.callID) == false)
    }

    @Test("a stopped stage waits for the user, and the surface is told")
    func aStoppedStageWaitsForTheUser() async throws {
        // Given a call whose transcription is the stage that is running
        let fixture = try await processorFixture()
        _ = try #require(try await fixture.store.claimNextProcessingJob(executableOnly: true))
        _ = try await fixture.store.advanceProcessingJob(
            callID: fixture.callID,
            from: .queued,
            to: .transcribing
        )
        let stopped = CancelledStageRecorder()

        // When the stage ends because the work was stopped
        let processor = MeetingProcessor(
            store: fixture.store,
            runStage: { job in
                if job.stage == .transcribing { throw CancellationError() }
                throw FixtureProcessingError(message: "unexpected stage")
            },
            onStageCancelled: { callID in await stopped.record(callID) }
        )
        await processor.processNext()
        await processor.waitUntilIdle()

        // Then the claim is back in the queue, the call says it is waiting, and the surface that
        // holds the retry knows which call it belongs to.
        let job = try #require(try await fixture.store.processingJobs().first)
        #expect(job.stage == .transcribing)
        #expect(job.executionState == .pending)
        #expect(try await fixture.store.call(id: fixture.callID)?.status == .metadata)
        #expect(await stopped.callIDs == [fixture.callID])
    }

    private func processorFixture() async throws -> (
        store: CallStore,
        callID: CallID,
        audio: URL
    ) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "meeting-processor-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let audio = root.appending(path: "call.m4a")
        try Data("audio".utf8).write(to: audio)
        let store = try CallStore(path: root.appending(path: "calls.db").path)
        try await store.migrate()
        let callID = CallID(rawValue: UUID())
        try await store.createCall(.started(id: callID, at: Date(timeIntervalSince1970: 1_800_000_000)))
        try await store.updateCall(
            id: callID,
            endedAt: Date(timeIntervalSince1970: 1_800_000_060),
            audioPath: audio.path,
            status: .metadata
        )
        try await store.setParticipants([], for: callID)
        return (store, callID, audio)
    }
}

private actor CancelledStageRecorder {
    private(set) var callIDs: [CallID] = []

    func record(_ callID: CallID) {
        callIDs.append(callID)
    }
}

private struct FixtureProcessingError: Error {
    let message: String
}
