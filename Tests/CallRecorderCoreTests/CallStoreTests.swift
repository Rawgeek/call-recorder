import Foundation
import Libsql
import Testing
@testable import CallRecorderCore

@Suite("Call store")
struct CallStoreTests {
    @Test("external speaker review requests are claimed exactly once and completed")
    func claimsExternalSpeakerReviewRequestOnce() async throws {
        // Given
        let databasePath = temporaryDatabasePath()
        defer { try? FileManager.default.removeItem(atPath: databasePath) }
        let store = try CallStore(path: databasePath)
        try await store.migrate()
        let callID = CallID(rawValue: UUID())
        let participant = try await store.upsertParticipant(name: "Alice")
        try await store.createCall(.started(id: callID, at: Date()))
        let speakerStore = SpeakerStore(
            store: store,
            cipher: try VoiceprintCipher(keyData: Data(0..<32))
        )
        let clusterID = try await speakerStore.savePending(
            PendingSpeakerCluster(
                callID: callID,
                speakerIndex: 0,
                speakerLabel: "Speaker 1",
                cluster: SpeakerCluster(
                    id: SpeakerClusterID(rawValue: UUID()),
                    modelVersion: "model-v1",
                    embedding: [1] + Array(repeating: 0, count: 255),
                    speechDurationMilliseconds: 5_000
                ),
                createdAt: Date()
            )
        )
        let requestID = UUID()
        let external = try Database(databasePath).connect()
        try external.executeBatch("PRAGMA foreign_keys = ON;")
        _ = try external.execute(
            "INSERT INTO speaker_review_requests ("
                + "id, cluster_id, participant_id, action, status, created_at, updated_at"
                + ") VALUES (?, ?, ?, 'confirm', 'pending', ?, ?)",
            [
                requestID.uuidString,
                clusterID.rawValue.uuidString,
                participant.id.rawValue.uuidString,
                Date().timeIntervalSince1970,
                Date().timeIntervalSince1970,
            ]
        )

        // When
        let claimed = try await store.claimNextSpeakerReviewRequest()
        let secondClaim = try await store.claimNextSpeakerReviewRequest()
        let resetCount = try await store.resetInterruptedSpeakerReviewRequests()
        let reclaimed = try await store.claimNextSpeakerReviewRequest()
        try await store.completeSpeakerReviewRequest(requestID)

        // Then
        #expect(claimed?.id == requestID)
        #expect(claimed?.clusterID == clusterID)
        #expect(claimed?.participantID == participant.id)
        #expect(claimed?.action == .confirm)
        #expect(secondClaim == nil)
        #expect(resetCount == 1)
        #expect(reclaimed == claimed)
        let verifier = try Database(databasePath).connect()
        let status = try verifier.query(
            "SELECT status FROM speaker_review_requests WHERE id = ?",
            [requestID.uuidString]
        ).next()?.getString(0)
        #expect(status == "completed")
    }

    @Test("a reopen request sends a decided speaker back to review")
    func storesReopenSpeakerReviewRequest() async throws {
        // Given
        let databasePath = temporaryDatabasePath()
        defer { try? FileManager.default.removeItem(atPath: databasePath) }
        let store = try CallStore(path: databasePath)
        try await store.migrate()
        let callID = CallID(rawValue: UUID())
        try await store.createCall(.started(id: callID, at: Date()))
        let speakerStore = SpeakerStore(
            store: store,
            cipher: try VoiceprintCipher(keyData: Data(0..<32))
        )
        let clusterID = try await speakerStore.savePending(
            PendingSpeakerCluster(
                callID: callID,
                speakerIndex: 0,
                speakerLabel: "Speaker 1",
                cluster: SpeakerCluster(
                    id: SpeakerClusterID(rawValue: UUID()),
                    modelVersion: "model-v1",
                    embedding: [1] + Array(repeating: 0, count: 255),
                    speechDurationMilliseconds: 5_000
                ),
                createdAt: Date()
            )
        )
        let requestID = UUID()
        let external = try Database(databasePath).connect()
        try external.executeBatch("PRAGMA foreign_keys = ON;")

        // When a client asks for the speaker to be reviewed again
        _ = try external.execute(
            "INSERT INTO speaker_review_requests ("
                + "id, cluster_id, participant_id, action, status, created_at, updated_at"
                + ") VALUES (?, ?, NULL, 'reopen', 'pending', ?, ?)",
            [
                requestID.uuidString,
                clusterID.rawValue.uuidString,
                Date().timeIntervalSince1970,
                Date().timeIntervalSince1970,
            ]
        )
        let claimed = try await store.claimNextSpeakerReviewRequest()

        // Then
        #expect(claimed?.id == requestID)
        #expect(claimed?.action == .reopen)
        #expect(claimed?.participantID == nil)
    }

    @Test("a claim can be narrowed to the requests that need no voice key")
    func claimsOnlyRequestedSpeakerReviewActions() async throws {
        // Given a call whose older request names a voice and whose newer one names lines.
        let databasePath = temporaryDatabasePath()
        defer { try? FileManager.default.removeItem(atPath: databasePath) }
        let store = try CallStore(path: databasePath)
        try await store.migrate()
        let callID = CallID(rawValue: UUID())
        let participant = try await store.upsertParticipant(name: "Alice")
        try await store.createCall(.started(id: callID, at: Date()))
        let speakerStore = SpeakerStore(
            store: store,
            cipher: try VoiceprintCipher(keyData: Data(0..<32))
        )
        let clusterID = try await speakerStore.savePending(
            PendingSpeakerCluster(
                callID: callID,
                speakerIndex: 0,
                speakerLabel: "Speaker 1",
                cluster: SpeakerCluster(
                    id: SpeakerClusterID(rawValue: UUID()),
                    modelVersion: "model-v1",
                    embedding: [1] + Array(repeating: 0, count: 255),
                    speechDurationMilliseconds: 5_000
                ),
                createdAt: Date()
            )
        )
        let voiceRequestID = UUID()
        let lineRequestID = UUID()
        let external = try Database(databasePath).connect()
        try external.executeBatch("PRAGMA foreign_keys = ON;")
        let now = Date().timeIntervalSince1970
        _ = try external.execute(
            "INSERT INTO speaker_review_requests ("
                + "id, cluster_id, participant_id, action, status, created_at, updated_at"
                + ") VALUES (?, ?, ?, 'confirm', 'pending', ?, ?)",
            [
                voiceRequestID.uuidString,
                clusterID.rawValue.uuidString,
                participant.id.rawValue.uuidString,
                now - 60,
                now - 60,
            ]
        )
        _ = try external.execute(
            "INSERT INTO speaker_review_requests ("
                + "id, call_id, participant_id, action, status, start_ms, end_ms, created_at, updated_at"
                + ") VALUES (?, ?, ?, 'assignLines', 'pending', ?, ?, ?, ?)",
            [
                lineRequestID.uuidString,
                callID.rawValue.uuidString,
                participant.id.rawValue.uuidString,
                1_000,
                2_000,
                now,
                now,
            ]
        )

        // When only the line actions can be applied
        let claimed = try await store.claimNextSpeakerReviewRequest(
            actions: [.assignLines, .releaseLines]
        )
        let verifier = try Database(databasePath).connect()

        // Then the newer line request is claimed and the older voice request stays pending for
        // when the voice layer is there.
        #expect(claimed?.id == lineRequestID)
        #expect(claimed?.action == .assignLines)
        #expect(claimed?.lineRange?.lowerBound == 1_000)
        #expect(claimed?.lineRange?.upperBound == 2_000)
        let voiceStatus = try verifier.query(
            "SELECT status FROM speaker_review_requests WHERE id = ?",
            [voiceRequestID.uuidString]
        ).next()?.getString(0)
        #expect(voiceStatus == "pending")

        // And with no filter the older voice request is the one that comes back.
        let unfiltered = try await store.claimNextSpeakerReviewRequest()
        #expect(unfiltered?.id == voiceRequestID)
    }

    @Test("a fresh unindexed call can be deleted before MCP creates search tables")
    func deletesCallWithoutSearchSchema() async throws {
        // Given
        let store = try CallStore(path: temporaryDatabasePath())
        try await store.migrate()
        let callID = CallID(rawValue: UUID())
        try await store.createCall(.started(id: callID, at: Date()))

        // When
        try await store.deleteCall(callID)

        // Then
        #expect(try await store.call(id: callID) == nil)
    }

    @Test("a vocabulary term can be edited and deleted")
    func editsAndDeletesGlossaryTerm() async throws {
        // Given an existing term with aliases
        let databasePath = temporaryDatabasePath()
        defer { try? FileManager.default.removeItem(atPath: databasePath) }
        let store = try CallStore(path: databasePath)
        try await store.migrate()
        let term = try await store.upsertGlossaryTerm(
            preferred: "Globex",
            aliases: ["Globexx", "Globe ship"]
        )
        #expect(try await store.listGlossaryTerms().map(\.preferred) == ["Globex"])

        // When the term is edited by its preferred spelling
        let edited = try await store.upsertGlossaryTerm(
            preferred: "Globex",
            aliases: ["Globexx", "Globe ship", "GlobeShip"]
        )

        // Then the edit keeps one row and replaces the aliases
        #expect(edited.id == term.id)
        let stored = try await store.listGlossaryTerms()
        #expect(stored.count == 1)
        #expect(stored[0].aliases.contains("GlobeShip"))

        // When the term is deleted
        try await store.deleteGlossaryTerm(id: term.id)

        // Then it is gone
        #expect(try await store.listGlossaryTerms().isEmpty)
    }

    @Test("deleting a missing vocabulary term reports an invalid identifier")
    func refusesToDeleteMissingGlossaryTerm() async throws {
        let databasePath = temporaryDatabasePath()
        defer { try? FileManager.default.removeItem(atPath: databasePath) }
        let store = try CallStore(path: databasePath)
        try await store.migrate()

        await #expect(throws: CallStoreError.self) {
            try await store.deleteGlossaryTerm(id: GlossaryTermID(rawValue: UUID()))
        }
    }
    @Test("every processing stage reads as plain words")
    func stagesHaveReadableLabels() {
        for stage in ProcessingStage.allCases {
            #expect(stage.displayName.isEmpty == false)
            #expect(stage.displayDetail.isEmpty == false)
            // No raw Swift case names or underscores may reach the Recovery list.
            #expect(stage.displayName.contains("_") == false)
            #expect(stage.displayDetail.contains("_") == false)
            #expect(stage.displayName != stage.rawValue || stage == .ready)
        }
    }




    @Test("migration is idempotent and enables the base schema")
    func migrationIsIdempotent() async throws {
        // Given
        let store = try CallStore(path: temporaryDatabasePath())

        // When
        try await store.migrate()
        try await store.migrate()

        // Then
        #expect(try await store.schemaVersion() == 1)
    }

    @Test("opening a database creates its missing parent directory")
    func openingCreatesParentDirectory() async throws {
        // Given
        let root = FileManager.default.temporaryDirectory
            .appending(path: "call-recorder-parent-\(UUID().uuidString)", directoryHint: .isDirectory)
        let path = root.appending(path: "nested/calls.db")
        defer { try? FileManager.default.removeItem(at: root) }

        // When
        let store = try CallStore(path: path.path)
        try await store.migrate()

        // Then
        #expect(FileManager.default.fileExists(atPath: path.path))
    }

    @Test("base migration preserves a newer search schema version")
    func baseMigrationPreservesNewerSchemaVersion() async throws {
        // Given
        let path = temporaryDatabasePath()
        do {
            let database = try Database(path)
            let connection = try database.connect()
            try connection.executeBatch("PRAGMA user_version = 2;")
        }
        let store = try CallStore(path: path)

        // When
        try await store.migrate()

        // Then
        #expect(try await store.schemaVersion() == 2)
    }

    @Test("migration turns a legacy indexing call into pending processing work")
    func migratesLegacyIndexingCall() async throws {
        // Given
        let fixture = try legacyStore(callStatus: "indexing", indexStatus: "pending")

        // When
        try await fixture.store.migrate()

        // Then
        let job = try #require(try await fixture.store.processingJobs().first)
        #expect(job.callID == fixture.callID)
        #expect(job.stage == .indexing)
        #expect(job.executionState == .pending)
        #expect(job.attemptCount == 0)
        #expect(job.createdAt == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(job.updatedAt == Date(timeIntervalSince1970: 1_800_000_060))
        #expect(job.startedAt == nil)
        #expect(job.completedAt == nil)
        #expect(job.latestEventID == nil)
        #expect(try await fixture.store.call(id: fixture.callID)?.status == .indexing)
        #expect(try await fixture.store.schemaVersion() == 2)
    }

    @Test("migration exposes an interrupted legacy recording as recoverable failure")
    func migratesInterruptedRecordingCall() async throws {
        // Given
        let fixture = try legacyStore(callStatus: "recording")

        // When
        try await fixture.store.migrate()

        // Then
        let job = try #require(try await fixture.store.processingJobs().first)
        #expect(job.callID == fixture.callID)
        #expect(job.stage == .awaitingParticipants)
        #expect(job.executionState == .failed)
        #expect(try await fixture.store.call(id: fixture.callID)?.status == .failed)
    }

    @Test("migration refuses to commit over foreign-key corruption")
    func migrationRejectsForeignKeyCorruption() async throws {
        // Given
        let fixture = try legacyStore(
            callStatus: "metadata",
            includeOrphanIndexJob: true
        )

        // When / Then
        await #expect(throws: CallStoreError.foreignKeyIntegrityFailed) {
            try await fixture.store.migrate()
        }
    }

    @Test("two database connections claim one pending job only once")
    func claimsOneJobOnce() async throws {
        // Given
        let fixture = try legacyStore(callStatus: "metadata")
        try await fixture.store.migrate()
        let secondStore = try CallStore(path: fixture.path)
        try await secondStore.migrate()
        let now = Date(timeIntervalSince1970: 1_800_000_120)

        // When
        async let first = fixture.store.claimNextProcessingJob(at: now)
        async let second = secondStore.claimNextProcessingJob(at: now)
        let (firstClaim, secondClaim) = try await (first, second)

        // Then
        let claim = try #require([firstClaim, secondClaim].compactMap { $0 }.first)
        #expect([firstClaim, secondClaim].compactMap { $0 }.count == 1)
        #expect(claim.callID == fixture.callID)
        #expect(claim.executionState == .running)
        #expect(claim.attemptCount == 1)
        #expect(claim.startedAt == now)
    }

    @Test("a claimed job advances to the next pending stage")
    func advancesClaimedProcessingJob() async throws {
        // Given
        let fixture = try legacyStore(callStatus: "metadata")
        try await fixture.store.migrate()
        _ = try #require(
            try await fixture.store.claimNextProcessingJob(
                at: Date(timeIntervalSince1970: 1_800_000_120)
            )
        )
        let advancedAt = Date(timeIntervalSince1970: 1_800_000_180)

        // When
        let advanced = try await fixture.store.advanceProcessingJob(
            callID: fixture.callID,
            from: .awaitingParticipants,
            to: .queued,
            at: advancedAt
        )

        // Then
        #expect(advanced.stage == .queued)
        #expect(advanced.executionState == .pending)
        #expect(advanced.attemptCount == 1)
        #expect(advanced.updatedAt == advancedAt)
        #expect(advanced.startedAt == nil)
        #expect(advanced.completedAt == nil)
    }

    @Test("a processing job cannot skip required stages")
    func rejectsSkippedProcessingStage() async throws {
        // Given
        let fixture = try legacyStore(callStatus: "metadata")
        try await fixture.store.migrate()
        _ = try #require(try await fixture.store.claimNextProcessingJob())

        // When / Then
        await #expect(
            throws: CallStoreError.invalidProcessingTransition(
                from: .awaitingParticipants,
                to: .indexing
            )
        ) {
            try await fixture.store.advanceProcessingJob(
                callID: fixture.callID,
                from: .awaitingParticipants,
                to: .indexing
            )
        }
    }

    @Test("the ready stage completes a processing job")
    func readyStageCompletesProcessingJob() async throws {
        // Given
        let fixture = try legacyStore(callStatus: "metadata")
        try await fixture.store.migrate()
        var stage = ProcessingStage.awaitingParticipants
        for nextStage in [
            ProcessingStage.queued,
            .transcribing,
            .diarizing,
            .attributing,
            .indexing,
            .finalizingArtifacts,
        ] {
            _ = try #require(try await fixture.store.claimNextProcessingJob())
            _ = try await fixture.store.advanceProcessingJob(
                callID: fixture.callID,
                from: stage,
                to: nextStage
            )
            stage = nextStage
        }
        _ = try #require(try await fixture.store.claimNextProcessingJob())
        let completedAt = Date(timeIntervalSince1970: 1_800_000_300)

        // When
        let ready = try await fixture.store.advanceProcessingJob(
            callID: fixture.callID,
            from: .finalizingArtifacts,
            to: .ready,
            at: completedAt
        )

        // Then
        #expect(ready.stage == .ready)
        #expect(ready.executionState == .complete)
        #expect(ready.completedAt == completedAt)
        #expect(try await fixture.store.claimNextProcessingJob() == nil)
    }

    @Test("failing a claimed stage persists its diagnostic event")
    func failsProcessingJobWithDiagnostic() async throws {
        // Given
        let fixture = try legacyStore(callStatus: "metadata")
        try await fixture.store.migrate()
        _ = try #require(try await fixture.store.claimNextProcessingJob())
        let failedAt = Date(timeIntervalSince1970: 1_800_000_240)

        // When
        let event = try await fixture.store.failProcessingJob(
            callID: fixture.callID,
            stage: .awaitingParticipants,
            summary: "Participant selection was interrupted.",
            errorType: "CancellationError",
            details: "operation cancelled",
            stderr: nil,
            at: failedAt
        )

        // Then
        #expect(event.callID == fixture.callID)
        #expect(event.stage == .awaitingParticipants)
        #expect(event.severity == .error)
        #expect(event.createdAt == failedAt)
        #expect(try await fixture.store.processingEvents(for: fixture.callID) == [event])
        let job = try #require(try await fixture.store.processingJobs().first)
        #expect(job.executionState == .failed)
        #expect(job.latestEventID == event.id)
        #expect(try await fixture.store.call(id: fixture.callID)?.status == .failed)
    }

    @Test("a failed stage can be returned to the pending queue")
    func retriesFailedProcessingJob() async throws {
        // Given
        let store = try CallStore(path: temporaryDatabasePath())
        try await store.migrate()
        let callID = CallID(rawValue: UUID())
        try await store.createCall(.started(id: callID, at: Date(timeIntervalSince1970: 1_800_000_000)))
        try await store.updateCall(
            id: callID,
            endedAt: Date(timeIntervalSince1970: 1_800_000_060),
            audioPath: "/tmp/call.m4a",
            status: .metadata
        )
        try await store.setParticipants([], for: callID)
        _ = try #require(try await store.claimNextProcessingJob(executableOnly: true))
        _ = try await store.failProcessingJob(
            callID: callID,
            stage: .queued,
            summary: "Fixture failure"
        )

        // When
        try await store.retryProcessingJob(callID: callID)

        // Then
        let job = try #require(try await store.processingJobs().first)
        #expect(job.stage == .queued)
        #expect(job.executionState == .pending)
        #expect(try await store.call(id: callID)?.status == .metadata)
        #expect(try await store.claimNextProcessingJob(executableOnly: true)?.callID == callID)
    }

    @Test("participant upsert reuses a normalized name")
    func participantUpsertReusesNormalizedName() async throws {
        // Given
        let store = try CallStore(path: temporaryDatabasePath())
        try await store.migrate()

        // When
        let first = try await store.upsertParticipant(name: "  Alice   Smith ")
        let second = try await store.upsertParticipant(name: "alice smith")
        let participants = try await store.listParticipants()

        // Then
        #expect(first.id == second.id)
        #expect(first.name == "Alice Smith")
        #expect(participants == [first])
    }

    @Test("participant profiles can be edited without replacing call links")
    func participantProfilesRoundTripAndPreserveCallLinks() async throws {
        // Given
        let store = try CallStore(path: temporaryDatabasePath())
        try await store.migrate()
        let participant = try await store.upsertParticipant(name: "Alice Smith")
        let call = CallRecord.started(
            id: CallID(rawValue: UUID()),
            at: Date(timeIntervalSince1970: 1_800_000_000)
        )
        try await store.createCall(call)
        try await store.setParticipants([participant.id], for: call.id)

        // When
        let updated = try await store.updateParticipant(
            id: participant.id,
            name: " Alice Jones ",
            role: " Head of Operations ",
            company: " Globex ",
            email: " alice@globex.com "
        )

        // Then
        #expect(
            updated == Participant(
                id: participant.id,
                name: "Alice Jones",
                role: "Head of Operations",
                company: "Globex",
                email: "alice@globex.com"
            )
        )
        #expect(try await store.listParticipants() == [updated])
        #expect(try await store.participants(for: call.id) == [updated])
    }

    @Test("named participants are grouped by call so a name is not reused by accident")
    func namedParticipantsGroupByCall() async throws {
        let store = try CallStore(path: temporaryDatabasePath())
        try await store.migrate()
        let speakerStore = SpeakerStore(
            store: store,
            cipher: try VoiceprintCipher(keyData: Data(0..<32))
        )
        let callID = CallID(rawValue: UUID())
        let otherCallID = CallID(rawValue: UUID())
        try await store.createCall(.started(id: callID, at: Date(timeIntervalSince1970: 1_800_000_000)))
        try await store.createCall(.started(id: otherCallID, at: Date(timeIntervalSince1970: 1_800_000_600)))
        let alice = try await store.upsertParticipant(name: "Alice")
        let bob = try await store.upsertParticipant(name: "Bob")

        // One decided speaker on the first call, and one on the second call.
        let first = try await speakerStore.savePending(
            PendingSpeakerCluster(
                callID: callID,
                speakerIndex: 0,
                speakerLabel: "Speaker 1",
                cluster: SpeakerCluster(
                    id: SpeakerClusterID(rawValue: UUID()),
                    modelVersion: "model-v1",
                    embedding: [1] + Array(repeating: 0, count: 255),
                    speechDurationMilliseconds: 5_000
                ),
                createdAt: Date()
            )
        )
        _ = try await speakerStore.confirm(clusterID: first, participantID: alice.id)
        let second = try await speakerStore.savePending(
            PendingSpeakerCluster(
                callID: otherCallID,
                speakerIndex: 0,
                speakerLabel: "Speaker 1",
                cluster: SpeakerCluster(
                    id: SpeakerClusterID(rawValue: UUID()),
                    modelVersion: "model-v1",
                    embedding: [0.5] + Array(repeating: 0, count: 255),
                    speechDurationMilliseconds: 4_000
                ),
                createdAt: Date()
            )
        )
        _ = try await speakerStore.confirm(clusterID: second, participantID: bob.id)

        let grouped = try await store.namedParticipantsByCall()

        #expect(grouped[callID] == [alice.id])
        #expect(grouped[otherCallID] == [bob.id])
    }

    @Test("glossary aliases round-trip as structured values")
    func glossaryAliasesRoundTrip() async throws {
        // Given
        let store = try CallStore(path: temporaryDatabasePath())
        try await store.migrate()

        // When
        let saved = try await store.upsertGlossaryTerm(
            preferred: "ScreenCaptureKit",
            aliases: ["screen capture kit", "screen-capture-kit"]
        )
        let terms = try await store.listGlossaryTerms()

        // Then
        #expect(terms == [saved])
        #expect(terms.first?.aliases == ["screen capture kit", "screen-capture-kit"])
    }

    @Test("glossary usage counts the transcripts that mention a term")
    func glossaryUsageCountsMentions() async throws {
        // Given
        let path = temporaryDatabasePath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try CallStore(path: path)
        try await store.migrate()
        _ = try await store.upsertGlossaryTerm(preferred: "Globex", aliases: ["Globexx"])
        _ = try await store.upsertGlossaryTerm(preferred: "Geodis", aliases: [])
        for (index, text) in [
            "We ship with Globex every day.",
            "Globexx is how the meeting notes spell it.",
            "Nothing relevant here.",
        ].enumerated() {
            let callID = CallID(rawValue: UUID())
            try await store.createCall(
                .started(id: callID, at: Date(timeIntervalSince1970: 1_800_000_000 + Double(index)))
            )
            try await store.saveTranscript(
                TranscriptRecord(
                    callID: callID,
                    language: "en",
                    model: "medium",
                    text: text,
                    markdownPath: "/tmp/usage-\(index).md",
                    jsonPath: "/tmp/usage-\(index).json"
                )
            )
        }
        // The header repeats the glossary, so it must not count as the user saying a term.
        let headerOnly = CallID(rawValue: UUID())
        try await store.createCall(
            .started(id: headerOnly, at: Date(timeIntervalSince1970: 1_800_000_500))
        )
        try await store.saveTranscript(
            TranscriptRecord(
                callID: headerOnly,
                language: "en",
                model: "medium",
                text: "# Meeting Transcript\n\nParticipants: Sam\nGlossary: Geodis (also GeoDis)\n\nHello.",
                markdownPath: "/tmp/usage-header.md",
                jsonPath: "/tmp/usage-header.json"
            )
        )

        // When
        let counts = try await store.glossaryUsageCounts()

        // Then
        #expect(counts["globex"] == 2)
        #expect(counts["geodis"] == 0)
    }

    @Test("glossary usage is empty when no transcript is saved yet")
    func glossaryUsageCountsWithoutIndex() async throws {
        // Given
        let store = try CallStore(path: temporaryDatabasePath())
        try await store.migrate()
        _ = try await store.upsertGlossaryTerm(preferred: "Globex", aliases: [])

        // When
        let counts = try await store.glossaryUsageCounts()

        // Then
        #expect(counts.isEmpty)
    }

    @Test("a call retains its selected participants")
    func callRetainsSelectedParticipants() async throws {
        // Given
        let store = try CallStore(path: temporaryDatabasePath())
        try await store.migrate()
        let participant = try await store.upsertParticipant(name: "Ирина")
        let call = CallRecord.started(
            id: CallID(rawValue: UUID()),
            at: Date(timeIntervalSince1970: 1_800_000_000)
        )
        try await store.createCall(call)

        // When
        try await store.setParticipants([participant.id], for: call.id)

        // Then
        #expect(try await store.participants(for: call.id) == [participant])
    }

    @Test("every call's people are grouped by call in name order")
    func participantsAreGroupedByCall() async throws {
        // Given three people and two calls that share one of them.
        let store = try CallStore(path: temporaryDatabasePath())
        try await store.migrate()
        let zoe = try await store.upsertParticipant(name: "Zoe")
        let adam = try await store.upsertParticipant(name: "Adam")
        let sam = try await store.upsertParticipant(name: "Sam")
        let first = CallRecord.started(
            id: CallID(rawValue: UUID()),
            at: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let second = CallRecord.started(
            id: CallID(rawValue: UUID()),
            at: Date(timeIntervalSince1970: 1_800_000_600)
        )
        try await store.createCall(first)
        try await store.createCall(second)
        try await store.setParticipants([zoe.id, adam.id], for: first.id)
        try await store.setParticipants([sam.id], for: second.id)

        // When
        let grouped = try await store.participantsByCall()

        // Then the grouping agrees with the single-call query, which is the one the rest of the
        // app reads, and each call's people are in the order that query returns them.
        #expect(grouped[first.id]?.map(\.name) == ["Adam", "Zoe"])
        #expect(grouped[first.id] == (try await store.participants(for: first.id)))
        #expect(grouped[second.id]?.map(\.name) == ["Sam"])
        #expect(grouped[second.id] == (try await store.participants(for: second.id)))
    }

    @Test("recent calls include participants and expose completed transcript text")
    func recentCallsSupportTranscriptCopying() async throws {
        // Given
        let store = try CallStore(path: temporaryDatabasePath())
        try await store.migrate()
        let participant = try await store.upsertParticipant(name: "Sam")
        let older = CallRecord.started(
            id: CallID(rawValue: UUID()),
            at: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let recent = CallRecord.started(
            id: CallID(rawValue: UUID()),
            at: Date(timeIntervalSince1970: 1_800_000_120)
        )
        try await store.createCall(older)
        try await store.createCall(recent)
        try await store.updateCall(
            id: recent.id,
            endedAt: Date(timeIntervalSince1970: 1_800_000_180),
            audioPath: "/tmp/recent.m4a",
            status: .metadata
        )
        try await store.setParticipants([participant.id], for: recent.id)
        try await store.saveTranscript(
            TranscriptRecord(
                callID: recent.id,
                language: "en",
                model: "whisper-small",
                text: "**Sam**: Ship it.",
                markdownPath: "/tmp/recent.md",
                jsonPath: "/tmp/recent.json"
            )
        )

        // When
        let calls = try await store.recentCalls(limit: 1)
        let transcript = try await store.transcriptText(for: recent.id)

        // Then
        #expect(
            calls == [
                RecentCallSummary(
                    id: recent.id,
                    startedAt: recent.startedAt,
                    endedAt: Date(timeIntervalSince1970: 1_800_000_180),
                    status: .indexing,
                    participantNames: ["Sam"],
                    hasTranscript: true
                )
            ]
        )
        #expect(transcript == "**Sam**: Ship it.")
    }

    @Test("saving participants queues a finalized call for processing")
    func participantSelectionQueuesProcessing() async throws {
        // Given
        let store = try CallStore(path: temporaryDatabasePath())
        try await store.migrate()
        let participant = try await store.upsertParticipant(name: "Dana")
        let call = CallRecord.started(
            id: CallID(rawValue: UUID()),
            at: Date(timeIntervalSince1970: 1_800_000_000)
        )
        try await store.createCall(call)
        try await store.updateCall(
            id: call.id,
            endedAt: Date(timeIntervalSince1970: 1_800_000_060),
            audioPath: "/tmp/call.m4a",
            status: .metadata
        )

        // When
        try await store.setParticipants([participant.id], for: call.id)

        // Then
        let job = try #require(try await store.processingJobs().first)
        #expect(job.stage == .queued)
        #expect(job.executionState == .pending)
    }

    @Test("late participant saves do not reset a claimed processing job")
    func participantSelectionPreservesClaimedJob() async throws {
        // Given
        let store = try CallStore(path: temporaryDatabasePath())
        try await store.migrate()
        let participant = try await store.upsertParticipant(name: "Sam")
        let call = CallRecord.started(
            id: CallID(rawValue: UUID()),
            at: Date(timeIntervalSince1970: 1_800_000_000)
        )
        try await store.createCall(call)
        try await store.updateCall(
            id: call.id,
            endedAt: Date(timeIntervalSince1970: 1_800_000_060),
            audioPath: "/tmp/call.m4a",
            status: .metadata
        )
        let claimedAt = Date(timeIntervalSince1970: 1_800_000_120)
        _ = try #require(try await store.claimNextProcessingJob(at: claimedAt))

        // When
        try await store.setParticipants([participant.id], for: call.id)

        // Then
        let job = try #require(try await store.processingJobs().first)
        #expect(job.stage == .awaitingParticipants)
        #expect(job.executionState == .running)
        #expect(job.startedAt == claimedAt)
    }

    @Test("participant assignment survives a temporary database write lock")
    func participantAssignmentRetriesTemporaryWriteLock() async throws {
        // Given
        let path = temporaryDatabasePath()
        let store = try CallStore(path: path)
        try await store.migrate()
        let participant = try await store.upsertParticipant(name: "Adi")
        let call = CallRecord.started(
            id: CallID(rawValue: UUID()),
            at: Date(timeIntervalSince1970: 1_800_000_000)
        )
        try await store.createCall(call)
        let blockerDatabase = try Database(path)
        let blockerConnection = try blockerDatabase.connect()
        let blocker = try blockerConnection.transaction()
        _ = try blocker.execute(
            "UPDATE calls SET status = status WHERE id = ?",
            [call.id.rawValue.uuidString]
        )

        // When
        let assignment = Task {
            try await store.setParticipants([participant.id], for: call.id)
        }
        try await Task.sleep(for: .seconds(3.5))
        blocker.commit()
        try await assignment.value

        // Then
        #expect(try await store.participants(for: call.id) == [participant])
    }

    @Test("participant assignment preserves MCP UUID casing")
    func participantAssignmentUsesStoredIdentifierCasing() async throws {
        // Given
        let path = temporaryDatabasePath()
        do {
            let seedStore = try CallStore(path: path)
            try await seedStore.migrate()
        }
        let participantID = UUID()
        let database = try Database(path)
        let connection = try database.connect()
        _ = try connection.execute(
            "INSERT INTO participants (id, name, normalized_name) VALUES (?, ?, ?)",
            [participantID.uuidString.lowercased(), "Sam", "sam"]
        )
        let store = try CallStore(path: path)
        try await store.migrate()
        let participant = try #require(try await store.listParticipants().first)
        let call = CallRecord.started(
            id: CallID(rawValue: UUID()),
            at: Date(timeIntervalSince1970: 1_800_000_000)
        )
        try await store.createCall(call)

        // When
        try await store.setParticipants([participant.id], for: call.id)

        // Then
        #expect(try await store.participants(for: call.id) == [participant])
    }

    @Test("saving a transcript queues durable indexing work")
    func transcriptCreatesPendingIndexJob() async throws {
        // Given
        let store = try CallStore(path: temporaryDatabasePath())
        try await store.migrate()
        let callID = CallID(rawValue: UUID())
        try await store.createCall(.started(id: callID, at: Date(timeIntervalSince1970: 1_800_000_000)))
        let transcript = TranscriptRecord(
            callID: callID,
            language: "ru",
            model: "small",
            text: "Обсудили план запуска.",
            markdownPath: "/tmp/transcript.md",
            jsonPath: "/tmp/transcript.json"
        )

        // When
        try await store.saveTranscript(transcript)

        // Then
        #expect(try await store.pendingIndexCallIDs() == [callID])
        let processingJob = try #require(try await store.processingJobs().first)
        #expect(processingJob.callID == callID)
        #expect(processingJob.stage == .indexing)
        #expect(processingJob.executionState == .pending)
        #expect(try await store.call(id: callID)?.status == .indexing)
    }

    @Test("processor transcript persistence preserves its claimed stage")
    func processorTranscriptPersistencePreservesClaim() async throws {
        // Given
        let store = try CallStore(path: temporaryDatabasePath())
        try await store.migrate()
        let callID = CallID(rawValue: UUID())
        try await store.createCall(.started(id: callID, at: Date(timeIntervalSince1970: 1_800_000_000)))
        try await store.updateCall(
            id: callID,
            endedAt: Date(timeIntervalSince1970: 1_800_000_060),
            audioPath: "/tmp/call.m4a",
            status: .metadata
        )
        try await store.setParticipants([], for: callID)
        _ = try #require(try await store.claimNextProcessingJob(executableOnly: true))
        _ = try await store.advanceProcessingJob(callID: callID, from: .queued, to: .transcribing)
        _ = try #require(try await store.claimNextProcessingJob(executableOnly: true))

        // When
        try await store.saveTranscript(
            TranscriptRecord(
                callID: callID,
                language: "en",
                model: "medium",
                text: "Ready to index.",
                markdownPath: "/tmp/transcript.md",
                jsonPath: "/tmp/transcript.json"
            ),
            queueIndexing: false
        )

        // Then
        let job = try #require(try await store.processingJobs().first)
        #expect(job.stage == .transcribing)
        #expect(job.executionState == .running)
        #expect(try await store.pendingIndexCallIDs() == [callID])
        #expect(try await store.call(id: callID)?.status == .transcribing)
    }

    @Test("a stopped transcription goes back to the queue and the call says it is waiting")
    func stoppedTranscriptionWaitsForTheUser() async throws {
        // Given a call whose transcription is the claimed stage
        let store = try CallStore(path: temporaryDatabasePath())
        try await store.migrate()
        let callID = CallID(rawValue: UUID())
        try await store.createCall(.started(id: callID, at: Date(timeIntervalSince1970: 1_800_000_000)))
        try await store.updateCall(
            id: callID,
            endedAt: Date(timeIntervalSince1970: 1_800_000_060),
            audioPath: "/tmp/call.m4a",
            status: .metadata
        )
        try await store.setParticipants([], for: callID)
        _ = try #require(try await store.claimNextProcessingJob(executableOnly: true))
        _ = try await store.advanceProcessingJob(callID: callID, from: .queued, to: .transcribing)
        _ = try #require(try await store.claimNextProcessingJob(executableOnly: true))

        // When the user stops it
        try await store.stopProcessingJob(callID: callID, stage: .transcribing)

        // Then the claim is free again, the stage is kept for the retry, and the row that read
        // "Transcribing" says the call is waiting.
        let job = try #require(try await store.processingJobs().first)
        #expect(job.stage == .transcribing)
        #expect(job.executionState == .pending)
        #expect(try await store.call(id: callID)?.status == .metadata)
    }

    @Test("a call remembers that its other side was never captured")
    func systemAudioStateIsStored() async throws {
        // Given a call with no measurement yet
        let store = try CallStore(path: temporaryDatabasePath())
        try await store.migrate()
        let callID = CallID(rawValue: UUID())
        try await store.createCall(.started(id: callID, at: Date(timeIntervalSince1970: 1_800_000_000)))

        // Then it reads unknown rather than fine
        #expect(try await store.recentCalls(limit: 5).first?.systemAudio == nil)

        // When the measurement says the other side was never captured
        try await store.setSystemAudio(.missing, for: callID)

        // Then the row carries it
        #expect(try await store.recentCalls(limit: 5).first?.systemAudio == .missing)
        #expect(try await store.callSummaries(ids: [callID])[callID]?.systemAudio == .missing)
    }

    @Test("a stop after transcription leaves the call's own wording alone")
    func stopAfterTranscriptionKeepsItsWording() async throws {
        // Given a call whose speaker stage is the claimed one
        let store = try CallStore(path: temporaryDatabasePath())
        try await store.migrate()
        let callID = CallID(rawValue: UUID())
        try await store.createCall(.started(id: callID, at: Date(timeIntervalSince1970: 1_800_000_000)))
        try await store.updateCall(
            id: callID,
            endedAt: Date(timeIntervalSince1970: 1_800_000_060),
            audioPath: "/tmp/call.m4a",
            status: .metadata
        )
        try await store.setParticipants([], for: callID)
        _ = try #require(try await store.claimNextProcessingJob(executableOnly: true))
        _ = try await store.advanceProcessingJob(callID: callID, from: .queued, to: .transcribing)
        _ = try #require(try await store.claimNextProcessingJob(executableOnly: true))
        _ = try await store.advanceProcessingJob(callID: callID, from: .transcribing, to: .diarizing)
        _ = try #require(try await store.claimNextProcessingJob(executableOnly: true))

        // When the user stops the speaker stage
        try await store.stopProcessingJob(callID: callID, stage: .diarizing)

        // Then the transcript is already written, so the call keeps the wording that says so
        // instead of claiming it is waiting to be transcribed.
        let job = try #require(try await store.processingJobs().first)
        #expect(job.stage == .diarizing)
        #expect(job.executionState == .pending)
        #expect(try await store.call(id: callID)?.status == .transcribing)
    }

    @Test("indexing done outside the pipeline closes the job it was queued for")
    func settlesIndexingDoneOutsideThePipeline() async throws {
        // Given a call whose saved transcript queued an indexing job
        let store = try CallStore(path: temporaryDatabasePath())
        try await store.migrate()
        let callID = CallID(rawValue: UUID())
        try await store.createCall(.started(id: callID, at: Date(timeIntervalSince1970: 1_800_000_000)))
        try await store.saveTranscript(
            TranscriptRecord(
                callID: callID,
                language: "ru",
                model: "small",
                text: "Обсудили план запуска.",
                markdownPath: "/tmp/transcript.md",
                jsonPath: "/tmp/transcript.json"
            )
        )
        #expect(try await store.processingJobs().first?.executionState == .pending)

        // When the indexing is done by a repair rather than by the pipeline
        let settled = try await store.settleIndexedProcessingJob(callID: callID)

        // Then the queue no longer reports work that is already done
        #expect(settled)
        let job = try #require(try await store.processingJobs().first)
        #expect(job.stage == .ready)
        #expect(job.executionState == .complete)
        #expect(try await store.settleIndexedProcessingJob(callID: callID) == false)
    }

    @Test("a claimed indexing job is never settled by another writer")
    func doesNotSettleAClaimedJob() async throws {
        // Given a job the pipeline has already taken
        let store = try CallStore(path: temporaryDatabasePath())
        try await store.migrate()
        let callID = CallID(rawValue: UUID())
        try await store.createCall(.started(id: callID, at: Date(timeIntervalSince1970: 1_800_000_000)))
        try await store.saveTranscript(
            TranscriptRecord(
                callID: callID,
                language: "en",
                model: "small",
                text: "Ready to index.",
                markdownPath: "/tmp/transcript.md",
                jsonPath: "/tmp/transcript.json"
            )
        )
        _ = try #require(try await store.claimNextProcessingJob(executableOnly: true))

        // When
        let settled = try await store.settleIndexedProcessingJob(callID: callID)

        // Then the running job is left alone, because another writer owns it
        #expect(settled == false)
        #expect(try await store.processingJobs().first?.executionState == .running)
    }

    @Test("a library-wide settle closes only the jobs whose index is built")
    func settlesOnlyBuiltIndexesAcrossTheLibrary() async throws {
        // Given one call that owes an indexing job and one that does not
        let path = temporaryDatabasePath()
        let store = try CallStore(path: path)
        try await store.migrate()
        let indexed = CallID(rawValue: UUID())
        let unindexed = CallID(rawValue: UUID())
        for callID in [indexed, unindexed] {
            try await store.createCall(
                .started(id: callID, at: Date(timeIntervalSince1970: 1_800_000_000))
            )
            try await store.saveTranscript(
                TranscriptRecord(
                    callID: callID,
                    language: "en",
                    model: "small",
                    text: "Ready to index.",
                    markdownPath: "/tmp/\(callID.rawValue.uuidString).md",
                    jsonPath: "/tmp/\(callID.rawValue.uuidString).json"
                )
            )
        }
        // The first call's index has been built by a repair; the second one has not. The indexer
        // writes this row itself, and the test writes the same row rather than running embeddings.
        let connection = try Database(path).connect()
        _ = try connection.execute(
            "UPDATE index_jobs SET status = 'ready', error = NULL WHERE call_id = ?",
            [indexed.rawValue.uuidString]
        )

        // When
        let settled = try await store.settleCompletedIndexingJobs()

        // Then only the finished one is closed
        #expect(settled == 1)
        let jobs = try await store.processingJobs()
        #expect(jobs.first { $0.callID == indexed }?.executionState == .complete)
        #expect(jobs.first { $0.callID == unindexed }?.executionState == .pending)
    }

    @Test("finalized capture keeps its audio path and metadata status")
    func finalizedCapturePersistsAudioPath() async throws {
        // Given
        let store = try CallStore(path: temporaryDatabasePath())
        try await store.migrate()
        let call = CallRecord.started(
            id: CallID(rawValue: UUID()),
            at: Date(timeIntervalSince1970: 1_800_000_000)
        )
        try await store.createCall(call)

        // When
        try await store.updateCall(
            id: call.id,
            endedAt: Date(timeIntervalSince1970: 1_800_000_060),
            audioPath: "/tmp/call.m4a",
            status: .metadata
        )

        // Then
        let updated = try await store.call(id: call.id)
        #expect(updated?.endedAt == Date(timeIntervalSince1970: 1_800_000_060))
        #expect(updated?.audioPath == "/tmp/call.m4a")
        #expect(updated?.status == .metadata)
        let processingJob = try #require(try await store.processingJobs().first)
        #expect(processingJob.callID == call.id)
        #expect(processingJob.stage == .awaitingParticipants)
        #expect(processingJob.executionState == .pending)
    }

    @Test("finalized capture queues processing without participant selection")
    func finalizedCaptureQueuesImmediately() async throws {
        // Given
        let store = try CallStore(path: temporaryDatabasePath())
        try await store.migrate()
        let call = CallRecord.started(
            id: CallID(rawValue: UUID()),
            at: Date(timeIntervalSince1970: 1_800_000_000)
        )
        try await store.createCall(call)
        let endedAt = Date(timeIntervalSince1970: 1_800_000_060)

        // When
        try await store.finalizeAndQueue(
            id: call.id,
            endedAt: endedAt,
            audioPath: "/tmp/call.m4a"
        )

        // Then
        let stored = try #require(try await store.call(id: call.id))
        #expect(stored.endedAt == endedAt)
        #expect(stored.audioPath == "/tmp/call.m4a")
        #expect(stored.status == .metadata)
        let job = try #require(try await store.processingJobs().first)
        #expect(job.callID == call.id)
        #expect(job.stage == .queued)
        #expect(job.executionState == .pending)
    }

    @Test("replayed finalization does not reset processing that already advanced")
    func replayedFinalizationPreservesAdvancedProcessing() async throws {
        // Given
        let store = try CallStore(path: temporaryDatabasePath())
        try await store.migrate()
        let call = CallRecord.started(
            id: CallID(rawValue: UUID()),
            at: Date(timeIntervalSince1970: 1_800_000_000)
        )
        try await store.createCall(call)
        let firstEnd = Date(timeIntervalSince1970: 1_800_000_060)
        try await store.finalizeAndQueue(
            id: call.id,
            endedAt: firstEnd,
            audioPath: "/tmp/call.m4a"
        )
        _ = try #require(try await store.claimNextProcessingJob(executableOnly: true))
        _ = try await store.advanceProcessingJob(
            callID: call.id,
            from: .queued,
            to: .transcribing
        )

        // When
        try await store.finalizeAndQueue(
            id: call.id,
            endedAt: Date(timeIntervalSince1970: 1_800_000_120),
            audioPath: "/tmp/call.m4a"
        )

        // Then
        let stored = try #require(try await store.call(id: call.id))
        #expect(stored.endedAt == firstEnd)
        #expect(stored.status == .transcribing)
        let job = try #require(try await store.processingJobs().first)
        #expect(job.stage == .transcribing)
        #expect(job.executionState == .pending)
    }

    @Test("replayed finalization does not release a claimed queue job")
    func replayedFinalizationPreservesClaimedQueueJob() async throws {
        // Given
        let store = try CallStore(path: temporaryDatabasePath())
        try await store.migrate()
        let call = CallRecord.started(
            id: CallID(rawValue: UUID()),
            at: Date(timeIntervalSince1970: 1_800_000_000)
        )
        try await store.createCall(call)
        let endedAt = Date(timeIntervalSince1970: 1_800_000_060)
        try await store.finalizeAndQueue(
            id: call.id,
            endedAt: endedAt,
            audioPath: "/tmp/call.m4a"
        )
        let claimedAt = Date(timeIntervalSince1970: 1_800_000_090)
        _ = try #require(
            try await store.claimNextProcessingJob(
                at: claimedAt,
                executableOnly: true
            )
        )

        // When
        try await store.finalizeAndQueue(
            id: call.id,
            endedAt: Date(timeIntervalSince1970: 1_800_000_120),
            audioPath: "/tmp/call.m4a"
        )

        // Then
        let job = try #require(try await store.processingJobs().first)
        #expect(job.stage == .queued)
        #expect(job.executionState == .running)
        #expect(job.attemptCount == 1)
        #expect(job.startedAt == claimedAt)
    }

    @Test("capture finalization reports a call removed during its update")
    func finalizedCaptureRejectsConcurrentDeletion() async throws {
        // Given
        let path = temporaryDatabasePath()
        let store = try CallStore(path: path)
        try await store.migrate()
        let call = CallRecord.started(
            id: CallID(rawValue: UUID()),
            at: Date(timeIntervalSince1970: 1_800_000_000)
        )
        try await store.createCall(call)
        do {
            let database = try Database(path)
            let connection = try database.connect()
            try connection.executeBatch("""
                CREATE TRIGGER remove_call_before_update
                BEFORE UPDATE ON calls
                BEGIN
                    DELETE FROM calls WHERE id = OLD.id;
                END;
                """)
        }

        // When / Then
        await #expect(throws: CallStoreError.callNotFound(call.id)) {
            try await store.updateCall(
                id: call.id,
                endedAt: Date(timeIntervalSince1970: 1_800_000_060),
                audioPath: "/tmp/call.m4a",
                status: .metadata
            )
        }
    }

    @Test("the latest finalized call can resume participant selection after relaunch")
    func latestMetadataCallRestoresParticipantSelection() async throws {
        // Given
        let store = try CallStore(path: temporaryDatabasePath())
        try await store.migrate()
        let older = CallRecord.started(
            id: CallID(rawValue: UUID()),
            at: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let newer = CallRecord.started(
            id: CallID(rawValue: UUID()),
            at: Date(timeIntervalSince1970: 1_800_000_100)
        )
        try await store.createCall(older)
        try await store.createCall(newer)
        try await store.updateCall(
            id: older.id,
            endedAt: Date(timeIntervalSince1970: 1_800_000_060),
            audioPath: "/tmp/older.m4a",
            status: .metadata
        )
        try await store.updateCall(
            id: newer.id,
            endedAt: Date(timeIntervalSince1970: 1_800_000_180),
            audioPath: "/tmp/newer.m4a",
            status: .metadata
        )

        // When
        let pending = try await store.latestMetadataCall()
        let expected = try await store.call(id: newer.id)

        // Then
        #expect(pending == expected)
    }

    @Test("startup queues legacy finalized calls without participant selection")
    func startupQueuesLegacyFinalizedCalls() async throws {
        // Given
        let store = try CallStore(path: temporaryDatabasePath())
        try await store.migrate()
        let call = CallRecord.started(
            id: CallID(rawValue: UUID()),
            at: Date(timeIntervalSince1970: 1_800_000_000)
        )
        try await store.createCall(call)
        try await store.updateCall(
            id: call.id,
            endedAt: Date(timeIntervalSince1970: 1_800_000_060),
            audioPath: "/tmp/legacy-call.m4a",
            status: .metadata
        )

        // When
        let queuedCount = try await store.queuePendingParticipantJobs()

        // Then
        #expect(queuedCount == 1)
        let job = try #require(try await store.processingJobs().first)
        #expect(job.stage == .queued)
        #expect(job.executionState == .pending)
    }

    @Test("failed indexing jobs with ready index_jobs reconcile atomically to finalizingArtifacts")
    func reconcilesFailedIndexingJobWithReadyIndexJob() async throws {
        // Given: the indexer committed index_jobs=ready and calls=ready, then the
        // stale status guard failed the processing job at stage indexing.
        let store = try CallStore(path: temporaryDatabasePath())
        try await store.migrate()
        let callID = CallID(rawValue: UUID())
        try await store.createCall(.started(id: callID, at: Date(timeIntervalSince1970: 1_800_000_000)))
        try await store.finalizeAndQueue(
            id: callID,
            endedAt: Date(timeIntervalSince1970: 1_800_000_060),
            audioPath: "/tmp/call.m4a"
        )
        try await store.saveTranscript(
            TranscriptRecord(
                callID: callID,
                language: "en",
                model: "small",
                text: "Already indexed once.",
                markdownPath: "/tmp/transcript.md",
                jsonPath: "/tmp/transcript.json"
            ),
            queueIndexing: false
        )
        _ = try #require(try await store.claimNextProcessingJob(executableOnly: true))
        _ = try await store.advanceProcessingJob(callID: callID, from: .queued, to: .transcribing)
        _ = try #require(try await store.claimNextProcessingJob(executableOnly: true))
        _ = try await store.advanceProcessingJob(callID: callID, from: .transcribing, to: .diarizing)
        _ = try #require(try await store.claimNextProcessingJob(executableOnly: true))
        _ = try await store.advanceProcessingJob(callID: callID, from: .diarizing, to: .attributing)
        _ = try #require(try await store.claimNextProcessingJob(executableOnly: true))
        _ = try await store.advanceProcessingJob(callID: callID, from: .attributing, to: .indexing)
        _ = try #require(try await store.claimNextProcessingJob(executableOnly: true))
        let event = try await store.failProcessingJob(
            callID: callID,
            stage: .indexing,
            summary: "Stale status guard failure.",
            errorType: "BackgroundProcessingError",
            details: "indexingIncomplete",
            at: Date(timeIntervalSince1970: 1_800_000_240)
        )
        let failedJob = try #require(try await store.processingJobs().first)
        #expect(failedJob.stage == .indexing)
        #expect(failedJob.executionState == .failed)
        #expect(try await store.indexIsReady(for: callID) == false)
        _ = try await store.markIndexReady(for: callID)
        #expect(try await store.indexIsReady(for: callID))
        let reconciledAt = Date(timeIntervalSince1970: 1_800_000_300)

        // When: startup reconciliation runs.
        let affected = try await store.reconcileFailedIndexingJobs(at: reconciledAt)

        // Then: the call and job resume finalizingArtifacts atomically, preserving
        // source/transcript/chunks, attempt counts, and prior events.
        #expect(affected == 1)
        #expect(try await store.call(id: callID)?.status == .ready)
        let job = try #require(try await store.processingJobs().first)
        #expect(job.stage == .finalizingArtifacts)
        #expect(job.executionState == .pending)
        #expect(job.attemptCount == failedJob.attemptCount)
        #expect(job.createdAt == failedJob.createdAt)
        #expect(job.startedAt == nil)
        #expect(job.completedAt == nil)
        #expect(job.latestEventID == event.id)
        #expect(job.updatedAt == reconciledAt)
        #expect(try await store.transcriptText(for: callID) == "Already indexed once.")
        #expect(try await store.pendingIndexCallIDs().isEmpty)
        #expect(try await store.processingEvents(for: callID) == [event])
        let claim = try await store.claimNextProcessingJob(executableOnly: true)
        #expect(claim?.callID == callID)
        #expect(claim?.stage == .finalizingArtifacts)

        // And reconciliation is idempotent.
        let secondRun = try await store.reconcileFailedIndexingJobs(at: reconciledAt)
        #expect(secondRun == 0)
        #expect(try await store.call(id: callID)?.status == .ready)
        let afterSecondRun = try await store.processingJobs().first
        #expect(afterSecondRun?.stage == .finalizingArtifacts)
        #expect(afterSecondRun?.executionState == .running)
    }

    @Test("reconciliation only touches failed indexing jobs with ready index_jobs")
    func reconciliationIsSelective() async throws {
        // Given: a failed indexing job whose index_jobs row is NOT ready, and a
        // healthy queued job that must be untouched.
        let store = try CallStore(path: temporaryDatabasePath())
        try await store.migrate()
        let stuckCall = CallID(rawValue: UUID())
        try await store.createCall(.started(id: stuckCall, at: Date(timeIntervalSince1970: 1_800_000_000)))
        try await store.finalizeAndQueue(
            id: stuckCall,
            endedAt: Date(timeIntervalSince1970: 1_800_000_060),
            audioPath: "/tmp/stuck.m4a"
        )
        try await store.saveTranscript(
            TranscriptRecord(
                callID: stuckCall,
                language: "en",
                model: "small",
                text: "Index genuinely failed.",
                markdownPath: "/tmp/stuck.md",
                jsonPath: "/tmp/stuck.json"
            ),
            queueIndexing: false
        )
        _ = try #require(try await store.claimNextProcessingJob(executableOnly: true))
        _ = try await store.advanceProcessingJob(callID: stuckCall, from: .queued, to: .transcribing)
        _ = try #require(try await store.claimNextProcessingJob(executableOnly: true))
        _ = try await store.advanceProcessingJob(callID: stuckCall, from: .transcribing, to: .diarizing)
        _ = try #require(try await store.claimNextProcessingJob(executableOnly: true))
        _ = try await store.advanceProcessingJob(callID: stuckCall, from: .diarizing, to: .attributing)
        _ = try #require(try await store.claimNextProcessingJob(executableOnly: true))
        _ = try await store.advanceProcessingJob(callID: stuckCall, from: .attributing, to: .indexing)
        _ = try #require(try await store.claimNextProcessingJob(executableOnly: true))
        _ = try await store.failProcessingJob(
            callID: stuckCall,
            stage: .indexing,
            summary: "Genuine indexing failure."
        )
        let healthyCall = CallID(rawValue: UUID())
        try await store.createCall(.started(id: healthyCall, at: Date(timeIntervalSince1970: 1_800_000_120)))
        try await store.finalizeAndQueue(
            id: healthyCall,
            endedAt: Date(timeIntervalSince1970: 1_800_000_180),
            audioPath: "/tmp/healthy.m4a"
        )

        // When
        let affected = try await store.reconcileFailedIndexingJobs(
            at: Date(timeIntervalSince1970: 1_800_000_300)
        )

        // Then
        #expect(affected == 0)
        let stuckJob = try #require(try await store.processingJobs().first {
            $0.callID == stuckCall
        })
        #expect(stuckJob.stage == .indexing)
        #expect(stuckJob.executionState == .failed)
        #expect(try await store.call(id: stuckCall)?.status == .failed)
        let healthyJob = try #require(try await store.processingJobs().first {
            $0.callID == healthyCall
        })
        #expect(healthyJob.stage == .queued)
        #expect(healthyJob.executionState == .pending)
    }

    @Test("participant assignment rejects an unknown call")
    func participantAssignmentRejectsUnknownCall() async throws {
        // Given
        let store = try CallStore(path: temporaryDatabasePath())
        try await store.migrate()
        let participant = try await store.upsertParticipant(name: "Alex")

        // When / Then
        await #expect(throws: CallStoreError.self) {
            try await store.setParticipants(
                [participant.id],
                for: CallID(rawValue: UUID())
            )
        }
    }

    @Test("participant editing of a call preserves completed and running processing")
    func postCallParticipantEditPreservesProcessingState() async throws {
        // Given: one completed call and one call mid-processing.
        let store = try CallStore(path: temporaryDatabasePath())
        try await store.migrate()
        let alice = try await store.upsertParticipant(name: "Alice")
        let bob = try await store.upsertParticipant(name: "Bob")
        let completed = CallID(rawValue: UUID())
        let running = CallID(rawValue: UUID())
        for (index, callID) in [completed, running].enumerated() {
            try await store.createCall(
                .started(
                    id: callID,
                    at: Date(timeIntervalSince1970: 1_800_000_000 + Double(index * 100))
                )
            )
            try await store.updateCall(
                id: callID,
                endedAt: Date(timeIntervalSince1970: 1_800_000_060),
                audioPath: "/tmp/call.m4a",
                status: .metadata
            )
            try await store.setParticipants([alice.id], for: callID)
        }
        var stage = ProcessingStage.queued
        for nextStage in [
            ProcessingStage.transcribing,
            .diarizing,
            .attributing,
            .indexing,
            .finalizingArtifacts,
            .ready,
        ] {
            _ = try #require(
                try await store.claimNextProcessingJob(executableOnly: true)
            )
            _ = try await store.advanceProcessingJob(
                callID: completed,
                from: stage,
                to: nextStage
            )
            stage = nextStage
        }
        _ = try #require(try await store.claimNextProcessingJob(executableOnly: true))
        _ = try await store.advanceProcessingJob(
            callID: running,
            from: .queued,
            to: .transcribing
        )
        _ = try #require(try await store.claimNextProcessingJob(executableOnly: true))

        // When: participants are edited on both calls after the fact.
        try await store.setParticipants([alice.id, bob.id], for: completed)
        try await store.setParticipants([alice.id, bob.id], for: running)

        // Then: both calls keep their processing state and only their own
        // participant links change.
        let completedJob = try #require(
            try await store.processingJobs().first { $0.callID == completed }
        )
        #expect(completedJob.stage == .ready)
        #expect(completedJob.executionState == .complete)
        let runningJob = try #require(
            try await store.processingJobs().first { $0.callID == running }
        )
        #expect(runningJob.stage == .transcribing)
        #expect(runningJob.executionState == .running)
        #expect(try await store.call(id: completed)?.status == .ready)
        #expect(try await store.call(id: running)?.status == .transcribing)
        #expect(try await store.participants(for: completed).map(\.id) == [alice.id, bob.id])
        #expect(try await store.participants(for: running).map(\.id) == [alice.id, bob.id])
    }

    private func temporaryDatabasePath() -> String {
        FileManager.default.temporaryDirectory
            .appending(path: "call-recorder-tests-\(UUID().uuidString).db")
            .path
    }

    private func legacyStore(
        callStatus: String,
        indexStatus: String? = nil,
        includeOrphanIndexJob: Bool = false
    ) throws -> (store: CallStore, callID: CallID, path: String) {
        let path = temporaryDatabasePath()
        let callID = CallID(rawValue: UUID())
        do {
            let database = try Database(path)
            let connection = try database.connect()
            try connection.executeBatch("""
                PRAGMA foreign_keys = OFF;
                CREATE TABLE calls (
                    id TEXT PRIMARY KEY,
                    started_at REAL NOT NULL,
                    ended_at REAL,
                    audio_path TEXT,
                    status TEXT NOT NULL CHECK(status IN ('recording','metadata','transcribing','indexing','ready','failed'))
                );
                CREATE TABLE index_jobs (
                    call_id TEXT PRIMARY KEY REFERENCES calls(id) ON DELETE CASCADE,
                    status TEXT NOT NULL CHECK(status IN ('pending','running','ready','failed')),
                    error TEXT
                );
                PRAGMA user_version = 2;
                """)
            _ = try connection.execute(
                "INSERT INTO calls (id, started_at, ended_at, audio_path, status) VALUES (?, ?, ?, ?, ?)",
                [callID.rawValue.uuidString, 1_800_000_000.0, 1_800_000_060.0, "/tmp/call.m4a", callStatus]
            )
            if let indexStatus {
                _ = try connection.execute(
                    "INSERT INTO index_jobs (call_id, status, error) VALUES (?, ?, NULL)",
                    [callID.rawValue.uuidString, indexStatus]
                )
            }
            if includeOrphanIndexJob {
                _ = try connection.execute(
                    "INSERT INTO index_jobs (call_id, status, error) VALUES (?, 'pending', NULL)",
                    [UUID().uuidString]
                )
            }
        }
        return (try CallStore(path: path), callID, path)
    }

    @Test("a launch finds the recordings an earlier launch left open")
    func reportsInterruptedRecordings() async throws {
        // Given: one open recording, one finished call, and one failed call.
        let path = temporaryDatabasePath()
        let store = try CallStore(path: path)
        try await store.migrate()
        let openCall = CallID(rawValue: UUID())
        let finishedCall = CallID(rawValue: UUID())
        let failedCall = CallID(rawValue: UUID())
        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        try await store.createCall(.started(id: openCall, at: startedAt))
        try await store.createCall(.started(id: finishedCall, at: startedAt.addingTimeInterval(-600)))
        try await store.updateCall(
            id: finishedCall,
            endedAt: startedAt.addingTimeInterval(-540),
            audioPath: "/tmp/finished.m4a",
            status: .ready
        )
        try await store.createCall(.started(id: failedCall, at: startedAt.addingTimeInterval(-1200)))
        // The other two statuses are set directly: no store call leaves a saved call at failed
        // without also writing a job, and this test is about what launch reads.
        let connection = try Database(path).connect()
        _ = try connection.execute(
            "UPDATE calls SET status = 'failed' WHERE id = ?",
            [failedCall.rawValue.uuidString]
        )

        // When
        let interrupted = try await store.interruptedRecordings()

        // Then: only the open recording is reported, with the time it started.
        #expect(interrupted == [
            CallStore.InterruptedRecording(callID: openCall, startedAt: startedAt),
        ])

        // And once it is closed out it is no longer reported, so a second launch does nothing.
        try await store.deleteCall(openCall)
        #expect(try await store.interruptedRecordings().isEmpty)

        // And the failed call is never reported, so a retryable failure is not swept up by this.
        #expect(try await store.call(id: failedCall)?.status == .failed)
    }

    @Test("a job list can be shown with the calls it belongs to")
    func summarizesNamedCalls() async throws {
        // Given: two calls, one with two participants and one with none, plus an unknown id.
        let store = try CallStore(path: temporaryDatabasePath())
        try await store.migrate()
        let withPeople = CallID(rawValue: UUID())
        let alone = CallID(rawValue: UUID())
        let missing = CallID(rawValue: UUID())
        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        try await store.createCall(.started(id: withPeople, at: startedAt))
        try await store.createCall(.started(id: alone, at: startedAt.addingTimeInterval(-3_600)))
        let alice = try await store.upsertParticipant(name: "Alice")
        let bob = try await store.upsertParticipant(name: "Bob")
        try await store.setParticipants([alice.id, bob.id], for: withPeople)

        // When
        let summaries = try await store.callSummaries(ids: [withPeople, alone, missing])

        // Then: each known call carries its own start time and its own people, in name order, and
        // an id that no longer exists is simply absent rather than a row of empty values.
        #expect(summaries.count == 2)
        #expect(summaries[withPeople]?.startedAt == startedAt)
        #expect(summaries[withPeople]?.participantNames == ["Alice", "Bob"])
        #expect(summaries[alone]?.startedAt == startedAt.addingTimeInterval(-3_600))
        #expect(summaries[alone]?.participantNames.isEmpty == true)
        #expect(summaries[missing] == nil)
        #expect(try await store.callSummaries(ids: []).isEmpty)
    }
}
