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

    @Test("cleanup refuses a copied manifest that names another call")
    func cleanupRefusesManifestForAnotherCall() async throws {
        let fixture = try await RecoveryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let wrapper = fixture.recoveryRoot.appending(
            path: fixture.callID.rawValue.uuidString,
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: wrapper, withIntermediateDirectories: true)
        try writeManifest(
            RecoverableArtifact(
                callID: CallID(rawValue: UUID()),
                kind: .completedCall,
                originalDirectory: fixture.workingDirectory,
                recoveryDirectory: wrapper,
                deletedAt: fixture.finishedAt,
                purgeAfter: fixture.finishedAt.addingTimeInterval(60)
            ),
            to: wrapper
        )

        await #expect(throws: ArtifactRecoveryError.invalidManifest) {
            try await fixture.recovery().finalizeReadyCall(
                fixture.callID,
                store: fixture.store,
                at: fixture.finishedAt
            )
        }

        #expect(FileManager.default.fileExists(atPath: fixture.audio.path))
        #expect(!FileManager.default.fileExists(atPath: wrapper.appending(path: "payload").path))
    }

    @Test("cleanup refuses a manifest that points at another wrapper")
    func cleanupRefusesManifestForAnotherWrapper() async throws {
        let fixture = try await RecoveryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let wrapper = fixture.recoveryRoot.appending(
            path: fixture.callID.rawValue.uuidString,
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: wrapper, withIntermediateDirectories: true)
        let elsewhere = fixture.recoveryRoot.appending(
            path: UUID().uuidString,
            directoryHint: .isDirectory
        )
        try writeManifest(
            RecoverableArtifact(
                callID: fixture.callID,
                kind: .discardedRecording,
                originalDirectory: fixture.workingDirectory,
                recoveryDirectory: elsewhere,
                deletedAt: fixture.finishedAt,
                purgeAfter: fixture.finishedAt.addingTimeInterval(60)
            ),
            to: wrapper
        )

        #expect(throws: ArtifactRecoveryError.invalidManifest) {
            try fixture.recovery().discardCall(
                fixture.callID,
                sourceDirectory: fixture.workingDirectory,
                at: fixture.finishedAt
            )
        }

        #expect(FileManager.default.fileExists(atPath: fixture.audio.path))
        #expect(!FileManager.default.fileExists(atPath: elsewhere.path))
        #expect(!FileManager.default.fileExists(atPath: wrapper.appending(path: "payload").path))
    }

    @Test("a cleanup stopped after moving nothing or part of the files resumes on retry")
    func cleanupResumesAfterPartialMove() async throws {
        let fixture = try await RecoveryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let shots = fixture.workingDirectory.appending(path: "Screenshots", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        let shot = shots.appending(path: "shot-000000005-0000000000000001-000.jpg")
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: shot)
        let failing = FailingMoves(failing: [1, 3])
        let interrupted = fixture.recovery(cleanupMoveItem: { source, destination in
            if failing.shouldFail() { throw InterruptedRestore.failure }
            try FileManager.default.moveItem(at: source, to: destination)
        })
        let wrapper = fixture.recoveryRoot.appending(
            path: fixture.callID.rawValue.uuidString,
            directoryHint: .isDirectory
        )
        let payload = wrapper.appending(path: "payload", directoryHint: .isDirectory)

        // The first failure leaves the payload directory created but empty.
        await #expect(throws: InterruptedRestore.failure) {
            try await interrupted.finalizeReadyCall(
                fixture.callID,
                store: fixture.store,
                at: fixture.finishedAt
            )
        }
        #expect(FileManager.default.fileExists(atPath: payload.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: payload.path).isEmpty)
        #expect(FileManager.default.fileExists(atPath: fixture.audio.path))

        // The second failure comes after one child has moved, leaving a partial payload.
        await #expect(throws: InterruptedRestore.failure) {
            try await interrupted.finalizeReadyCall(
                fixture.callID,
                store: fixture.store,
                at: fixture.finishedAt
            )
        }
        let moved = try FileManager.default.contentsOfDirectory(atPath: payload.path)
        let left = try FileManager.default.contentsOfDirectory(atPath: fixture.workingDirectory.path)
        #expect(moved.count == 1, "moved \(moved) left \(left)")
        #expect(left.filter { $0 != ScreenshotArchive.directoryName }.count == 2, "moved \(moved) left \(left)")
        let remaining = Set(left.filter { $0 != ScreenshotArchive.directoryName })
        // Directory enumeration does not promise which child moves first. Every original child
        // must still exist on exactly one side of the interrupted move.
        #expect(Set(moved).isDisjoint(with: remaining))
        #expect(Set(moved).union(remaining) == ["call.m4a", "segment-001.mp4", "transcript.json"])

        let item = try #require(
            try await fixture.recovery().finalizeReadyCall(
                fixture.callID,
                store: fixture.store,
                at: fixture.finishedAt
            )
        )

        #expect(item.kind == .completedCall)
        #expect(!FileManager.default.fileExists(atPath: fixture.audio.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.json.path))
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.workingDirectory.appending(path: "segment-001.mp4").path
            )
        )
        #expect(FileManager.default.fileExists(atPath: payload.appending(path: "call.m4a").path))
        #expect(FileManager.default.fileExists(atPath: shot.path))
        #expect(FileManager.default.fileExists(atPath: fixture.markdown.path))
        #expect(try fixture.recovery().items() == [item])
    }

    @Test("cleanup refuses a source file that conflicts with what the payload holds")
    func cleanupRefusesConflictingSourceChild() async throws {
        let fixture = try await RecoveryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let failing = FailingMoves(failing: [2])
        let interrupted = fixture.recovery(cleanupMoveItem: { source, destination in
            if failing.shouldFail() { throw InterruptedRestore.failure }
            try FileManager.default.moveItem(at: source, to: destination)
        })
        let wrapper = fixture.recoveryRoot.appending(
            path: fixture.callID.rawValue.uuidString,
            directoryHint: .isDirectory
        )
        let payload = wrapper.appending(path: "payload", directoryHint: .isDirectory)

        await #expect(throws: InterruptedRestore.failure) {
            try await interrupted.finalizeReadyCall(
                fixture.callID,
                store: fixture.store,
                at: fixture.finishedAt
            )
        }
        let movedName = try #require(
            try FileManager.default.contentsOfDirectory(atPath: payload.path).first
        )
        let payloadFile = payload.appending(path: movedName)
        let keptBytes = try Data(contentsOf: payloadFile)
        let conflicting = fixture.workingDirectory.appending(path: movedName)
        try Data("a different copy".utf8).write(to: conflicting)

        await #expect(throws: ArtifactRecoveryError.invalidManifest) {
            try await fixture.recovery().finalizeReadyCall(
                fixture.callID,
                store: fixture.store,
                at: fixture.finishedAt
            )
        }

        #expect(try Data(contentsOf: payloadFile) == keptBytes)
        #expect(FileManager.default.fileExists(atPath: conflicting.path))
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

    @Test("the screen photographs stay with the call when its audio is given back")
    func screenshotsOutliveTheAudioCleanup() async throws {
        let fixture = try await RecoveryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let shots = fixture.workingDirectory.appending(
            path: "Screenshots",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        let shot = shots.appending(path: "shot-000000005-0000000000000001-000.jpg")
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: shot)

        let item = try #require(
            try await fixture.recovery().finalizeReadyCall(
                fixture.callID,
                store: fixture.store,
                at: fixture.finishedAt
            )
        )

        #expect(FileManager.default.fileExists(atPath: shot.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.audio.path))
        #expect(FileManager.default.fileExists(atPath: item.payloadDirectory.path))
        #expect(
            ScreenshotArchive.read(in: fixture.workingDirectory).map(\.url.lastPathComponent)
                == [shot.lastPathComponent]
        )

        // A repeat after the saved audio expired finds a folder that holds only pictures. That is
        // a finished call rather than a missing source, and the new pass must not fail on it.
        try fixture.recovery().purgeExpired(now: item.purgeAfter)
        let second = try await fixture.recovery().finalizeReadyCall(
            fixture.callID,
            store: fixture.store,
            at: fixture.finishedAt
        )
        #expect(second == nil)
        #expect(FileManager.default.fileExists(atPath: shot.path))
    }

    @Test("restoring a finished call puts its audio back beside its screenshots")
    func restoreMergesAudioBesideScreenshots() async throws {
        let fixture = try await RecoveryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let shots = fixture.workingDirectory.appending(
            path: "Screenshots",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        let shot = shots.appending(path: "shot-000000005-0000000000000001-000.jpg")
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: shot)
        _ = try await fixture.recovery().finalizeReadyCall(
            fixture.callID,
            store: fixture.store,
            at: fixture.finishedAt
        )

        try fixture.recovery().restore(fixture.callID)

        #expect(FileManager.default.fileExists(atPath: fixture.audio.path))
        #expect(FileManager.default.fileExists(atPath: shot.path))
        #expect(try fixture.recovery().items().isEmpty)
    }

    @Test("restore tolerates Finder metadata beside screenshots")
    func restoreIgnoresFinderMetadata() async throws {
        let fixture = try await RecoveryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let shots = fixture.workingDirectory.appending(path: "Screenshots", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        let shot = shots.appending(path: "shot-000000005-0000000000000001-000.jpg")
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: shot)
        let finderMetadata = fixture.workingDirectory.appending(path: ".DS_Store")
        try Data("old Finder metadata".utf8).write(to: finderMetadata)
        let item = try #require(
            try await fixture.recovery().finalizeReadyCall(
                fixture.callID,
                store: fixture.store,
                at: fixture.finishedAt
            )
        )
        let payloadMetadata = item.payloadDirectory.appending(path: ".DS_Store")
        #expect(try Data(contentsOf: payloadMetadata) == Data("old Finder metadata".utf8))
        try Data("finder".utf8).write(to: finderMetadata)

        try fixture.recovery().restore(fixture.callID)

        #expect(FileManager.default.fileExists(atPath: fixture.audio.path))
        #expect(FileManager.default.fileExists(atPath: shot.path))
        #expect(FileManager.default.fileExists(atPath: finderMetadata.path))
        #expect(try Data(contentsOf: finderMetadata) == Data("finder".utf8))
        #expect(!FileManager.default.fileExists(atPath: item.payloadDirectory.path))
        #expect(try fixture.recovery().items().isEmpty)
    }

    @Test("restore refuses a conflicting audio file and preserves both copies")
    func restoreRefusesConflictingAudio() async throws {
        let fixture = try await RecoveryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let shots = fixture.workingDirectory.appending(path: "Screenshots", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        let shot = shots.appending(path: "shot-000000005-0000000000000001-000.jpg")
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: shot)
        let item = try #require(
            try await fixture.recovery().finalizeReadyCall(
                fixture.callID,
                store: fixture.store,
                at: fixture.finishedAt
            )
        )
        let conflicting = fixture.workingDirectory.appending(path: "call.m4a")
        try Data("different audio".utf8).write(to: conflicting)
        let payloadAudio = item.payloadDirectory.appending(path: "call.m4a")
        let payloadBefore = try Data(contentsOf: payloadAudio)

        #expect(throws: ArtifactRecoveryError.restoreTargetExists) {
            try fixture.recovery().restore(fixture.callID)
        }

        #expect(try Data(contentsOf: conflicting) == Data("different audio".utf8))
        #expect(try Data(contentsOf: payloadAudio) == payloadBefore)
        #expect(FileManager.default.fileExists(atPath: shot.path))
        #expect(try fixture.recovery().items() == [item])
    }

    @Test("restore does not merge an unrelated entry into the call folder")
    func restoreRefusesUnrelatedTargetEntry() async throws {
        let fixture = try await RecoveryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let shots = fixture.workingDirectory.appending(path: "Screenshots", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        let shot = shots.appending(path: "shot-000000005-0000000000000001-000.jpg")
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: shot)
        let item = try #require(
            try await fixture.recovery().finalizeReadyCall(
                fixture.callID,
                store: fixture.store,
                at: fixture.finishedAt
            )
        )
        let unrelated = fixture.workingDirectory.appending(path: "notes.txt")
        try Data("keep me".utf8).write(to: unrelated)

        #expect(throws: ArtifactRecoveryError.restoreTargetExists) {
            try fixture.recovery().restore(fixture.callID)
        }

        #expect(try Data(contentsOf: unrelated) == Data("keep me".utf8))
        #expect(FileManager.default.fileExists(atPath: shot.path))
        #expect(FileManager.default.fileExists(atPath: item.payloadDirectory.path))
        #expect(try fixture.recovery().items() == [item])
    }

    @Test("a matching partial restore and Finder metadata can be retried")
    func restoreRetriesMatchingPartialMerge() async throws {
        let fixture = try await RecoveryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let shots = fixture.workingDirectory.appending(path: "Screenshots", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        let shot = shots.appending(path: "shot-000000005-0000000000000001-000.jpg")
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: shot)
        let item = try #require(
            try await fixture.recovery().finalizeReadyCall(
                fixture.callID,
                store: fixture.store,
                at: fixture.finishedAt
            )
        )
        let payloadAudio = item.payloadDirectory.appending(path: "call.m4a")
        try FileManager.default.copyItem(at: payloadAudio, to: fixture.workingDirectory.appending(path: "call.m4a"))
        try Data("finder".utf8).write(to: fixture.workingDirectory.appending(path: ".DS_Store"))

        try fixture.recovery().restore(fixture.callID)

        #expect(FileManager.default.fileExists(atPath: fixture.audio.path))
        #expect(FileManager.default.fileExists(atPath: shot.path))
        #expect(try fixture.recovery().items().isEmpty)
    }

    private func cleanedCallWithScreenshots(
        _ fixture: RecoveryFixture
    ) async throws -> (item: RecoverableArtifact, wrapper: URL) {
        let shots = fixture.workingDirectory.appending(path: "Screenshots", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        let shot = shots.appending(path: "shot-000000005-0000000000000001-000.jpg")
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: shot)
        let item = try #require(
            try await fixture.recovery().finalizeReadyCall(
                fixture.callID,
                store: fixture.store,
                at: fixture.finishedAt
            )
        )
        let wrapper = fixture.recoveryRoot.appending(
            path: fixture.callID.rawValue.uuidString,
            directoryHint: .isDirectory
        )
        return (item, wrapper)
    }

    @Test("a restore journal with a duplicate name is refused before any move")
    func restoreRefusesDuplicateJournalNames() async throws {
        let fixture = try await RecoveryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (item, wrapper) = try await cleanedCallWithScreenshots(fixture)
        let journal = TestRestoreJournal(entries: [
            .init(name: "call.m4a", size: 5, sha256: String(repeating: "a", count: 64)),
            .init(name: "call.m4a", size: 5, sha256: String(repeating: "b", count: 64)),
        ])
        let journalURL = wrapper.appending(path: "restore-journal.json")
        try JSONEncoder().encode(journal).write(to: journalURL)

        #expect(throws: ArtifactRecoveryError.invalidManifest) {
            try fixture.recovery().restore(fixture.callID)
        }

        #expect(!FileManager.default.fileExists(atPath: fixture.audio.path))
        #expect(
            FileManager.default.fileExists(
                atPath: item.payloadDirectory.appending(path: "call.m4a").path
            )
        )
        #expect(FileManager.default.fileExists(atPath: journalURL.path))
    }

    @Test("a restore journal with a path entry is refused before any move")
    func restoreRefusesJournalPathEntry() async throws {
        let fixture = try await RecoveryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (item, wrapper) = try await cleanedCallWithScreenshots(fixture)
        let journal = TestRestoreJournal(entries: [
            .init(name: "../escaped", size: 4, sha256: String(repeating: "a", count: 64))
        ])
        let journalURL = wrapper.appending(path: "restore-journal.json")
        try JSONEncoder().encode(journal).write(to: journalURL)
        let escaped = fixture.recordingsRoot.appending(path: "escaped")

        #expect(throws: ArtifactRecoveryError.invalidManifest) {
            try fixture.recovery().restore(fixture.callID)
        }

        #expect(!FileManager.default.fileExists(atPath: escaped.path))
        #expect(
            FileManager.default.fileExists(
                atPath: item.payloadDirectory.appending(path: "call.m4a").path
            )
        )
        #expect(FileManager.default.fileExists(atPath: journalURL.path))
    }

    @Test("a restore whose wrapper removal fails finishes on the next try")
    func restoreFinishesAfterWrapperRemovalFailure() async throws {
        let fixture = try await RecoveryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (item, wrapper) = try await cleanedCallWithScreenshots(fixture)
        let shot = fixture.workingDirectory.appending(
            path: "Screenshots",
            directoryHint: .isDirectory
        ).appending(path: "shot-000000005-0000000000000001-000.jpg")
        let failingRemoval = fixture.recovery(removeWrapper: { _ in
            throw InterruptedRestore.failure
        })

        try failingRemoval.restore(fixture.callID)

        #expect(FileManager.default.fileExists(atPath: fixture.audio.path))
        #expect(FileManager.default.fileExists(atPath: fixture.json.path))
        #expect(FileManager.default.fileExists(atPath: shot.path))
        #expect(FileManager.default.fileExists(atPath: item.payloadDirectory.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: item.payloadDirectory.path).isEmpty)
        #expect(
            FileManager.default.fileExists(
                atPath: wrapper.appending(path: "restore-journal.json").path
            )
        )
        #expect(try fixture.recovery().items() == [item])

        try fixture.recovery().restore(fixture.callID)

        #expect(FileManager.default.fileExists(atPath: fixture.audio.path))
        #expect(FileManager.default.fileExists(atPath: fixture.json.path))
        #expect(FileManager.default.fileExists(atPath: shot.path))
        #expect(try fixture.recovery().items().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: wrapper.path))
    }

    @Test("a restore interrupted after its first move resumes without overwriting")
    func restoreResumesAfterMoveFailure() async throws {
        let fixture = try await RecoveryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let shots = fixture.workingDirectory.appending(path: "Screenshots", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        let shot = shots.appending(path: "shot-000000005-0000000000000001-000.jpg")
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: shot)
        let item = try #require(
            try await fixture.recovery().finalizeReadyCall(
                fixture.callID,
                store: fixture.store,
                at: fixture.finishedAt
            )
        )
        let moveCounter = CountingFailure()
        let interrupted = fixture.recovery { source, destination in
            if moveCounter.next() == 2 { throw InterruptedRestore.failure }
            try FileManager.default.moveItem(at: source, to: destination)
        }

        #expect(throws: InterruptedRestore.failure) {
            try interrupted.restore(fixture.callID)
        }

        #expect(FileManager.default.fileExists(atPath: fixture.audio.path))
        #expect(FileManager.default.fileExists(atPath: item.payloadDirectory.path))
        #expect(FileManager.default.fileExists(atPath: shot.path))

        try fixture.recovery().restore(fixture.callID)

        #expect(FileManager.default.fileExists(atPath: fixture.audio.path))
        #expect(FileManager.default.fileExists(atPath: fixture.json.path))
        #expect(FileManager.default.fileExists(atPath: shot.path))
        #expect(try fixture.recovery().items().isEmpty)
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

    func recovery(
        restoreMoveItem: (@Sendable (URL, URL) throws -> Void)? = nil,
        cleanupMoveItem: (@Sendable (URL, URL) throws -> Void)? = nil,
        removeWrapper: (@Sendable (URL) throws -> Void)? = nil
    ) -> ArtifactRecovery {
        return ArtifactRecovery(
            directory: recoveryRoot,
            recordingsRoot: recordingsRoot,
            retention: 24 * 60 * 60,
            restoreMoveItem: restoreMoveItem ?? { try FileManager.default.moveItem(at: $0, to: $1) },
            cleanupMoveItem: cleanupMoveItem ?? { try FileManager.default.moveItem(at: $0, to: $1) },
            removeRecoveryWrapper: removeWrapper ?? { try FileManager.default.removeItem(at: $0) }
        )
    }
}

private final class CountingFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }
}

private final class FailingMoves: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let failing: Set<Int>

    init(failing: Set<Int>) {
        self.failing = failing
    }

    func shouldFail() -> Bool {
        lock.withLock {
            count += 1
            return failing.contains(count)
        }
    }
}

private struct TestRestoreJournal: Encodable {
    struct Entry: Encodable {
        let name: String
        let size: Int
        let sha256: String
    }

    let entries: [Entry]
}

private func writeManifest(_ item: RecoverableArtifact, to wrapper: URL) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(item).write(to: wrapper.appending(path: "manifest.json"))
}

private enum InterruptedRestore: Error, Equatable {
    case failure
}
