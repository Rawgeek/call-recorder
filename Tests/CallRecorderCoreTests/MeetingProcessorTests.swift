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

    @Test("a call queued again while its stage ran stays queued instead of ending the drain")
    func aSupersededStageDoesNotEndTheDrain() async throws {
        // Given a call that has reached the indexing stage, and a pass that rewrites its transcript
        // while that stage runs. Saving a transcript queues the stage again, which takes away the
        // claim the drain was holding.
        let fixture = try await processorFixture()
        var stage = ProcessingStage.queued
        for nextStage in [ProcessingStage.transcribing, .diarizing, .attributing, .indexing] {
            _ = try #require(try await fixture.store.claimNextProcessingJob(executableOnly: true))
            _ = try await fixture.store.advanceProcessingJob(
                callID: fixture.callID,
                from: stage,
                to: nextStage
            )
            stage = nextStage
        }
        let attemptsBefore = try #require(try await fixture.store.processingJobs().first).attemptCount
        let requeued = RequeueOnceDuringStage(store: fixture.store, callID: fixture.callID)
        let processor = MeetingProcessor(store: fixture.store) { _ in
            guard try await requeued.requeueOnFirstRun() else { throw CancellationError() }
            return .finalizingArtifacts
        }

        // When
        await processor.processNext()
        await processor.waitUntilIdle()

        // Then the queue kept the call, and the drain reclaimed it: the second claim is what the
        // count shows, and it is the difference between a call that waits its turn and one that sat
        // at "Indexing" with every call behind it waiting until the next launch.
        let job = try #require(try await fixture.store.processingJobs().first)
        #expect(job.stage == .indexing)
        #expect(job.executionState == .pending)
        #expect(job.attemptCount == attemptsBefore + 2)
        #expect(try await fixture.store.call(id: fixture.callID)?.status == .indexing)
    }

    @Test("a stage that loses its claim while it fails is written down as superseded")
    func aStageThatLosesItsClaimWhileItFailsIsSuperseded() async throws {
        // Given a call at its last stage and a pass that names a voice while that stage runs. Saving
        // the rewritten transcript queues the call's indexing stage again and clears the claim the
        // drain holds, so the stage's own guard throws over a call that is already back in the
        // queue: on 2026-09-25 the 16:21 call threw ArtifactRecoveryError.callNotReady here.
        let fixture = try await processorFixture()
        var stage = ProcessingStage.queued
        for nextStage in [
            ProcessingStage.transcribing, .diarizing, .attributing, .indexing, .finalizingArtifacts,
        ] {
            _ = try #require(try await fixture.store.claimNextProcessingJob(executableOnly: true))
            _ = try await fixture.store.advanceProcessingJob(
                callID: fixture.callID,
                from: stage,
                to: nextStage
            )
            stage = nextStage
        }
        let requeued = RequeueOnceDuringStage(store: fixture.store, callID: fixture.callID)
        let processor = MeetingProcessor(store: fixture.store) { _ in
            guard try await requeued.requeueOnFirstRun() else { throw CancellationError() }
            throw ArtifactRecoveryError.callNotReady
        }

        // When
        await processor.processNext()
        await processor.waitUntilIdle()

        // Then the run is kept as what it was: work that another pass took the call away from.
        // Nothing is marked failed, and the record names the stage and where the call went.
        let events = try await fixture.store.processingEvents(for: fixture.callID)
        #expect(events.count == 1)
        let event = try #require(events.first)
        #expect(event.severity == .warning)
        #expect(event.stage == .finalizingArtifacts)
        #expect(event.errorType?.contains("ArtifactRecoveryError") == true)
        #expect(event.summary.contains("indexing"))
        let job = try #require(try await fixture.store.processingJobs().first)
        #expect(job.stage == .indexing)
        #expect(job.executionState == .pending)
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

    @Test("a stage stopped after its claim is already back in the queue still tells the surface")
    func aStopAfterTheClaimIsGoneKeepsTheLoop() async throws {
        // Given a call whose transcription is running, and a surface that put the claim back in the
        // queue before the stage noticed it had been stopped
        let fixture = try await processorFixture()
        let store = fixture.store
        _ = try #require(try await store.claimNextProcessingJob(executableOnly: true))
        _ = try await store.advanceProcessingJob(
            callID: fixture.callID,
            from: .queued,
            to: .transcribing
        )
        let stopped = CancelledStageRecorder()

        // When the stage ends as stopped
        let processor = MeetingProcessor(
            store: store,
            runStage: { job in
                guard job.stage == .transcribing else { throw FixtureProcessingError(message: "unexpected stage") }
                try await store.stopProcessingJob(callID: job.callID, stage: job.stage)
                throw CancellationError()
            },
            onStageCancelled: { callID in await stopped.record(callID) }
        )
        await processor.processNext()
        await processor.waitUntilIdle()

        // Then the surface that stopped it is told, and the loop went on instead of ending: the
        // second put-back found the claim already in the queue, and throwing that out of the loop
        // logged "Processor loop failed" over a call that was exactly where it belonged.
        #expect(await stopped.callIDs == [fixture.callID])
        let job = try #require(try await store.processingJobs().first)
        #expect(job.executionState == .pending)
    }

    @Test("a stage that fails after its claim is gone does not fail the processor loop")
    func aFailureAfterTheClaimIsGoneKeepsTheLoop() async throws {
        // Given a call whose transcription is running, and a pass that queued it again while the
        // stage ran, so the claim it holds is gone
        let fixture = try await processorFixture()
        let store = fixture.store
        _ = try #require(try await store.claimNextProcessingJob(executableOnly: true))
        _ = try await store.advanceProcessingJob(
            callID: fixture.callID,
            from: .queued,
            to: .transcribing
        )
        let changes = ChangeCounter()
        let runs = RunCounter()

        // When the first pass of the stage fails on its own account, and the pass the queue asks
        // for afterwards is the one that does the work
        let processor = MeetingProcessor(
            store: store,
            runStage: { job in
                guard job.stage == .transcribing else { throw FixtureProcessingError(message: "unexpected stage") }
                guard try await runs.next() > 1 else {
                    try await store.stopProcessingJob(callID: job.callID, stage: job.stage)
                    throw FixtureProcessingError(message: "boom")
                }
                return .diarizing
            },
            onChange: { await changes.record() }
        )
        await processor.processNext()
        await processor.waitUntilIdle()

        // Then the call moved on rather than the drain ending: the failure the store could not
        // record (its claim was gone) did not take the loop with it.
        let job = try #require(try await store.processingJobs().first)
        #expect(job.stage == .diarizing)
        #expect(await changes.count > 0)
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

private actor RequeueOnceDuringStage {
    private let store: CallStore
    private let callID: CallID
    private var hasRequeued = false

    init(store: CallStore, callID: CallID) {
        self.store = store
        self.callID = callID
    }

    /// Queues the call's stage again the way a rewritten transcript does, and only once, so the
    /// drain reclaims the work instead of looping over it.
    func requeueOnFirstRun() async throws -> Bool {
        guard !hasRequeued else { return false }
        hasRequeued = true
        try await store.saveTranscript(
            TranscriptRecord(
                callID: callID,
                language: "en",
                model: "test",
                text: "test",
                markdownPath: "/tmp/queued-again.md",
                jsonPath: "/tmp/queued-again.json"
            )
        )
        return true
    }
}

private actor CancelledStageRecorder {
    private(set) var callIDs: [CallID] = []

    func record(_ callID: CallID) {
        callIDs.append(callID)
    }
}

private actor ChangeCounter {
    private(set) var count = 0

    func record() {
        count += 1
    }
}

private actor RunCounter {
    private var runs = 0

    /// The number of the run that is starting, counting from one.
    func next() -> Int {
        runs += 1
        return runs
    }
}

private struct FixtureProcessingError: Error {
    let message: String
}
