import CallRecorderCore
import Foundation
import Libsql
import Testing
@testable import CallRecorderApp

@Suite("Artifact recovery")
struct ArtifactRecoveryTests {
    @Test("speaker retry uses the saved checkpoint and cannot interrupt an active job")
    func retriesOnlyInactiveSpeakerAnalysis() async throws {
        let fixture = try await RecoveryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let prior = try await fixture.store.transcript(for: fixture.callID)
        try await fixture.store.retrySpeakerAnalysis(callID: fixture.callID)
        let job = try #require(try await fixture.store.claimNextProcessingJob())
        #expect(job.stage == .diarizing)
        #expect(job.executionState == .running)
        await #expect(throws: CallStoreError.processingJobNotClaimed(fixture.callID)) {
            try await fixture.store.retrySpeakerAnalysis(callID: fixture.callID)
        }
        #expect(try await fixture.store.transcript(for: fixture.callID) == prior)
    }

    @Test("a queued indexing stage does not block separating the voices again")
    func reseparationReplacesQueuedIndexing() async throws {
        let fixture = try await RecoveryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        // What a naming pass leaves behind: the call owes a search index, so its job has been
        // queued again at the indexing stage. The 2026-09-18 14:01 call sat like this while both
        // Retry and Separate again refused it, because a queued job is neither complete nor
        // failed. Separating its voices again outranks the queued stage, which it replaces.
        let connection = try Database(fixture.databasePath).connect()
        try connection.executeBatch(
            """
            UPDATE calls SET status = 'indexing' WHERE id = '\(fixture.callID.rawValue.uuidString)';
            UPDATE processing_jobs SET stage = 'indexing', execution_state = 'pending',
                attempt_count = 12 WHERE call_id = '\(fixture.callID.rawValue.uuidString)';
            """
        )

        try await fixture.store.retrySpeakerAnalysis(callID: fixture.callID)

        let job = try #require(try await fixture.store.processingJobs().first)
        #expect(job.stage == .diarizing)
        #expect(job.executionState == .pending)
        #expect(try await fixture.store.call(id: fixture.callID)?.status == .transcribing)
    }

    @Test("a queued transcription is not spent on separating voices")
    func reseparationLeavesQueuedTranscriptionAlone() async throws {
        let fixture = try await RecoveryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let connection = try Database(fixture.databasePath).connect()
        try connection.executeBatch(
            """
            UPDATE processing_jobs SET stage = 'transcribing', execution_state = 'pending'
                WHERE call_id = '\(fixture.callID.rawValue.uuidString)';
            """
        )

        await #expect(throws: CallStoreError.processingJobNotClaimed(fixture.callID)) {
            try await fixture.store.retrySpeakerAnalysis(callID: fixture.callID)
        }
    }

    @Test("legacy failed speaker detection cannot send audio to automatic cleanup")
    func retainsAudioWhenSpeakerDetectionNeverRan() async throws {
        let fixture = try await RecoveryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try JSONEncoder().encode(NormalizedTranscript(
            callId: fixture.callID.rawValue.uuidString, language: "en", model: "test",
            participants: [], glossary: [],
            segments: [TranscriptSegment(startMs: 0, endMs: 10_000, text: "Remote voice.", source: .system)]
        )).write(to: fixture.json)
        await #expect(throws: ArtifactRecoveryError.speakerReviewPending) {
            try await fixture.recovery().finalizeReadyCall(fixture.callID, store: fixture.store)
        }
        #expect(FileManager.default.fileExists(atPath: fixture.audio.path))
        #expect(try fixture.recovery().items().isEmpty)
    }

    @Test("a call told to keep its audio keeps it, and is finished all the same")
    func keepsAudioWhenTheSettingSaysTo() async throws {
        // Given
        let fixture = try await RecoveryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let recovery = fixture.recovery()

        // When
        let item = try await recovery.finalizeReadyCall(
            fixture.callID,
            store: fixture.store,
            removingAudio: false,
            at: fixture.finishedAt
        )

        // Then
        #expect(item == nil)
        #expect(FileManager.default.fileExists(atPath: fixture.audio.path))
        #expect(try recovery.items().isEmpty)
    }

    @Test("cleanup refuses a call whose index is not ready")
    func refusesCleanupUntilIndexIsReady() async throws {
        // Given
        let fixture = try await RecoveryFixture(indexReady: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let recovery = fixture.recovery()

        // When / Then
        await #expect(throws: ArtifactRecoveryError.indexNotReady) {
            try await recovery.finalizeReadyCall(
                fixture.callID,
                store: fixture.store,
                at: fixture.finishedAt
            )
        }
        #expect(FileManager.default.fileExists(atPath: fixture.audio.path))
    }

    @Test("cleanup moves working files but keeps the promoted transcript")
    func movesWorkingFilesAfterVerification() async throws {
        // Given
        let fixture = try await RecoveryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let recovery = fixture.recovery()

        // When
        let item = try #require(
            try await recovery.finalizeReadyCall(
                fixture.callID,
                store: fixture.store,
                at: fixture.finishedAt
            )
        )

        // Then
        #expect(item.kind == .completedCall)
        #expect(!FileManager.default.fileExists(atPath: fixture.workingDirectory.path))
        #expect(FileManager.default.fileExists(atPath: item.payloadDirectory.path))
        #expect(FileManager.default.fileExists(atPath: fixture.markdown.path))
        #expect(try recovery.items() == [item])
    }

    @Test("restore returns a cleaned call to its original folder")
    func restoresCleanedCall() async throws {
        // Given
        let fixture = try await RecoveryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let recovery = fixture.recovery()
        _ = try await recovery.finalizeReadyCall(
            fixture.callID,
            store: fixture.store,
            at: fixture.finishedAt
        )

        // When
        try recovery.restore(fixture.callID)

        // Then
        #expect(FileManager.default.fileExists(atPath: fixture.audio.path))
        #expect(FileManager.default.fileExists(atPath: fixture.json.path))
        #expect(try recovery.items().isEmpty)
    }

    @Test("expired recovery items are purged after 24 hours")
    func purgesExpiredItem() async throws {
        // Given
        let fixture = try await RecoveryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let recovery = fixture.recovery()
        let item = try #require(
            try await recovery.finalizeReadyCall(
                fixture.callID,
                store: fixture.store,
                at: fixture.finishedAt
            )
        )

        // When
        try recovery.purgeExpired(now: item.purgeAfter)

        // Then
        #expect(try recovery.items().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: item.payloadDirectory.path))
    }

    @Test("a cleanup retried after it failed finishes instead of failing again")
    func retryAfterFailedCleanupFinishes() async throws {
        // Given: the state a failed cleanup leaves behind, which is what a retry found before.
        let fixture = try await RecoveryFixture(failedCleanup: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let recovery = fixture.recovery()

        // When
        let item = try await recovery.finalizeReadyCall(fixture.callID, store: fixture.store)

        // Then
        #expect(item == nil)
        #expect(try recovery.items().isEmpty)
        #expect(FileManager.default.fileExists(atPath: fixture.markdown.path))
    }

    @Test("a call whose working files are gone is already finished, not broken")
    func finalizedCallRepeatsWithoutFailing() async throws {
        // Given
        let fixture = try await RecoveryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let recovery = fixture.recovery()
        try FileManager.default.removeItem(at: fixture.workingDirectory)

        // When
        let item = try await recovery.finalizeReadyCall(fixture.callID, store: fixture.store)

        // Then
        #expect(item == nil)
        #expect(try recovery.items().isEmpty)
    }

    @Test("re-running cleanup after the saved copy expired succeeds")
    func repeatCleanupAfterPurgeSucceeds() async throws {
        // Given: a call that was cleaned once, and whose saved copy has since expired.
        let fixture = try await RecoveryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let recovery = fixture.recovery()
        let first = try #require(
            try await recovery.finalizeReadyCall(
                fixture.callID,
                store: fixture.store,
                at: fixture.finishedAt
            )
        )
        try recovery.purgeExpired(now: first.purgeAfter)

        // When
        let second = try await recovery.finalizeReadyCall(
            fixture.callID,
            store: fixture.store,
            at: fixture.finishedAt
        )

        // Then
        #expect(second == nil)
        #expect(try recovery.items().isEmpty)
        #expect(FileManager.default.fileExists(atPath: fixture.markdown.path))
    }

    @Test("cleaning twice while the saved copy exists returns the same copy")
    func repeatCleanupReturnsSavedCopy() async throws {
        // Given
        let fixture = try await RecoveryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let recovery = fixture.recovery()
        let first = try #require(
            try await recovery.finalizeReadyCall(
                fixture.callID,
                store: fixture.store,
                at: fixture.finishedAt
            )
        )

        // When
        let second = try await recovery.finalizeReadyCall(
            fixture.callID,
            store: fixture.store,
            at: fixture.finishedAt
        )

        // Then
        #expect(second == first)
        #expect(try recovery.items() == [first])
    }

    @Test("discarded accidental recording remains recoverable")
    func discardedRecordingIsRecoverable() async throws {
        // Given
        let fixture = try await RecoveryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let recovery = fixture.recovery()

        // When
        let item = try recovery.discardCall(
            fixture.callID,
            sourceDirectory: fixture.workingDirectory,
            at: fixture.finishedAt
        )

        // Then
        #expect(item.kind == .discardedRecording)
        #expect(!FileManager.default.fileExists(atPath: fixture.workingDirectory.path))
        #expect(FileManager.default.fileExists(atPath: item.payloadDirectory.path))
    }

    @Test("cleanup waits for every speaker review, then becomes recoverable")
    func cleanupWaitsForSpeakerReview() async throws {
        let fixture = try await RecoveryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let speakers = SpeakerStore(
            store: fixture.store,
            cipher: try VoiceprintCipher(keyData: Data(0..<32))
        )
        var embedding = Array(repeating: Float.zero, count: 256)
        embedding[0] = 1
        let pending = PendingSpeakerCluster(
            callID: fixture.callID,
            speakerIndex: 0,
            speakerLabel: "SPEAKER_00",
            cluster: SpeakerCluster(
                id: SpeakerClusterID(rawValue: UUID()),
                modelVersion: "model-v1",
                embedding: embedding,
                speechDurationMilliseconds: 10_000
            ),
            createdAt: fixture.finishedAt
        )
        try await speakers.savePending(pending)

        await #expect(throws: ArtifactRecoveryError.speakerReviewPending) {
            try await fixture.recovery().finalizeReadyCall(
                fixture.callID,
                store: fixture.store,
                at: fixture.finishedAt
            )
        }

        #expect(FileManager.default.fileExists(atPath: fixture.workingDirectory.path))
        #expect(try await speakers.pendingClusters(for: fixture.callID).map(\.cluster.id) == [pending.cluster.id])
        #expect(try await speakers.unresolvedReviews().map(\.clusterID) == [pending.cluster.id])

        try await speakers.keepUnknown(clusterID: pending.cluster.id, at: fixture.finishedAt)
        let item = try #require(
            try await fixture.recovery().finalizeReadyCall(
                fixture.callID,
                store: fixture.store,
                at: fixture.finishedAt
            )
        )

        #expect(!FileManager.default.fileExists(atPath: fixture.workingDirectory.path))
        #expect(FileManager.default.fileExists(atPath: item.payloadDirectory.path))
    }
}

private struct RecoveryFixture {
    let root: URL
    let recordingsRoot: URL
    let recoveryRoot: URL
    let workingDirectory: URL
    let audio: URL
    let markdown: URL
    let json: URL
    let databasePath: String
    let store: CallStore
    let callID: CallID
    let finishedAt = Date(timeIntervalSince1970: 1_800_000_000)

    init(indexReady: Bool = true, failedCleanup: Bool = false) async throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "call-recorder-recovery-\(UUID().uuidString)", directoryHint: .isDirectory)
        recordingsRoot = root.appending(path: "Recordings", directoryHint: .isDirectory)
        recoveryRoot = root.appending(path: "Recently Deleted", directoryHint: .isDirectory)
        workingDirectory = recordingsRoot.appending(
            path: "2027-01-15 15.00.00",
            directoryHint: .isDirectory
        )
        audio = workingDirectory.appending(path: "call.m4a")
        markdown = recordingsRoot.appending(path: "2027-01-15 15.00.00.md")
        json = workingDirectory.appending(path: "transcript.json")
        databasePath = root.appending(path: "calls.db").path
        callID = CallID(rawValue: UUID())
        let seedStore = try CallStore(path: databasePath)

        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: audio)
        try Data("segment".utf8).write(to: workingDirectory.appending(path: "segment-001.mp4"))
        try Data("transcript".utf8).write(to: markdown)
        try JSONEncoder().encode(NormalizedTranscript(
            callId: callID.rawValue.uuidString, language: "en", model: "test",
            participants: [], glossary: [], segments: []
        )).write(to: json)
        try await seedStore.migrate()
        try await seedStore.createCall(
            .started(id: callID, at: finishedAt.addingTimeInterval(-60))
        )
        try await seedStore.updateCall(
            id: callID,
            endedAt: finishedAt,
            audioPath: audio.path,
            status: .metadata
        )
        try await seedStore.saveTranscript(
            TranscriptRecord(
                callID: callID,
                language: "en",
                model: "test",
                text: "test",
                markdownPath: markdown.path,
                jsonPath: json.path
            )
        )
        let database = try Database(databasePath)
        let connection = try database.connect()
        try connection.executeBatch(
            """
            UPDATE calls SET status = 'ready' WHERE id = '\(callID.rawValue.uuidString)';
            UPDATE processing_jobs SET stage = 'ready', execution_state = 'complete'
                WHERE call_id = '\(callID.rawValue.uuidString)';
            UPDATE index_jobs SET status = '\(indexReady ? "ready" : "pending")'
                WHERE call_id = '\(callID.rawValue.uuidString)';
            """
        )
        if failedCleanup {
            // What a failed cleanup leaves: the call is marked failed, the job sits at the
            // finalizing stage, and the working files were removed by the earlier attempt.
            try FileManager.default.removeItem(at: workingDirectory)
            try connection.executeBatch(
                """
                UPDATE calls SET status = 'failed' WHERE id = '\(callID.rawValue.uuidString)';
                UPDATE processing_jobs SET stage = 'finalizingArtifacts',
                    execution_state = 'failed'
                    WHERE call_id = '\(callID.rawValue.uuidString)';
                """
            )
        }
        store = try CallStore(path: databasePath)
    }

    func recovery() -> ArtifactRecovery {
        ArtifactRecovery(
            directory: recoveryRoot,
            recordingsRoot: recordingsRoot,
            retention: 24 * 60 * 60
        )
    }
}
