import Foundation
import Libsql
import Darwin

public enum CallStoreError: Error, Equatable {
    case invalidName
    case callNotFound(CallID)
    case participantNotFound(ParticipantID)
    case speakerClusterNotFound(SpeakerClusterID)
    case speakerReviewRequestNotFound(UUID)
    case invalidStoredIdentifier(String)
    case invalidStoredAliases
    case invalidStoredStatus(String)
    case invalidStoredValue
    case foreignKeyIntegrityFailed
    case migrationStepFailed(Int, String)
    case processingJobNotClaimed(CallID)
    case invalidProcessingTransition(from: ProcessingStage, to: ProcessingStage)
    case backupIntegrityFailed(String)
    case invalidLimit
}

public actor CallStore {
    private let database: Database
    private var connection: Connection

    public init(path: String) throws {
        try FileManager.default.createDirectory(
            at: URL(filePath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        database = try Database(path)
        connection = try database.connect()
    }

    public func migrate() throws {
        try Self.ensureForeignKeyIntegrity(connection)
        try connection.executeBatch(Self.connectionPragmas)
        let existingVersion = try schemaVersion()
        try connection.executeBatch(Self.baseSchema)
        if existingVersion < 1 {
            try connection.executeBatch("PRAGMA user_version = 1;")
        }
        try migrateProcessingSchema()
        try migrateParticipantProfileSchema()
        try migrateSpeakerIdentitySchema()
        try migrateSpeakerReviewSchema()
        try migrateSpeakerReviewRequestSchema()
        try migrateSpeakerReopenSchema()
        try migrateSpeakerLineOverrideSchema()
        try migrateSpeakerLineRequestSchema()
        try migrateSystemAudioSchema()
    }

    public func schemaVersion() throws -> Int {
        guard let row = try connection.query("PRAGMA user_version").next() else { return 0 }
        return try row.getInt(0)
    }

    public func upsertParticipant(name: String) async throws -> Participant {
        let displayName = try Self.cleanedName(name)
        let normalizedName = Self.normalizedName(displayName)
        return try await withWriteRetry {
            let proposedID = ParticipantID(rawValue: UUID())
            _ = try connection.execute(
                "INSERT INTO participants (id, name, normalized_name) VALUES (?, ?, ?) "
                    + "ON CONFLICT(normalized_name) DO NOTHING",
                [proposedID.rawValue.uuidString, displayName, normalizedName]
            )
            guard let row = try connection.query(
                "SELECT id, name, role, company, email FROM participants WHERE normalized_name = ?",
                [normalizedName]
            ).next() else {
                throw CallStoreError.invalidStoredIdentifier(normalizedName)
            }
            return try Self.participant(from: row)
        }
    }

    public func listParticipants() throws -> [Participant] {
        try connection.query(
            "SELECT id, name, role, company, email FROM participants ORDER BY normalized_name"
        ).map(Self.participant)
    }

    public func updateParticipant(
        id: ParticipantID,
        name: String,
        role: String?,
        company: String?,
        email: String?
    ) async throws -> Participant {
        let participant = Participant(
            id: id,
            name: try Self.cleanedName(name),
            role: Self.cleanedOptional(role),
            company: Self.cleanedOptional(company),
            email: Self.cleanedOptional(email)
        )
        return try await withWriteRetry {
            let changed = try connection.execute(
                "UPDATE participants SET name = ?, normalized_name = ?, role = ?, company = ?, email = ? "
                    + "WHERE id = ? COLLATE NOCASE",
                [
                    participant.name,
                    Self.normalizedName(participant.name),
                    participant.role ?? Value.null,
                    participant.company ?? Value.null,
                    participant.email ?? Value.null,
                    id.rawValue.uuidString,
                ]
            )
            guard changed == 1 else { throw CallStoreError.participantNotFound(id) }
            return participant
        }
    }

    public func upsertGlossaryTerm(
        preferred: String,
        aliases: [String]
    ) async throws -> GlossaryTerm {
        let displayName = try Self.cleanedName(preferred)
        let normalizedName = Self.normalizedName(displayName)
        let cleanedAliases = try aliases.map(Self.cleanedName)
        let aliasesData = try JSONEncoder().encode(cleanedAliases)
        guard let aliasesJSON = String(data: aliasesData, encoding: .utf8) else {
            throw CallStoreError.invalidStoredAliases
        }
        return try await withWriteRetry {
            let proposedID = GlossaryTermID(rawValue: UUID())
            _ = try connection.execute(
                "INSERT INTO glossary_terms (id, preferred, normalized_preferred, aliases_json) "
                    + "VALUES (?, ?, ?, ?) ON CONFLICT(normalized_preferred) DO UPDATE SET "
                    + "preferred = excluded.preferred, aliases_json = excluded.aliases_json",
                [proposedID.rawValue.uuidString, displayName, normalizedName, aliasesJSON]
            )
            guard let row = try connection.query(
                "SELECT id, preferred, aliases_json FROM glossary_terms "
                    + "WHERE normalized_preferred = ?",
                [normalizedName]
            ).next() else {
                throw CallStoreError.invalidStoredIdentifier(normalizedName)
            }
            return try Self.glossaryTerm(from: row)
        }
    }

    public func listGlossaryTerms() throws -> [GlossaryTerm] {
        try connection.query(
            "SELECT id, preferred, aliases_json FROM glossary_terms ORDER BY normalized_preferred"
        ).map(Self.glossaryTerm)
    }

    /// How often each glossary term already appears in saved transcripts, keyed by the
    /// lowercased preferred spelling. whisper.cpp accepts only about 224 prompt tokens, so the
    /// glossary is much larger than the prompt can carry. Terms the user already says, or
    /// already gets misheard, are the ones worth that space. Only the newest transcripts are
    /// read, because recent meetings predict the next one better than old ones do.
    public func glossaryUsageCounts(sampleLimit: Int = 40) throws -> [String: Int] {
        guard sampleLimit > 0 else { throw CallStoreError.invalidLimit }
        let terms = try listGlossaryTerms()
        guard !terms.isEmpty else { return [:] }
        // Searching with Swift strings costs grapheme-aware comparisons, which took about five
        // seconds for 40 transcripts and made the metadata refresh wait. Raw byte search finds
        // the same spellings in a fraction of the time, and both sides are already lowercased.
        let sample = try connection.query(
            "SELECT t.text FROM transcripts t JOIN calls c ON c.id = t.call_id "
                + "ORDER BY c.started_at DESC LIMIT ?",
            [sampleLimit]
        ).map { Array(Self.spokenText(from: try $0.getString(0)).lowercased().utf8) }
        guard !sample.isEmpty else { return [:] }
        var counts: [String: Int] = [:]
        for term in terms {
            let spellings = Set([term.preferred] + term.aliases)
                .map { Array($0.lowercased().utf8) }
                .filter { $0.count > 1 }
            var matches = 0
            for text in sample where spellings.contains(where: { Self.contains(text, $0) }) {
                matches += 1
            }
            counts[term.preferred.lowercased()] = matches
        }
        return counts
    }

    /// Byte-level substring search. `memmem` is the C library's tuned implementation, which keeps
    /// the scan linear in the size of the transcripts instead of paying per-character cost.
    static func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        return haystack.withUnsafeBufferPointer { hay in
            needle.withUnsafeBufferPointer { pin in
                guard let hayBase = hay.baseAddress, let pinBase = pin.baseAddress else {
                    return false
                }
                return memmem(hayBase, hay.count, pinBase, pin.count) != nil
            }
        }
    }

    /// Drops the transcript header. The header lists glossary terms, so counting it would make
    /// every listed term look used and hide the terms the user actually says.
    static func spokenText(from transcript: String) -> String {
        let headerPrefixes = ["# meeting transcript", "participants:", "glossary:"]
        return transcript.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces).lowercased()
                return !headerPrefixes.contains { trimmed.hasPrefix($0) }
            }
            .joined(separator: "\n")
    }

    public func deleteGlossaryTerm(id: GlossaryTermID) async throws {
        let changed = try await withWriteRetry {
            try connection.execute(
                "DELETE FROM glossary_terms WHERE id = ?",
                [id.rawValue.uuidString]
            )
        }
        guard changed == 1 else { throw CallStoreError.invalidStoredIdentifier(id.rawValue.uuidString) }
    }

    public func createCall(_ call: CallRecord) async throws {
        try await withWriteRetry {
            _ = try connection.execute(
                "INSERT INTO calls (id, started_at, ended_at, audio_path, status) "
                    + "VALUES (?, ?, ?, ?, ?)",
                [
                    call.id.rawValue.uuidString,
                    call.startedAt.timeIntervalSince1970,
                    call.endedAt?.timeIntervalSince1970 ?? Value.null,
                    call.audioPath ?? Value.null,
                    call.status.rawValue,
                ]
            )
        }
    }

    public func updateCall(
        id: CallID,
        endedAt: Date,
        audioPath: String,
        status: CallStatus
    ) async throws {
        try await withWriteRetry {
            let transaction = try connection.transaction()
            do {
                let changed = try transaction.execute(
                    "UPDATE calls SET ended_at = ?, audio_path = ?, status = ? WHERE id = ?",
                    [
                        endedAt.timeIntervalSince1970,
                        audioPath,
                        status.rawValue,
                        id.rawValue.uuidString,
                    ]
                )
                guard changed == 1 else { throw CallStoreError.callNotFound(id) }
                if status == .metadata {
                    _ = try transaction.execute(
                        "INSERT INTO processing_jobs ("
                            + "call_id, stage, execution_state, attempt_count, created_at, updated_at"
                            + ") SELECT id, 'awaitingParticipants', 'pending', 0, started_at, ? "
                            + "FROM calls WHERE id = ? ON CONFLICT(call_id) DO UPDATE SET "
                            + "stage = 'awaitingParticipants', execution_state = 'pending', "
                            + "updated_at = excluded.updated_at, started_at = NULL, "
                            + "completed_at = NULL, latest_event_id = NULL, claim_token = NULL",
                        [endedAt.timeIntervalSince1970, id.rawValue.uuidString]
                    )
                }
                transaction.commit()
            } catch {
                transaction.rollback()
                throw error
            }
        }
    }

    public func finalizeAndQueue(
        id: CallID,
        endedAt: Date,
        audioPath: String
    ) async throws {
        try await withWriteRetry {
            let transaction = try connection.transaction()
            do {
                guard let row = try transaction.query(
                    "SELECT status FROM calls WHERE id = ?",
                    [id.rawValue.uuidString]
                ).next() else { throw CallStoreError.callNotFound(id) }
                let storedStatusValue = try row.getString(0)
                guard let storedStatus = CallStatus(rawValue: storedStatusValue) else {
                    throw CallStoreError.invalidStoredStatus(storedStatusValue)
                }
                guard storedStatus == .recording || storedStatus == .metadata else {
                    transaction.commit()
                    return
                }
                if let jobRow = try transaction.query(
                    "SELECT stage, execution_state FROM processing_jobs WHERE call_id = ?",
                    [id.rawValue.uuidString]
                ).next() {
                    let stageValue = try jobRow.getString(0)
                    let executionValue = try jobRow.getString(1)
                    guard
                        let stage = ProcessingStage(rawValue: stageValue),
                        let execution = ProcessingExecutionState(rawValue: executionValue)
                    else { throw CallStoreError.invalidStoredStatus("\(stageValue):\(executionValue)") }
                    let canQueue = (stage == .awaitingParticipants || stage == .queued)
                        && (execution == .pending || execution == .failed)
                    guard canQueue else {
                        transaction.commit()
                        return
                    }
                }
                let changed = try transaction.execute(
                    "UPDATE calls SET ended_at = ?, audio_path = ?, status = 'metadata' "
                        + "WHERE id = ? AND status IN ('recording', 'metadata')",
                    [
                        endedAt.timeIntervalSince1970,
                        audioPath,
                        id.rawValue.uuidString,
                    ]
                )
                guard changed == 1 else { throw CallStoreError.callNotFound(id) }
                _ = try transaction.execute(
                    "INSERT INTO processing_jobs ("
                        + "call_id, stage, execution_state, attempt_count, created_at, updated_at"
                        + ") SELECT id, 'queued', 'pending', 0, started_at, ? FROM calls "
                        + "WHERE id = ? ON CONFLICT(call_id) DO UPDATE SET "
                        + "stage = 'queued', execution_state = 'pending', "
                        + "updated_at = excluded.updated_at, started_at = NULL, "
                        + "completed_at = NULL, latest_event_id = NULL, claim_token = NULL",
                    [endedAt.timeIntervalSince1970, id.rawValue.uuidString]
                )
                transaction.commit()
            } catch {
                transaction.rollback()
                throw error
            }
        }
    }

    public func call(id: CallID) throws -> CallRecord? {
        guard let row = try connection.query(
            "SELECT started_at, ended_at, audio_path, status FROM calls WHERE id = ?",
            [id.rawValue.uuidString]
        ).next() else { return nil }
        let statusValue = try row.getString(3)
        guard let status = CallStatus(rawValue: statusValue) else {
            throw CallStoreError.invalidStoredStatus(statusValue)
        }
        return CallRecord(
            id: id,
            startedAt: Date(timeIntervalSince1970: try row.getDouble(0)),
            endedAt: try Self.optionalDate(row.get(1)),
            audioPath: try Self.optionalString(row.get(2)),
            status: status
        )
    }

    public func latestMetadataCall() throws -> CallRecord? {
        guard let row = try connection.query(
            "SELECT id FROM calls WHERE status = 'metadata' ORDER BY ended_at DESC LIMIT 1"
        ).next() else { return nil }
        return try call(
            id: CallID(rawValue: try Self.uuid(from: row.getString(0)))
        )
    }

    public func queuePendingParticipantJobs() async throws -> Int {
        try await withWriteRetry {
            try connection.execute(
                "UPDATE processing_jobs SET stage = 'queued', updated_at = ?, "
                    + "started_at = NULL, completed_at = NULL, latest_event_id = NULL, "
                    + "claim_token = NULL WHERE stage = 'awaitingParticipants' "
                    + "AND execution_state = 'pending' AND EXISTS ("
                    + "SELECT 1 FROM calls WHERE calls.id = processing_jobs.call_id "
                    + "AND calls.audio_path IS NOT NULL)",
                [Date().timeIntervalSince1970]
            )
        }
    }


    /// One call that has a saved transcript, with the participant names the database holds for
    /// it. Lets a caller compare the file on disk with the stored list.
    public func transcriptHeaderRows(
        limit: Int = 500
    ) throws -> [(callID: CallID, markdownPath: String, names: [String])] {
        guard (1...5_000).contains(limit) else { throw CallStoreError.invalidLimit }
        let calls = try connection.query(
            "SELECT transcripts.call_id, transcripts.markdown_path FROM transcripts "
                + "JOIN calls ON calls.id = transcripts.call_id "
                + "ORDER BY calls.started_at DESC LIMIT ?",
            [limit]
        ).map { row in
            (callID: CallID(rawValue: try Self.uuid(from: row.getString(0))), path: try row.getString(1))
        }
        var namesByCall: [String: [String]] = [:]
        for row in try connection.query(
            "SELECT call_participants.call_id, participants.name "
                + "FROM call_participants JOIN participants ON participants.id = call_participants.participant_id "
                + "ORDER BY participants.name COLLATE NOCASE"
        ) {
            namesByCall[try row.getString(0), default: []].append(try row.getString(1))
        }
        return calls.map { (callID: $0.callID, markdownPath: $0.path, names: namesByCall[$0.callID.rawValue.uuidString] ?? []) }
    }

    /// One stored transcript with everything needed to write its file back.
    ///
    /// The text is what the database holds, which is the same text the search index was built
    /// from and the same text the transcript window shows. A file rebuilt from it is the
    /// transcript, not a copy of a copy.
    public struct TranscriptFileRecord: Sendable {
        public let callID: CallID
        public let startedAt: Date
        public let language: String
        public let model: String
        public let text: String
        public let markdownPath: String
        public let jsonPath: String
    }

    /// Every transcript in the store, newest first.
    ///
    /// A transcript row and the file it names are two things, and they can disagree: the working
    /// directory a call was transcribed into is removed once the transcript and its search index
    /// are verified, and the row is supposed to be repointed at the promoted file first. Where
    /// that did not happen the row kept naming a folder that no longer exists, so the call
    /// reported a saved transcript that could not be opened. Reading the rows and the files
    /// together is how that is found.
    ///
    /// The query is bounded because a rebuild reads one text per row.
    public func transcriptFileRecords(limit: Int = 500) throws -> [TranscriptFileRecord] {
        guard (1...5_000).contains(limit) else { throw CallStoreError.invalidLimit }
        return try connection.query(
            "SELECT t.call_id, c.started_at, t.language, t.model, t.text,"
                + " t.markdown_path, t.json_path FROM transcripts t"
                + " JOIN calls c ON c.id = t.call_id"
                + " ORDER BY c.started_at DESC LIMIT ?",
            [limit]
        ).map(Self.fileRecord(from:))
    }

    /// The same row as above, for one call.
    ///
    /// Opening a transcript is the moment a row with a missing file is felt, and answering it
    /// means writing that one file back. Reading the whole library to reach one call would make
    /// a button wait on every other transcript in it.
    public func transcriptFileRecord(for callID: CallID) throws -> TranscriptFileRecord? {
        let rows = try connection.query(
            "SELECT t.call_id, c.started_at, t.language, t.model, t.text,"
                + " t.markdown_path, t.json_path FROM transcripts t"
                + " JOIN calls c ON c.id = t.call_id"
                + " WHERE t.call_id = ? LIMIT 1",
            [callID.rawValue.uuidString]
        )
        guard let row = try rows.next() else { return nil }
        return try Self.fileRecord(from: row)
    }

    /// Reads one row of the transcript-file select list both readers above share.
    private static func fileRecord(from row: Row) throws -> TranscriptFileRecord {
        TranscriptFileRecord(
            callID: CallID(rawValue: try uuid(from: row.getString(0))),
            startedAt: Date(timeIntervalSince1970: try row.getDouble(1)),
            language: try row.getString(2),
            model: try row.getString(3),
            text: try row.getString(4),
            markdownPath: try row.getString(5),
            jsonPath: try row.getString(6)
        )
    }

    public func recentCalls(limit: Int, at _: Date = Date()) throws -> [RecentCallSummary] {
        guard (1...50).contains(limit) else { throw CallStoreError.invalidLimit }
        let rows = try connection.query(
            """
            WITH selected AS (
                SELECT calls.id, calls.started_at, calls.ended_at, calls.status,
                    EXISTS(SELECT 1 FROM transcripts WHERE transcripts.call_id = calls.id)
                        AS has_transcript,
                    -- A transcript row with no text is a transcription that found nothing to
                    -- write. The file exists, so a plain existence test called it a transcript.
                    COALESCE((SELECT length(transcripts.text) > 0 FROM transcripts
                        WHERE transcripts.call_id = calls.id), 0) AS has_speech,
                    (SELECT COUNT(*) FROM speaker_assignments
                        WHERE speaker_assignments.call_id = calls.id
                        AND speaker_assignments.state IN ('suggested', 'unknown')
                        AND speaker_assignments.reviewed_at IS NULL
                        AND EXISTS(SELECT 1 FROM pending_speaker_clusters clusters
                            WHERE clusters.id = speaker_assignments.cluster_id)) AS unresolved_speakers,
                    calls.system_audio
                FROM calls ORDER BY calls.started_at DESC, calls.id LIMIT ?
            )
            SELECT selected.id, selected.started_at, selected.ended_at, selected.status,
                selected.has_transcript, selected.has_speech, selected.unresolved_speakers,
                participants.name, selected.system_audio
            FROM selected
            LEFT JOIN call_participants ON call_participants.call_id = selected.id
            LEFT JOIN participants ON participants.id = call_participants.participant_id COLLATE NOCASE
            ORDER BY selected.started_at DESC, selected.id, participants.normalized_name
            """,
            [limit]
        )
        var byID: [CallID: RecentCallSummary] = [:]
        var order: [CallID] = []
        for row in rows {
            let id = CallID(rawValue: try Self.uuid(from: row.getString(0)))
            if byID[id] == nil {
                let statusValue = try row.getString(3)
                guard let status = CallStatus(rawValue: statusValue) else {
                    throw CallStoreError.invalidStoredStatus(statusValue)
                }
                order.append(id)
                byID[id] = RecentCallSummary(
                    id: id,
                    startedAt: Date(timeIntervalSince1970: try row.getDouble(1)),
                    endedAt: try Self.optionalDate(row.get(2)),
                    status: status,
                    participantNames: [],
                    hasTranscript: try row.getInt(4) == 1,
                    unresolvedSpeakerCount: try row.getInt(6),
                    hasSpeech: try row.getInt(5) == 1,
                    systemAudio: try Self.optionalSystemAudio(row.get(8))
                )
            }
            guard let name = try Self.optionalString(row.get(7)), let current = byID[id] else {
                continue
            }
            byID[id] = RecentCallSummary(
                id: current.id,
                startedAt: current.startedAt,
                endedAt: current.endedAt,
                status: current.status,
                participantNames: current.participantNames + [name],
                hasTranscript: current.hasTranscript,
                unresolvedSpeakerCount: current.unresolvedSpeakerCount,
                hasSpeech: current.hasSpeech,
                systemAudio: current.systemAudio
            )
        }
        return order.compactMap { byID[$0] }
    }

    public func transcriptText(for callID: CallID) throws -> String? {
        try connection.query(
            "SELECT text FROM transcripts WHERE call_id = ?",
            [callID.rawValue.uuidString]
        ).next().map { try $0.getString(0) }
    }

    /// The same summary `recentCalls` returns, for calls named by id.
    ///
    /// The Recovery pane lists jobs that need a decision, and a job carries only a call id. A row
    /// that says "Transcribing audio" four times over tells the person nothing about which call to
    /// retry first, so the list asks for the dates and names of exactly the calls it shows.
    public func callSummaries(ids: [CallID]) throws -> [CallID: RecentCallSummary] {
        guard !ids.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")
        let rows = try connection.query(
            """
            SELECT calls.id, calls.started_at, calls.ended_at, calls.status,
                EXISTS(SELECT 1 FROM transcripts WHERE transcripts.call_id = calls.id)
                    AS has_transcript,
                participants.name, calls.system_audio
            FROM calls
            LEFT JOIN call_participants ON call_participants.call_id = calls.id
            LEFT JOIN participants ON participants.id = call_participants.participant_id COLLATE NOCASE
            WHERE calls.id IN (\(placeholders))
            ORDER BY calls.started_at DESC, calls.id, participants.normalized_name
            """,
            ids.map { $0.rawValue.uuidString }
        )
        var byID: [CallID: RecentCallSummary] = [:]
        for row in rows {
            let id = CallID(rawValue: try Self.uuid(from: row.getString(0)))
            let name = try Self.optionalString(row.get(5))
            if let current = byID[id] {
                byID[id] = RecentCallSummary(
                    id: current.id,
                    startedAt: current.startedAt,
                    endedAt: current.endedAt,
                    status: current.status,
                    participantNames: current.participantNames + [name].compactMap { $0 },
                    hasTranscript: current.hasTranscript,
                    unresolvedSpeakerCount: current.unresolvedSpeakerCount,
                    systemAudio: current.systemAudio
                )
                continue
            }
            let statusValue = try row.getString(3)
            guard let status = CallStatus(rawValue: statusValue) else {
                throw CallStoreError.invalidStoredStatus(statusValue)
            }
            byID[id] = RecentCallSummary(
                id: id,
                startedAt: Date(timeIntervalSince1970: try row.getDouble(1)),
                endedAt: try Self.optionalDate(row.get(2)),
                status: status,
                participantNames: [name].compactMap { $0 },
                hasTranscript: try row.getInt(4) == 1,
                systemAudio: try Self.optionalSystemAudio(row.get(6))
            )
        }
        return byID
    }

    /// Every call that has a saved transcript, newest first.
    ///
    /// The glossary repair walks these: a term added after a call was recorded never reached the
    /// saved text, so repairing an existing library means visiting each of them.
    public func callIDsWithTranscripts() throws -> [CallID] {
        try connection.query(
            "SELECT transcripts.call_id FROM transcripts "
                + "JOIN calls ON calls.id = transcripts.call_id "
                + "ORDER BY calls.started_at DESC, transcripts.call_id"
        ).compactMap { row in
            (try? row.getString(0)).flatMap { UUID(uuidString: $0) }.map { CallID(rawValue: $0) }
        }
    }

    public func transcript(for callID: CallID) throws -> TranscriptRecord? {
        guard let row = try connection.query(
            "SELECT language, model, text, markdown_path, json_path FROM transcripts WHERE call_id = ?",
            [callID.rawValue.uuidString]
        ).next() else { return nil }
        return TranscriptRecord(
            callID: callID,
            language: try row.getString(0),
            model: try row.getString(1),
            text: try row.getString(2),
            markdownPath: try row.getString(3),
            jsonPath: try row.getString(4)
        )
    }

    public func setParticipants(
        _ participantIDs: [ParticipantID],
        for callID: CallID
    ) async throws {
        try await withWriteRetry {
            guard try callExists(callID) else { throw CallStoreError.callNotFound(callID) }
            let transaction = try connection.transaction()
            do {
                _ = try transaction.execute(
                    "DELETE FROM call_participants WHERE call_id = ?",
                    [callID.rawValue.uuidString]
                )
                for participantID in participantIDs {
                    guard let participantRow = try transaction.query(
                        "SELECT id FROM participants WHERE id = ? COLLATE NOCASE",
                        [participantID.rawValue.uuidString]
                    ).next() else {
                        throw CallStoreError.participantNotFound(participantID)
                    }
                    _ = try transaction.execute(
                        "INSERT INTO call_participants (call_id, participant_id) VALUES (?, ?)",
                        [callID.rawValue.uuidString, try participantRow.getString(0)]
                    )
                }
                _ = try transaction.execute(
                    "UPDATE processing_jobs SET stage = 'queued', execution_state = 'pending', "
                        + "updated_at = ?, started_at = NULL, completed_at = NULL, claim_token = NULL "
                        + "WHERE call_id = ? AND stage = 'awaitingParticipants' "
                        + "AND execution_state = 'pending'",
                    [Date().timeIntervalSince1970, callID.rawValue.uuidString]
                )
                transaction.commit()
            } catch {
                transaction.rollback()
                throw error
            }
        }
    }

    public func participants(for callID: CallID) throws -> [Participant] {
        try connection.query(
            "SELECT p.id, p.name, p.role, p.company, p.email FROM participants p "
                + "JOIN call_participants cp ON cp.participant_id = p.id COLLATE NOCASE "
                + "WHERE cp.call_id = ? ORDER BY p.normalized_name",
            [callID.rawValue.uuidString]
        ).map(Self.participant)
    }

    /// Everyone on every call, keyed by call.
    ///
    /// The speaker review window asks which people were on the call it is naming a voice for, and
    /// that question deserves its own answer: a remote speaker is almost always one of the people
    /// who were on the call, and a list of everyone ever met buries those three among forty-seven.
    /// Asking per call would be one query per card, so the whole table is read once and grouped.
    /// The order matches the single-call query, so a name sits in the same place in both.
    public func participantsByCall() throws -> [CallID: [Participant]] {
        var result: [CallID: [Participant]] = [:]
        let rows = try connection.query(
            "SELECT cp.call_id, p.id, p.name, p.role, p.company, p.email FROM participants p "
                + "JOIN call_participants cp ON cp.participant_id = p.id COLLATE NOCASE "
                + "ORDER BY cp.call_id, p.normalized_name"
        )
        while let row = rows.next() {
            let callID = CallID(rawValue: try Self.uuid(from: row.getString(0)))
            let participant = Participant(
                id: ParticipantID(rawValue: try Self.uuid(from: row.getString(1))),
                name: try row.getString(2),
                role: try Self.optionalString(row.get(3)),
                company: try Self.optionalString(row.get(4)),
                email: try Self.optionalString(row.get(5))
            )
            result[callID, default: []].append(participant)
        }
        return result
    }

    func hasEncryptedSpeakerData() throws -> Bool {
        try connection.query(
            "SELECT 1 FROM pending_speaker_clusters UNION ALL "
                + "SELECT 1 FROM participant_voice_samples LIMIT 1"
        ).next() != nil
    }

    func upsertPendingSpeakerCluster(
        _ record: EncryptedPendingSpeakerCluster
    ) async throws -> SpeakerClusterID {
        try await withWriteRetry {
            guard try callExists(record.callID) else {
                throw CallStoreError.callNotFound(record.callID)
            }
            let transaction = try connection.transaction()
            do {
                let existingID = try transaction.query(
                    "SELECT id FROM pending_speaker_clusters "
                        + "WHERE call_id = ? AND speaker_index = ?",
                    [record.callID.rawValue.uuidString, record.speakerIndex]
                ).next().map { try $0.getString(0) }
                let clusterID: SpeakerClusterID
                if let existingID {
                    clusterID = SpeakerClusterID(rawValue: try Self.uuid(from: existingID))
                    _ = try transaction.execute(
                        "UPDATE pending_speaker_clusters SET speaker_label = ?, model_version = ?, "
                            + "encrypted_embedding = ?, speech_ms = ?, created_at = ?, expires_at = ? "
                            + "WHERE id = ?",
                        [
                            record.speakerLabel,
                            record.modelVersion,
                            record.encryptedEmbedding,
                            record.speechDurationMilliseconds,
                            record.createdAt.timeIntervalSince1970,
                            record.expiresAt.timeIntervalSince1970,
                            existingID,
                        ]
                    )
                } else {
                    clusterID = record.clusterID
                    _ = try transaction.execute(
                        "INSERT INTO pending_speaker_clusters ("
                            + "id, call_id, speaker_index, speaker_label, model_version, "
                            + "encrypted_embedding, speech_ms, created_at, expires_at"
                            + ") VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                        [
                            clusterID.rawValue.uuidString,
                            record.callID.rawValue.uuidString,
                            record.speakerIndex,
                            record.speakerLabel,
                            record.modelVersion,
                            record.encryptedEmbedding,
                            record.speechDurationMilliseconds,
                            record.createdAt.timeIntervalSince1970,
                            record.expiresAt.timeIntervalSince1970,
                        ]
                    )
                }
                _ = try transaction.execute(
                    "INSERT INTO speaker_assignments ("
                        + "cluster_id, call_id, speaker_index, participant_id, state, "
                        + "confidence_band, updated_at"
                        + ") VALUES (?, ?, ?, NULL, 'unknown', 'none', ?) "
                        + "ON CONFLICT(cluster_id) DO NOTHING",
                    [
                        clusterID.rawValue.uuidString,
                        record.callID.rawValue.uuidString,
                        record.speakerIndex,
                        record.createdAt.timeIntervalSince1970,
                    ]
                )
                transaction.commit()
                return clusterID
            } catch {
                transaction.rollback()
                throw error
            }
        }
    }

    func encryptedPendingSpeakerClusters(
        for callID: CallID,
        at date: Date = Date()
    ) throws -> [EncryptedPendingSpeakerCluster] {
        try connection.query(
            "SELECT id, speaker_index, speaker_label, model_version, encrypted_embedding, "
                + "speech_ms, created_at, expires_at FROM pending_speaker_clusters "
                + "WHERE call_id = ? AND (expires_at > ? OR EXISTS ("
                + "SELECT 1 FROM speaker_assignments assignments "
                + "WHERE assignments.cluster_id = pending_speaker_clusters.id "
                + "AND assignments.state IN ('suggested','unknown') "
                + "AND assignments.reviewed_at IS NULL)) ORDER BY speaker_index",
            [callID.rawValue.uuidString, date.timeIntervalSince1970]
        ).map { row in
            EncryptedPendingSpeakerCluster(
                callID: callID,
                speakerIndex: try row.getInt(1),
                speakerLabel: try row.getString(2),
                clusterID: SpeakerClusterID(rawValue: try Self.uuid(from: row.getString(0))),
                modelVersion: try row.getString(3),
                encryptedEmbedding: try row.getData(4),
                speechDurationMilliseconds: try row.getInt(5),
                createdAt: Date(timeIntervalSince1970: try row.getDouble(6)),
                expiresAt: Date(timeIntervalSince1970: try row.getDouble(7))
            )
        }
    }

    func encryptedVoiceSamples(modelVersion: String) throws -> [EncryptedVoiceSample] {
        try connection.query(
            "SELECT participant_id, model_version, encrypted_embedding "
                + "FROM participant_voice_samples WHERE model_version = ? "
                + "ORDER BY participant_id, created_at, id",
            [modelVersion]
        ).map { row in
            EncryptedVoiceSample(
                participantID: ParticipantID(rawValue: try Self.uuid(from: row.getString(0))),
                modelVersion: try row.getString(1),
                encryptedEmbedding: try row.getData(2)
            )
        }
    }

    func confirmedSpeakerSampleCount(for participantID: ParticipantID) throws -> Int {
        guard let row = try connection.query(
            "SELECT COUNT(*) FROM participant_voice_samples WHERE participant_id = ? COLLATE NOCASE",
            [participantID.rawValue.uuidString]
        ).next() else { return 0 }
        return try row.getInt(0)
    }

    func confirmSpeaker(
        clusterID: SpeakerClusterID,
        participantID: ParticipantID,
        minimumSpeechMilliseconds: Int
    ) async throws {
        try await withWriteRetry {
            let transaction = try connection.transaction()
            do {
                guard let cluster = try transaction.query(
                    "SELECT call_id, model_version, encrypted_embedding, speech_ms, created_at "
                        + "FROM pending_speaker_clusters WHERE id = ?",
                    [clusterID.rawValue.uuidString]
                ).next() else { throw CallStoreError.speakerClusterNotFound(clusterID) }
                let storedID = try Self.storedParticipantID(participantID, in: transaction)
                let callID = try cluster.getString(0)
                let modelVersion = try cluster.getString(1)
                let encryptedEmbedding = try cluster.getData(2)
                let speechMilliseconds = try cluster.getInt(3)
                let createdAt = try cluster.getDouble(4)
                let priorParticipant = try transaction.query(
                    "SELECT participant_id FROM speaker_assignments WHERE cluster_id = ?",
                    [clusterID.rawValue.uuidString]
                ).next().flatMap { try Self.optionalString($0.get(0)) }

                _ = try transaction.execute(
                    "UPDATE speaker_assignments SET participant_id = ?, state = 'confirmed', "
                        + "confidence_band = 'high', reviewed_at = ?, updated_at = ? "
                        + "WHERE cluster_id = ?",
                    [
                        storedID,
                        Date().timeIntervalSince1970,
                        Date().timeIntervalSince1970,
                        clusterID.rawValue.uuidString,
                    ]
                )
                _ = try transaction.execute(
                    "INSERT OR IGNORE INTO call_participants (call_id, participant_id) VALUES (?, ?)",
                    [callID, storedID]
                )
                if speechMilliseconds >= minimumSpeechMilliseconds {
                    _ = try transaction.execute(
                        "INSERT INTO participant_voice_samples ("
                            + "id, participant_id, model_version, encrypted_embedding, speech_ms, "
                            + "confirmed_call_id, created_at, source_cluster_id"
                            + ") VALUES (?, ?, ?, ?, ?, ?, ?, ?) "
                            + "ON CONFLICT(source_cluster_id) DO UPDATE SET "
                            + "participant_id = excluded.participant_id, "
                            + "model_version = excluded.model_version, "
                            + "encrypted_embedding = excluded.encrypted_embedding, "
                            + "speech_ms = excluded.speech_ms, confirmed_call_id = excluded.confirmed_call_id",
                        [
                            UUID().uuidString,
                            storedID,
                            modelVersion,
                            encryptedEmbedding,
                            speechMilliseconds,
                            callID,
                            createdAt,
                            clusterID.rawValue.uuidString,
                        ]
                    )
                    _ = try transaction.execute(
                        "DELETE FROM participant_voice_samples WHERE id IN ("
                            + "SELECT id FROM participant_voice_samples WHERE participant_id = ? COLLATE NOCASE "
                            + "AND model_version = ? ORDER BY created_at DESC, id DESC "
                            + "LIMIT -1 OFFSET 20)",
                        [storedID, modelVersion]
                    )
                }
                if let priorParticipant, priorParticipant.caseInsensitiveCompare(storedID) != .orderedSame {
                    _ = try transaction.execute(
                        "DELETE FROM call_participants WHERE call_id = ? AND participant_id = ? COLLATE NOCASE "
                            + "AND NOT EXISTS (SELECT 1 FROM speaker_assignments "
                            + "WHERE call_id = ? AND participant_id = ? COLLATE NOCASE "
                            + "AND state IN ('automatic','confirmed'))",
                        [callID, priorParticipant, callID, priorParticipant]
                    )
                }
                transaction.commit()
            } catch {
                transaction.rollback()
                throw error
            }
        }
    }

    func saveSpeakerMatches(_ matches: [SpeakerMatch]) async throws {
        guard !matches.isEmpty else { return }
        try await withWriteRetry {
            let transaction = try connection.transaction()
            do {
                for match in matches {
                    guard let cluster = try transaction.query(
                        "SELECT call_id FROM pending_speaker_clusters WHERE id = ?",
                        [match.clusterID.rawValue.uuidString]
                    ).next() else {
                        throw CallStoreError.speakerClusterNotFound(match.clusterID)
                    }
                    let callID = try cluster.getString(0)
                    let storedID = try match.participantID.map {
                        try Self.storedParticipantID($0, in: transaction)
                    }
                    let confidenceBand: String = switch match.state {
                    case .automatic, .confirmed: "high"
                    case .suggested: "review"
                    case .unknown: "none"
                    }
                    _ = try transaction.execute(
                        "UPDATE speaker_assignments SET participant_id = ?, state = ?, "
                            + "confidence_band = ?, reviewed_at = NULL, updated_at = ? "
                            + "WHERE cluster_id = ?",
                        [
                            storedID ?? Value.null,
                            match.state.rawValue,
                            confidenceBand,
                            Date().timeIntervalSince1970,
                            match.clusterID.rawValue.uuidString,
                        ]
                    )
                    if
                        match.state == .automatic || match.state == .confirmed,
                        let storedID
                    {
                        _ = try transaction.execute(
                            "INSERT OR IGNORE INTO call_participants (call_id, participant_id) "
                                + "VALUES (?, ?)",
                            [callID, storedID]
                        )
                    }
                }
                transaction.commit()
            } catch {
                transaction.rollback()
                throw error
            }
        }
    }

    func unresolvedSpeakerReviews(
        limit: Int = 100,
        at _: Date = Date()
    ) throws -> [SpeakerReviewItem] {
        guard (1...500).contains(limit) else { throw CallStoreError.invalidLimit }
        return try connection.query(
            "SELECT clusters.id, clusters.call_id, clusters.speaker_index, "
                + "clusters.speaker_label, clusters.speech_ms, assignments.participant_id, "
                + "assignments.state, clusters.created_at FROM pending_speaker_clusters clusters "
                + "JOIN speaker_assignments assignments ON assignments.cluster_id = clusters.id "
                + "WHERE assignments.state IN ('suggested','unknown') "
                + "AND assignments.reviewed_at IS NULL "
                + "ORDER BY clusters.created_at DESC, clusters.call_id, clusters.speaker_index LIMIT ?",
            [limit]
        ).map(Self.speakerReview)
    }


    /// One person named on more than one speaker fragment inside a single call.
    func sharedParticipantClusters() throws -> [(callID: CallID, participantID: ParticipantID)] {
        try connection.query(
            "SELECT assignments.call_id, assignments.participant_id "
                + "FROM speaker_assignments assignments "
                + "WHERE assignments.participant_id IS NOT NULL "
                + "AND assignments.state IN ('automatic','confirmed') "
                + "GROUP BY assignments.call_id, assignments.participant_id "
                + "HAVING COUNT(*) > 1 "
                + "ORDER BY assignments.call_id"
        ).map { row in
            (
                callID: CallID(rawValue: try Self.uuid(from: row.getString(0))),
                participantID: ParticipantID(rawValue: try Self.uuid(from: row.getString(1)))
            )
        }
    }

    /// The fragments one person is named on inside one call, in speaker order.
    func namedClusterIDs(callID: CallID, participantID: ParticipantID) throws -> [SpeakerClusterID] {
        try connection.query(
            "SELECT cluster_id FROM speaker_assignments WHERE call_id = ? "
                + "AND participant_id = ? COLLATE NOCASE AND state IN ('automatic','confirmed') "
                + "ORDER BY speaker_index",
            [callID.rawValue.uuidString, participantID.rawValue.uuidString]
        ).map { try SpeakerClusterID(rawValue: Self.uuid(from: $0.getString(0))) }
    }

    /// Participants already named for a call, keyed by call. The review window uses this to warn
    /// before the same person is given a second voice in a call, which is how one name ends up on
    /// several speakers.
    public func namedParticipantsByCall() throws -> [CallID: Set<ParticipantID>] {
        var result: [CallID: Set<ParticipantID>] = [:]
        let rows = try connection.query(
            "SELECT call_id, participant_id FROM speaker_assignments "
                + "WHERE participant_id IS NOT NULL "
                + "AND state IN ('automatic','confirmed') ORDER BY call_id"
        )
        while let row = rows.next() {
            let callID = CallID(rawValue: try Self.uuid(from: row.getString(0)))
            let participantID = ParticipantID(rawValue: try Self.uuid(from: row.getString(1)))
            result[callID, default: []].insert(participantID)
        }
        return result
    }

    /// Returns the stored review for one cluster whatever its state, so a mapping that was
    /// already decided can be reopened and corrected.
    func speakerReview(clusterID: SpeakerClusterID) throws -> SpeakerReviewItem? {
        try connection.query(
            "SELECT clusters.id, clusters.call_id, clusters.speaker_index, "
                + "clusters.speaker_label, clusters.speech_ms, assignments.participant_id, "
                + "assignments.state, clusters.created_at FROM pending_speaker_clusters clusters "
                + "JOIN speaker_assignments assignments ON assignments.cluster_id = clusters.id "
                + "WHERE clusters.id = ?",
            [clusterID.rawValue.uuidString]
        ).next().map { try Self.speakerReview($0) }
    }

    private static func speakerReview(_ row: Row) throws -> SpeakerReviewItem {
        let stateValue = try row.getString(6)
        guard let state = SpeakerMatchState(rawValue: stateValue) else {
            throw CallStoreError.invalidStoredStatus(stateValue)
        }
        return SpeakerReviewItem(
            clusterID: SpeakerClusterID(rawValue: try uuid(from: row.getString(0))),
            callID: CallID(rawValue: try uuid(from: row.getString(1))),
            speakerIndex: try row.getInt(2),
            speakerLabel: try row.getString(3),
            speechDurationMilliseconds: try row.getInt(4),
            suggestedParticipantID: try optionalString(row.get(5)).map {
                ParticipantID(rawValue: try uuid(from: $0))
            },
            state: state,
            createdAt: Date(timeIntervalSince1970: try row.getDouble(7))
        )
    }

    public func hasUnresolvedSpeakerReviews(for callID: CallID) throws -> Bool {
        try connection.query(
            "SELECT 1 FROM speaker_assignments WHERE call_id = ? "
                + "AND state IN ('suggested','unknown') AND reviewed_at IS NULL LIMIT 1",
            [callID.rawValue.uuidString]
        ).next() != nil
    }

    @discardableResult
    public func resetInterruptedSpeakerReviewRequests(at date: Date = Date()) async throws -> Int {
        try await withWriteRetry {
            try connection.execute(
                "UPDATE speaker_review_requests SET status = 'pending', error = NULL, "
                    + "claim_token = NULL, updated_at = ? "
                    + "WHERE status = 'running'",
                [date.timeIntervalSince1970]
            )
        }
    }

    /// Claims the oldest pending request, or the oldest that carries one of the given actions.
    ///
    /// The action filter exists because the two kinds of request have different prerequisites. A
    /// request that names a voice needs the voice layer, which needs its key. A request that names
    /// a range of lines is applied from the call store alone. Filtering here, rather than claiming
    /// a request and handing it back, is what keeps a queued line request from waiting behind a
    /// voice request whose key is missing.
    public func claimNextSpeakerReviewRequest(
        actions: [SpeakerReviewRequestAction]? = nil,
        at date: Date = Date()
    ) async throws -> SpeakerReviewRequest? {
        // An empty filter can never match, and it would also be invalid SQL. Answering here keeps
        // that meaning in one place.
        if let actions, actions.isEmpty { return nil }
        let claimToken = UUID().uuidString
        let actionValues = actions?.map(\.rawValue) ?? []
        let actionFilter =
            actionValues.isEmpty
            ? ""
            : "AND action IN ("
                + Array(repeating: "?", count: actionValues.count).joined(separator: ",") + ") "
        let changed = try await withWriteRetry {
            try connection.execute(
                "UPDATE speaker_review_requests SET status = 'running', claim_token = ?, "
                    + "updated_at = ? WHERE id = (SELECT id FROM speaker_review_requests "
                    + "WHERE status = 'pending' " + actionFilter
                    + "ORDER BY created_at, id LIMIT 1) "
                    + "AND status = 'pending'",
                [claimToken, date.timeIntervalSince1970] + actionValues
            )
        }
        guard changed == 1 else { return nil }
        guard let row = try connection.query(
            "SELECT id, cluster_id, call_id, participant_id, action, start_ms, end_ms "
                + "FROM speaker_review_requests WHERE claim_token = ?",
            [claimToken]
        ).next() else { throw CallStoreError.invalidStoredIdentifier(claimToken) }
        let id = try Self.uuid(from: row.getString(0))
        let participantID = try Self.optionalString(row.get(3)).map {
            ParticipantID(rawValue: try Self.uuid(from: $0))
        }
        let actionValue = try row.getString(4)
        guard let action = SpeakerReviewRequestAction(rawValue: actionValue) else {
            throw CallStoreError.invalidStoredStatus(actionValue)
        }
        let startMs = try Self.optionalInt(row.get(5))
        let endMs = try Self.optionalInt(row.get(6))
        return SpeakerReviewRequest(
            id: id,
            clusterID: try Self.optionalString(row.get(1)).map {
                SpeakerClusterID(rawValue: try Self.uuid(from: $0))
            },
            callID: try Self.optionalString(row.get(2)).map {
                CallID(rawValue: try Self.uuid(from: $0))
            },
            participantID: participantID,
            action: action,
            // The range is closed at the top so the two ends a request carries read the same way a
            // saved correction does, and neither can be dropped by an off-by-one at a boundary.
            lineRange: startMs.flatMap { start in endMs.map { start...$0 } }
        )
    }

    public func completeSpeakerReviewRequest(
        _ id: UUID,
        at date: Date = Date()
    ) async throws {
        let changed = try await withWriteRetry {
            try connection.execute(
                "UPDATE speaker_review_requests SET status = 'completed', error = NULL, "
                    + "claim_token = NULL, updated_at = ? "
                    + "WHERE id = ? AND status = 'running'",
                [date.timeIntervalSince1970, id.uuidString]
            )
        }
        guard changed == 1 else { throw CallStoreError.speakerReviewRequestNotFound(id) }
    }

    public func failSpeakerReviewRequest(
        _ id: UUID,
        error: String,
        at date: Date = Date()
    ) async throws {
        let changed = try await withWriteRetry {
            try connection.execute(
                "UPDATE speaker_review_requests SET status = 'failed', error = ?, "
                    + "claim_token = NULL, updated_at = ? "
                    + "WHERE id = ? AND status = 'running'",
                [error, date.timeIntervalSince1970, id.uuidString]
            )
        }
        guard changed == 1 else { throw CallStoreError.speakerReviewRequestNotFound(id) }
    }

    func keepSpeakerUnknown(clusterID: SpeakerClusterID, at date: Date) async throws {
        let changed = try await withWriteRetry {
            try connection.execute(
                "UPDATE speaker_assignments SET participant_id = NULL, state = 'unknown', "
                    + "confidence_band = 'none', reviewed_at = ?, updated_at = ? "
                    + "WHERE cluster_id = ?",
                [
                    date.timeIntervalSince1970,
                    date.timeIntervalSince1970,
                    clusterID.rawValue.uuidString,
                ]
            )
        }
        guard changed == 1 else { throw CallStoreError.speakerClusterNotFound(clusterID) }
    }

    // MARK: - Lines moved off the voice that was detected for them

    /// Records that a run of one call's lines belongs to a person, whatever the voice was named.
    ///
    /// The person is resolved to the casing the table holds before the write. A foreign key in
    /// SQLite compares text byte for byte, and some rows were written in lower case, so passing the
    /// identifier through as the caller prints it fails on exactly those rows.
    @discardableResult
    public func saveSpeakerLineOverride(
        callID: CallID,
        startMs: Int,
        endMs: Int,
        participantID: ParticipantID,
        at date: Date = Date()
    ) async throws -> SpeakerLineOverride {
        try await withWriteRetry {
            let stored = try Self.storedParticipantID(participantID, in: connection)
            let name = try connection.query(
                "SELECT name FROM participants WHERE id = ? COLLATE NOCASE",
                [stored]
            ).next().map { try $0.getString(0) }
            guard let name else { throw CallStoreError.participantNotFound(participantID) }
            _ = try connection.execute(
                "INSERT INTO speaker_line_overrides "
                    + "(call_id, start_ms, end_ms, participant_id, created_at) "
                    + "VALUES (?, ?, ?, ?, ?) "
                    + "ON CONFLICT(call_id, start_ms, end_ms) DO UPDATE SET "
                    + "participant_id = excluded.participant_id, created_at = excluded.created_at",
                [callID.rawValue.uuidString, startMs, endMs, stored, date.timeIntervalSince1970]
            )
            return SpeakerLineOverride(
                callID: callID,
                startMs: startMs,
                endMs: endMs,
                participantID: participantID,
                speakerName: name
            )
        }
    }

    /// Takes a correction back off, so the lines follow the voice again. Returns whether a row went.
    @discardableResult
    public func removeSpeakerLineOverride(callID: CallID, startMs: Int, endMs: Int) async throws -> Bool {
        try await withWriteRetry {
            try connection.execute(
                "DELETE FROM speaker_line_overrides "
                    + "WHERE call_id = ? AND start_ms = ? AND end_ms = ?",
                [callID.rawValue.uuidString, startMs, endMs]
            ) > 0
        }
    }

    /// Every correction saved for a call, oldest first.
    public func speakerLineOverrides(callID: CallID) throws -> [SpeakerLineOverride] {
        try Self.speakerLineOverrides(callID: callID, in: connection)
    }

    /// Whether any call holds a correction, so a caller can say so without listing them.
    public func hasSpeakerLineOverrides() throws -> Bool {
        try connection.query("SELECT 1 FROM speaker_line_overrides LIMIT 1").next() != nil
    }

    /// The call a detected voice belongs to, for a request that names lines rather than the voice.
    public func callID(forCluster clusterID: SpeakerClusterID) async throws -> CallID? {
        guard let row = try connection.query(
            "SELECT call_id FROM pending_speaker_clusters WHERE id = ?",
            [clusterID.rawValue.uuidString]
        ).next() else { return nil }
        return CallID(rawValue: try Self.uuid(from: row.getString(0)))
    }

    /// The stored corrections, ready to be written onto a transcript's lines.
    ///
    /// The person's name is read at the same time as the range: a transcript written from a stale
    /// name would put back a spelling the roster no longer uses.
    static func speakerLineOverrides(
        callID: CallID,
        in handle: some Prepareable
    ) throws -> [SpeakerLineOverride] {
        let rows = try handle.query(
            "SELECT o.start_ms, o.end_ms, o.participant_id, p.name "
                + "FROM speaker_line_overrides o "
                + "JOIN participants p ON p.id = o.participant_id COLLATE NOCASE "
                + "WHERE o.call_id = ? ORDER BY o.start_ms",
            [callID.rawValue.uuidString]
        )
        var overrides: [SpeakerLineOverride] = []
        while let row = try rows.next() {
            overrides.append(
                SpeakerLineOverride(
                    callID: callID,
                    startMs: try row.getInt(0),
                    endMs: try row.getInt(1),
                    participantID: ParticipantID(
                        rawValue: UUID(uuidString: try row.getString(2)) ?? UUID()
                    ),
                    speakerName: try row.getString(3)
                )
            )
        }
        return overrides
    }

    /// Writes each correction onto the lines it covers.
    ///
    /// Applied after the voice's own name, because the correction is the more specific answer: a
    /// mixed voice is named as the person it mostly is, and the lines that belong to someone else
    /// are set right on top of that. Written as a function of the lines so a test can ask what a
    /// correction does without a database.
    public static func applying(
        overrides: [SpeakerLineOverride],
        to segments: [TranscriptSegment]
    ) -> [TranscriptSegment] {
        guard !overrides.isEmpty else { return segments }
        return segments.map { segment in
            guard segment.source != .microphone else { return segment }
            for override in overrides
            where override.covers(startMs: segment.startMs, endMs: segment.endMs) {
                return TranscriptSegment(
                    startMs: segment.startMs,
                    endMs: segment.endMs,
                    text: segment.text,
                    speakerIndex: segment.speakerIndex,
                    source: segment.source,
                    participantID: override.participantID,
                    speakerName: override.speakerName
                )
            }
            return segment
        }
    }

    func reopenSpeakerReview(
        _ review: SpeakerReviewItem,
        at date: Date
    ) async throws {
        try await withWriteRetry {
            let transaction = try connection.transaction()
            do {
                _ = try transaction.execute(
                    "DELETE FROM participant_voice_samples WHERE source_cluster_id = ?",
                    [review.clusterID.rawValue.uuidString]
                )
                // A decided speaker returns to the review queue, keeping the prior choice as
                // the suggestion. Only then can a wrong mapping be corrected.
                //
                // The suggestion is written back with the casing the person is stored under, and
                // it is dropped when they are gone. This statement used to write the identifier as
                // the caller's UUID prints it, which is upper case, while some rows are stored in
                // lower case: the foreign key then refused the write and the whole repair stopped
                // at the first fragment. The repair runs at launch, so the failure repeated every
                // launch and the duplicated names it exists to clear stayed in place.
                let suggestion = try review.suggestedParticipantID.flatMap {
                    try Self.storedParticipantIDIfPresent($0, in: transaction)
                }
                let decidedState: SpeakerMatchState = switch review.state {
                case .suggested, .unknown: review.state
                case .confirmed, .automatic:
                    review.suggestedParticipantID == nil ? .unknown : .suggested
                }
                let reopenedState: SpeakerMatchState = suggestion == nil ? .unknown : decidedState
                let confidenceBand = reopenedState == .suggested ? "review" : "none"
                let changed = try transaction.execute(
                    "UPDATE speaker_assignments SET participant_id = ?, state = ?, "
                        + "confidence_band = ?, reviewed_at = NULL, updated_at = ? "
                        + "WHERE cluster_id = ?",
                    [
                        suggestion ?? Value.null,
                        reopenedState.rawValue,
                        confidenceBand,
                        date.timeIntervalSince1970,
                        review.clusterID.rawValue.uuidString,
                    ]
                )
                guard changed == 1 else {
                    throw CallStoreError.speakerClusterNotFound(review.clusterID)
                }
                transaction.commit()
            } catch {
                transaction.rollback()
                throw error
            }
        }
    }

    func voiceProfileSummaries(at date: Date = Date()) throws -> [VoiceProfileSummary] {
        try connection.query(
            "SELECT participants.id, COUNT(participant_voice_samples.id), "
                + "MAX(participant_voice_samples.created_at), "
                + "(SELECT COUNT(*) FROM voice_sample_recovery recovery "
                + "WHERE recovery.participant_id = participants.id COLLATE NOCASE AND recovery.purge_after > ?) "
                + "FROM participants LEFT JOIN participant_voice_samples "
                + "ON participant_voice_samples.participant_id = participants.id COLLATE NOCASE "
                + "GROUP BY participants.id ORDER BY participants.normalized_name",
            [date.timeIntervalSince1970]
        ).map { row in
            VoiceProfileSummary(
                participantID: ParticipantID(rawValue: try Self.uuid(from: row.getString(0))),
                confirmedSampleCount: try row.getInt(1),
                recoverableSampleCount: try row.getInt(3),
                lastConfirmedAt: try Self.optionalDate(row.get(2))
            )
        }
    }

    func resetVoiceProfile(
        participantID: ParticipantID,
        at date: Date
    ) async throws -> Int {
        try await withWriteRetry {
            let transaction = try connection.transaction()
            do {
                guard try transaction.query(
                    "SELECT 1 FROM participants WHERE id = ? COLLATE NOCASE",
                    [participantID.rawValue.uuidString]
                ).next() != nil else { throw CallStoreError.participantNotFound(participantID) }
                _ = try transaction.execute(
                    "INSERT OR REPLACE INTO voice_sample_recovery ("
                        + "id, participant_id, model_version, encrypted_embedding, speech_ms, "
                        + "confirmed_call_id, created_at, deleted_at, purge_after"
                        + ") SELECT id, participant_id, model_version, encrypted_embedding, speech_ms, "
                        + "confirmed_call_id, created_at, ?, ? FROM participant_voice_samples "
                        + "WHERE participant_id = ? COLLATE NOCASE",
                    [
                        date.timeIntervalSince1970,
                        date.addingTimeInterval(24 * 60 * 60).timeIntervalSince1970,
                        participantID.rawValue.uuidString,
                    ]
                )
                let deleted = try transaction.execute(
                    "DELETE FROM participant_voice_samples WHERE participant_id = ? COLLATE NOCASE",
                    [participantID.rawValue.uuidString]
                )
                transaction.commit()
                return deleted
            } catch {
                transaction.rollback()
                throw error
            }
        }
    }

    func restoreVoiceProfile(
        participantID: ParticipantID,
        at date: Date = Date()
    ) async throws -> Int {
        try await withWriteRetry {
            let transaction = try connection.transaction()
            do {
                let restored = try transaction.execute(
                    "INSERT OR IGNORE INTO participant_voice_samples ("
                        + "id, participant_id, model_version, encrypted_embedding, speech_ms, "
                        + "confirmed_call_id, created_at, source_cluster_id"
                        + ") SELECT id, participant_id, model_version, encrypted_embedding, speech_ms, "
                        + "confirmed_call_id, created_at, NULL FROM voice_sample_recovery "
                        + "WHERE participant_id = ? COLLATE NOCASE AND purge_after > ?",
                    [participantID.rawValue.uuidString, date.timeIntervalSince1970]
                )
                _ = try transaction.execute(
                    "DELETE FROM voice_sample_recovery WHERE participant_id = ? COLLATE NOCASE",
                    [participantID.rawValue.uuidString]
                )
                transaction.commit()
                return restored
            } catch {
                transaction.rollback()
                throw error
            }
        }
    }

    func purgeExpiredVoiceProfileRecovery(at date: Date) async throws -> Int {
        try await withWriteRetry {
            try connection.execute(
                "DELETE FROM voice_sample_recovery WHERE purge_after <= ?",
                [date.timeIntervalSince1970]
            )
        }
    }

    func purgeExpiredPendingSpeakerClusters(at date: Date) async throws -> Int {
        try await withWriteRetry {
            try connection.execute(
                "DELETE FROM pending_speaker_clusters WHERE expires_at <= ? "
                    + "AND NOT EXISTS (SELECT 1 FROM speaker_assignments assignments "
                    + "WHERE assignments.cluster_id = pending_speaker_clusters.id "
                    + "AND assignments.state IN ('suggested','unknown') "
                    + "AND assignments.reviewed_at IS NULL)",
                [date.timeIntervalSince1970]
            )
        }
    }

    public func saveTranscript(
        _ transcript: TranscriptRecord,
        queueIndexing: Bool = true
    ) async throws {
        try await withWriteRetry {
            guard try callExists(transcript.callID) else {
                throw CallStoreError.callNotFound(transcript.callID)
            }
            let transaction = try connection.transaction()
            let now = Date().timeIntervalSince1970
            do {
                _ = try transaction.execute(
                    "INSERT INTO transcripts (call_id, language, model, text, markdown_path, json_path) "
                        + "VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(call_id) DO UPDATE SET "
                        + "language = excluded.language, model = excluded.model, "
                        + "text = excluded.text, markdown_path = excluded.markdown_path, "
                        + "json_path = excluded.json_path",
                    [
                        transcript.callID.rawValue.uuidString,
                        transcript.language,
                        transcript.model,
                        transcript.text,
                        transcript.markdownPath,
                        transcript.jsonPath,
                    ]
                )
                _ = try transaction.execute(
                    "INSERT INTO index_jobs (call_id, status, error) VALUES (?, 'pending', NULL) "
                        + "ON CONFLICT(call_id) DO UPDATE SET status = 'pending', error = NULL",
                    [transcript.callID.rawValue.uuidString]
                )
                if queueIndexing {
                    _ = try transaction.execute(
                        "INSERT INTO processing_jobs ("
                            + "call_id, stage, execution_state, attempt_count, created_at, updated_at"
                            + ") VALUES (?, 'indexing', 'pending', 0, ?, ?) "
                            + "ON CONFLICT(call_id) DO UPDATE SET stage = 'indexing', "
                            + "execution_state = 'pending', updated_at = excluded.updated_at, "
                            + "started_at = NULL, completed_at = NULL, latest_event_id = NULL, "
                            + "claim_token = NULL",
                        [transcript.callID.rawValue.uuidString, now, now]
                    )
                    _ = try transaction.execute(
                        "UPDATE calls SET status = 'indexing' WHERE id = ?",
                        [transcript.callID.rawValue.uuidString]
                    )
                }
                transaction.commit()
            } catch {
                transaction.rollback()
                throw error
            }
        }
    }

    public func deleteCall(_ callID: CallID) async throws {
        try await withWriteRetry {
            let transaction = try connection.transaction()
            do {
                _ = try transaction.execute(
                    "DELETE FROM call_participants WHERE call_id = ?",
                    [callID.rawValue.uuidString]
                )
                _ = try transaction.execute(
                    "DELETE FROM index_jobs WHERE call_id = ?",
                    [callID.rawValue.uuidString]
                )
                _ = try transaction.execute(
                    "DELETE FROM transcripts WHERE call_id = ?",
                    [callID.rawValue.uuidString]
                )
                _ = try transaction.execute(
                    "DELETE FROM calls WHERE id = ?",
                    [callID.rawValue.uuidString]
                )
                transaction.commit()
            } catch {
                transaction.rollback()
                throw error
            }
        }
    }

    /// A recording that a previous launch left open.
    ///
    /// The app writes the call row before it opens the microphone, so a crash, a force quit, or a
    /// power loss leaves a call that still says it is recording. Nothing owns that row afterwards:
    /// the capture session is gone, so no stage will ever finish it and no retry can. Reporting
    /// them lets launch close them out instead of leaving a live-looking recording in the list for
    /// ever.
    public struct InterruptedRecording: Equatable, Sendable {
        public let callID: CallID
        public let startedAt: Date

        public init(callID: CallID, startedAt: Date) {
            self.callID = callID
            self.startedAt = startedAt
        }
    }

    public func interruptedRecordings() throws -> [InterruptedRecording] {
        try connection.query(
            "SELECT id, started_at FROM calls WHERE status = 'recording' "
                + "ORDER BY started_at, id",
            []
        ).map { row in
            InterruptedRecording(
                callID: CallID(rawValue: try Self.uuid(from: row.getString(0))),
                startedAt: Date(timeIntervalSince1970: try row.getDouble(1))
            )
        }
    }

    public func updateTranscriptPath(callID: CallID, markdownPath: String) async throws {
        try await withWriteRetry {
            _ = try connection.execute(
                "UPDATE transcripts SET markdown_path = ? WHERE call_id = ?",
                [markdownPath, callID.rawValue.uuidString]
            )
        }
    }

    public func updateTranscriptPaths(
        callID: CallID,
        markdownPath: String,
        jsonPath: String
    ) async throws {
        try await withWriteRetry {
            let changed = try connection.execute(
                "UPDATE transcripts SET markdown_path = ?, json_path = ? WHERE call_id = ?",
                [markdownPath, jsonPath, callID.rawValue.uuidString]
            )
            guard changed == 1 else { throw CallStoreError.callNotFound(callID) }
        }
    }

    public func pendingIndexCallIDs() throws -> [CallID] {
        try connection.query(
            "SELECT call_id FROM index_jobs WHERE status = 'pending' ORDER BY call_id"
        ).map { row in
            CallID(rawValue: try Self.uuid(from: row.getString(0)))
        }
    }

    public func indexIsReady(for callID: CallID) throws -> Bool {
        guard let row = try connection.query(
            "SELECT status FROM index_jobs WHERE call_id = ?",
            [callID.rawValue.uuidString]
        ).next() else { return false }
        return try row.getString(0) == "ready"
    }

    public func markIndexReady(for callID: CallID) async throws {
        _ = try await withWriteRetry {
            try connection.execute(
                "UPDATE index_jobs SET status = 'ready', error = NULL WHERE call_id = ?",
                [callID.rawValue.uuidString]
            )
        }
    }

    /// Records whether the other side of a call was captured.
    ///
    /// The answer is measured while the two source files still exist and read long after the
    /// cleanup has removed them, so it belongs in the row. Nil writes unknown, which is what every
    /// call recorded before this column existed carries.
    public func setSystemAudio(_ state: SystemAudioState?, for callID: CallID) async throws {
        _ = try await withWriteRetry {
            try connection.execute(
                "UPDATE calls SET system_audio = ? WHERE id = ?",
                [state.map { Value.text($0.rawValue) } ?? Value.null, callID.rawValue.uuidString]
            )
        }
    }

    public func processingJobs() throws -> [ProcessingJob] {
        try connection.query(
            "SELECT call_id, stage, execution_state, attempt_count, created_at, updated_at, "
                + "started_at, completed_at, latest_event_id FROM processing_jobs "
                + "ORDER BY created_at, call_id"
        ).map(Self.processingJob)
    }

    public func claimNextProcessingJob(
        at date: Date = Date(),
        executableOnly: Bool = false
    ) async throws -> ProcessingJob? {
        let claimToken = UUID().uuidString
        let changed = try await withWriteRetry {
            try connection.execute(
                "UPDATE processing_jobs SET execution_state = 'running', "
                    + "attempt_count = attempt_count + 1, updated_at = ?, started_at = ?, "
                    + "completed_at = NULL, claim_token = ? WHERE call_id = ("
                    + "SELECT call_id FROM processing_jobs WHERE execution_state = 'pending' "
                    + "AND (? = 0 OR stage != 'awaitingParticipants') "
                    + "ORDER BY created_at, call_id LIMIT 1"
                    + ") AND execution_state = 'pending'",
                [
                    date.timeIntervalSince1970,
                    date.timeIntervalSince1970,
                    claimToken,
                    executableOnly ? 1 : 0,
                ]
            )
        }
        guard changed == 1 else { return nil }
        guard let row = try connection.query(
            "SELECT call_id, stage, execution_state, attempt_count, created_at, updated_at, "
                + "started_at, completed_at, latest_event_id FROM processing_jobs "
                + "WHERE claim_token = ?",
            [claimToken]
        ).next() else {
            throw CallStoreError.invalidStoredIdentifier(claimToken)
        }
        return try Self.processingJob(from: row)
    }

    public func resetInterruptedProcessingJobs(at date: Date = Date()) async throws {
        _ = try await withWriteRetry {
            try connection.execute(
                "UPDATE processing_jobs SET execution_state = 'pending', updated_at = ?, "
                    + "started_at = NULL, completed_at = NULL, claim_token = NULL "
                    + "WHERE execution_state = 'running'",
                [date.timeIntervalSince1970]
            )
        }
    }

    /// Marks a call's indexing job done when the work was already done outside the pipeline.
    ///
    /// A repair that rewrites a saved transcript and then indexes it itself has finished the whole
    /// job the pipeline was going to do. Writing the transcript still stages an indexing job,
    /// because that is what a transcript write normally needs, so the repair left one behind for
    /// every file it touched: 47 calls sat in the queue with their index already built, and the
    /// Recovery pane counted them as still processing until the next launch drained them. The
    /// queue is meant to hold work that is owed, so the row is closed here instead.
    ///
    /// Only a job that is still pending is settled. A job the pipeline has already claimed is
    /// running somewhere else, and changing it here would race that work.
    @discardableResult
    public func settleIndexedProcessingJob(
        callID: CallID,
        at date: Date = Date()
    ) async throws -> Bool {
        try await withWriteRetry {
            try connection.execute(
                "UPDATE processing_jobs SET stage = 'ready', execution_state = 'complete', "
                    + "updated_at = ?, completed_at = ?, started_at = NULL, claim_token = NULL "
                    + "WHERE call_id = ? AND stage = 'indexing' AND execution_state = 'pending'",
                [date.timeIntervalSince1970, date.timeIntervalSince1970, callID.rawValue.uuidString]
            ) == 1
        }
    }

    /// Closes every queued indexing job whose index is already built.
    ///
    /// This is the same repair as settling one call, applied to a library instead of to one row,
    /// and it is what a launch needs. A repair that indexed a whole folder left one pending row per
    /// file it touched, so the queue held 47 calls that owed nothing and the Recovery pane
    /// reported them as still processing. Draining that queue instead would re-read every
    /// transcript and then run the stage after indexing, which fails for a call whose audio has
    /// been cleaned up: work that is already done must not be re-run just to clear a row.
    ///
    /// Returns how many rows were closed, so a caller can report what it did.
    @discardableResult
    public func settleCompletedIndexingJobs(at date: Date = Date()) async throws -> Int {
        try await withWriteRetry {
            try connection.execute(
                "UPDATE processing_jobs SET stage = 'ready', execution_state = 'complete', "
                    + "updated_at = ?, completed_at = ?, started_at = NULL, claim_token = NULL "
                    + "WHERE stage = 'indexing' AND execution_state = 'pending' AND EXISTS ("
                    + "SELECT 1 FROM index_jobs WHERE index_jobs.call_id = processing_jobs.call_id "
                    + "AND index_jobs.status = 'ready')",
                [date.timeIntervalSince1970, date.timeIntervalSince1970]
            )
        }
    }

    public func returnProcessingJobToPending(
        callID: CallID,
        stage: ProcessingStage,
        at date: Date = Date()
    ) async throws {
        let changed = try await withWriteRetry {
            try connection.execute(
                "UPDATE processing_jobs SET execution_state = 'pending', updated_at = ?, "
                    + "started_at = NULL, completed_at = NULL, claim_token = NULL "
                    + "WHERE call_id = ? AND stage = ? AND execution_state = 'running'",
                [date.timeIntervalSince1970, callID.rawValue.uuidString, stage.rawValue]
            )
        }
        guard changed == 1 else { throw CallStoreError.processingJobNotClaimed(callID) }
    }

    /// Ends a stage the user stopped, and says what the call is now doing.
    ///
    /// The stage runner polls a flag while it waits for its process, so a run that has to be
    /// stopped ends itself and lands here. The claim goes back to pending, which is the state the
    /// queue already knows how to pick up. Nothing else moves: the audio, the transcript, and
    /// every finished stage stay exactly where they were.
    public func stopProcessingJob(
        callID: CallID,
        stage: ProcessingStage,
        at date: Date = Date()
    ) async throws {
        try await withWriteRetry {
            let transaction = try connection.transaction()
            do {
                let changed = try transaction.execute(
                    "UPDATE processing_jobs SET execution_state = 'pending', updated_at = ?, "
                        + "started_at = NULL, completed_at = NULL, claim_token = NULL "
                        + "WHERE call_id = ? AND stage = ? AND execution_state = 'running'",
                    [date.timeIntervalSince1970, callID.rawValue.uuidString, stage.rawValue]
                )
                guard changed == 1 else {
                    throw CallStoreError.processingJobNotClaimed(callID)
                }
                // Only a stopped transcription changes what the call says. The row that read
                // "Transcribing" would otherwise keep claiming work that is not happening. A
                // stopped later stage keeps its own wording, because the transcript is already
                // written and "Waiting to transcribe" would be the wrong sentence for it.
                if stage == .transcribing {
                    _ = try transaction.execute(
                        "UPDATE calls SET status = ? WHERE id = ? AND status = ?",
                        [
                            CallStatus.metadata.rawValue,
                            callID.rawValue.uuidString,
                            CallStatus.transcribing.rawValue,
                        ]
                    )
                }
                transaction.commit()
            } catch {
                transaction.rollback()
                throw error
            }
        }
    }

    public func retryProcessingJob(
        callID: CallID,
        at date: Date = Date()
    ) async throws {
        guard let job = try processingJob(callID: callID), job.executionState == .failed else {
            throw CallStoreError.processingJobNotClaimed(callID)
        }
        try await withWriteRetry {
            let transaction = try connection.transaction()
            do {
                let changed = try transaction.execute(
                    "UPDATE processing_jobs SET execution_state = 'pending', updated_at = ?, "
                        + "started_at = NULL, completed_at = NULL, claim_token = NULL "
                        + "WHERE call_id = ? AND execution_state = 'failed'",
                    [date.timeIntervalSince1970, callID.rawValue.uuidString]
                )
                guard changed == 1 else {
                    throw CallStoreError.processingJobNotClaimed(callID)
                }
                if let status = Self.callStatus(for: job.stage) {
                    _ = try transaction.execute(
                        "UPDATE calls SET status = ? WHERE id = ?",
                        [status.rawValue, callID.rawValue.uuidString]
                    )
                }
                transaction.commit()
            } catch {
                transaction.rollback()
                throw error
            }
        }
    }

    public func retrySpeakerAnalysis(callID: CallID, at date: Date = Date()) async throws {
        try await withWriteRetry {
            let transaction = try connection.transaction()
            do {
                let changed = try transaction.execute(
                    "UPDATE processing_jobs SET stage = 'diarizing', execution_state = 'pending', "
                        + "updated_at = ?, started_at = NULL, completed_at = NULL, claim_token = NULL "
                        + "WHERE call_id = ? AND execution_state IN ('complete','failed') "
                        + "AND EXISTS (SELECT 1 FROM transcripts WHERE call_id = ?) "
                        + "AND EXISTS (SELECT 1 FROM calls WHERE id = ? AND status IN ('ready','failed'))",
                    [date.timeIntervalSince1970, callID.rawValue.uuidString,
                     callID.rawValue.uuidString, callID.rawValue.uuidString]
                )
                guard changed == 1 else { throw CallStoreError.processingJobNotClaimed(callID) }
                _ = try transaction.execute("UPDATE calls SET status = 'transcribing' WHERE id = ?",
                    [callID.rawValue.uuidString])
                transaction.commit()
            } catch {
                transaction.rollback()
                throw error
            }
        }
    }

    @discardableResult
    public func reconcileFailedIndexingJobs(at date: Date = Date()) async throws -> Int {
        try await withWriteRetry {
            let transaction = try connection.transaction()
            do {
                let changed = try transaction.execute(
                    "UPDATE calls SET status = 'ready' WHERE id IN ("
                        + "SELECT j.call_id FROM processing_jobs j "
                        + "JOIN index_jobs i ON i.call_id = j.call_id "
                        + "WHERE j.stage = 'indexing' AND j.execution_state = 'failed' "
                        + "AND i.status = 'ready')",
                    []
                )
                let jobChanges = try transaction.execute(
                    "UPDATE processing_jobs SET stage = 'finalizingArtifacts', "
                        + "execution_state = 'pending', started_at = NULL, "
                        + "completed_at = NULL, claim_token = NULL, updated_at = ? "
                        + "WHERE stage = 'indexing' AND execution_state = 'failed' "
                        + "AND EXISTS (SELECT 1 FROM index_jobs i "
                        + "WHERE i.call_id = processing_jobs.call_id AND i.status = 'ready')",
                    [date.timeIntervalSince1970]
                )
                transaction.commit()
                return jobChanges
            } catch {
                transaction.rollback()
                throw error
            }
        }
    }

    public func advanceProcessingJob(
        callID: CallID,
        from currentStage: ProcessingStage,
        to nextStage: ProcessingStage,
        at date: Date = Date()
    ) async throws -> ProcessingJob {
        guard Self.nextStage(after: currentStage) == nextStage else {
            throw CallStoreError.invalidProcessingTransition(
                from: currentStage,
                to: nextStage
            )
        }
        let nextExecutionState = nextStage == .ready
            ? ProcessingExecutionState.complete
            : .pending
        try await withWriteRetry {
            let transaction = try connection.transaction()
            do {
                let changed = try transaction.execute(
                    "UPDATE processing_jobs SET stage = ?, execution_state = ?, "
                        + "updated_at = ?, started_at = NULL, "
                        + "completed_at = CASE WHEN ? = 'complete' THEN ? ELSE NULL END, "
                        + "claim_token = NULL "
                        + "WHERE call_id = ? AND stage = ? AND execution_state = 'running'",
                    [
                        nextStage.rawValue,
                        nextExecutionState.rawValue,
                        date.timeIntervalSince1970,
                        nextExecutionState.rawValue,
                        date.timeIntervalSince1970,
                        callID.rawValue.uuidString,
                        currentStage.rawValue,
                    ]
                )
                guard changed == 1 else {
                    throw CallStoreError.processingJobNotClaimed(callID)
                }
                if let status = Self.callStatus(for: nextStage) {
                    _ = try transaction.execute(
                        "UPDATE calls SET status = ? WHERE id = ?",
                        [status.rawValue, callID.rawValue.uuidString]
                    )
                }
                transaction.commit()
            } catch {
                transaction.rollback()
                throw error
            }
        }
        guard let job = try processingJob(callID: callID) else {
            throw CallStoreError.processingJobNotClaimed(callID)
        }
        return job
    }

    public func failProcessingJob(
        callID: CallID,
        stage: ProcessingStage,
        summary: String,
        errorType: String? = nil,
        details: String? = nil,
        stderr: String? = nil,
        at date: Date = Date()
    ) async throws -> ProcessingEvent {
        let event = ProcessingEvent(
            id: UUID(),
            callID: callID,
            stage: stage,
            severity: .error,
            summary: summary,
            errorType: errorType,
            details: details,
            stderr: stderr,
            createdAt: date
        )
        try await withWriteRetry {
            let transaction = try connection.transaction()
            do {
                _ = try transaction.execute(
                    "INSERT INTO processing_events ("
                        + "id, call_id, stage, severity, summary, error_type, details, stderr, created_at"
                        + ") VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                    [
                        event.id.uuidString,
                        callID.rawValue.uuidString,
                        stage.rawValue,
                        event.severity.rawValue,
                        summary,
                        errorType ?? Value.null,
                        details ?? Value.null,
                        stderr ?? Value.null,
                        date.timeIntervalSince1970,
                    ]
                )
                let changed = try transaction.execute(
                    "UPDATE processing_jobs SET execution_state = 'failed', updated_at = ?, "
                        + "started_at = NULL, completed_at = NULL, latest_event_id = ?, "
                        + "claim_token = NULL WHERE call_id = ? AND stage = ? "
                        + "AND execution_state = 'running'",
                    [
                        date.timeIntervalSince1970,
                        event.id.uuidString,
                        callID.rawValue.uuidString,
                        stage.rawValue,
                    ]
                )
                guard changed == 1 else {
                    throw CallStoreError.processingJobNotClaimed(callID)
                }
                _ = try transaction.execute(
                    "UPDATE calls SET status = 'failed' WHERE id = ?",
                    [callID.rawValue.uuidString]
                )
                transaction.commit()
            } catch {
                transaction.rollback()
                throw error
            }
        }
        return event
    }

    public func processingEvents(for callID: CallID) throws -> [ProcessingEvent] {
        try connection.query(
            "SELECT id, call_id, stage, severity, summary, error_type, details, stderr, created_at "
                + "FROM processing_events WHERE call_id = ? ORDER BY created_at, id",
            [callID.rawValue.uuidString]
        ).map(Self.processingEvent)
    }

    @discardableResult
    public func recordProcessingWarning(
        callID: CallID,
        stage: ProcessingStage,
        summary: String,
        errorType: String? = nil,
        at date: Date = Date()
    ) async throws -> ProcessingEvent {
        let event = ProcessingEvent(
            id: UUID(),
            callID: callID,
            stage: stage,
            severity: .warning,
            summary: summary,
            errorType: errorType,
            details: nil,
            stderr: nil,
            createdAt: date
        )
        try await withWriteRetry {
            let transaction = try connection.transaction()
            do {
                guard try callExists(callID) else { throw CallStoreError.callNotFound(callID) }
                _ = try transaction.execute(
                    "INSERT INTO processing_events ("
                        + "id, call_id, stage, severity, summary, error_type, details, stderr, created_at"
                        + ") VALUES (?, ?, ?, ?, ?, ?, NULL, NULL, ?)",
                    [
                        event.id.uuidString,
                        callID.rawValue.uuidString,
                        stage.rawValue,
                        event.severity.rawValue,
                        summary,
                        errorType ?? Value.null,
                        date.timeIntervalSince1970,
                    ]
                )
                _ = try transaction.execute(
                    "UPDATE processing_jobs SET latest_event_id = ?, updated_at = ? WHERE call_id = ?",
                    [
                        event.id.uuidString,
                        date.timeIntervalSince1970,
                        callID.rawValue.uuidString,
                    ]
                )
                transaction.commit()
            } catch {
                transaction.rollback()
                throw error
            }
        }
        return event
    }

    public func recentProcessingEvents(limit: Int = 100) throws -> [ProcessingEvent] {
        guard (1...500).contains(limit) else { throw CallStoreError.invalidLimit }
        return try connection.query(
            "SELECT id, call_id, stage, severity, summary, error_type, details, stderr, created_at "
                + "FROM processing_events ORDER BY created_at DESC, id LIMIT ?",
            [limit]
        ).map(Self.processingEvent)
    }

    public func createBackup(
        in directory: URL,
        at date: Date = Date()
    ) async throws -> URL {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "calls-\(formatter.string(from: date))-\(UUID().uuidString.prefix(8)).db"
        let destination = directory.appending(path: name)
        _ = try await withWriteRetry {
            let backupConnection = try database.connect()
            try backupConnection.executeBatch(Self.connectionPragmas)
            return try backupConnection.execute("VACUUM INTO ?", [destination.path])
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: destination.path
        )
        guard try Self.prepareBackupForStorage(at: destination).isHealthy else {
            throw CallStoreError.backupIntegrityFailed(destination.path)
        }
        try Self.removeBackupSidecars(for: destination)
        try Self.pruneBackups(in: directory, preserving: destination, keeping: 3)
        return destination
    }

    public func integrityReport() throws -> DatabaseIntegrityReport {
        try Self.integrityReport(connection: connection)
    }

    public static func integrityReport(at databaseURL: URL) throws -> DatabaseIntegrityReport {
        let database = try Database(databaseURL.path)
        let connection = try database.connect()
        return try integrityReport(connection: connection)
    }

    private func migrateProcessingSchema() throws {
        try connection.executeBatch(Self.migrationLedgerSchema)
        guard try connection.query(
            "SELECT 1 FROM call_recorder_migrations WHERE id = ? LIMIT 1",
            [Self.processingMigrationID]
        ).next() == nil else { return }

        let transaction = try connection.transaction()
        do {
            do {
                try transaction.executeBatch(Self.processingMigrationSchema)
            } catch {
                throw CallStoreError.migrationStepFailed(1, String(reflecting: error))
            }
            try Self.ensureForeignKeyIntegrity(transaction)
            _ = try transaction.execute(
                "INSERT INTO call_recorder_migrations (id, applied_at) VALUES (?, ?)",
                [Self.processingMigrationID, Date().timeIntervalSince1970]
            )
            transaction.commit()
        } catch {
            transaction.rollback()
            throw error
        }
    }

    private func migrateParticipantProfileSchema() throws {
        guard try connection.query(
            "SELECT 1 FROM call_recorder_migrations WHERE id = ? LIMIT 1",
            [Self.participantProfileMigrationID]
        ).next() == nil else { return }

        let transaction = try connection.transaction()
        do {
            do {
                try transaction.executeBatch(Self.participantProfileMigrationSchema)
            } catch {
                throw CallStoreError.migrationStepFailed(2, String(reflecting: error))
            }
            try Self.ensureForeignKeyIntegrity(transaction)
            _ = try transaction.execute(
                "INSERT INTO call_recorder_migrations (id, applied_at) VALUES (?, ?)",
                [Self.participantProfileMigrationID, Date().timeIntervalSince1970]
            )
            transaction.commit()
        } catch {
            transaction.rollback()
            throw error
        }
    }

    private func migrateSpeakerIdentitySchema() throws {
        guard try connection.query(
            "SELECT 1 FROM call_recorder_migrations WHERE id = ? LIMIT 1",
            [Self.speakerIdentityMigrationID]
        ).next() == nil else { return }

        let transaction = try connection.transaction()
        do {
            do {
                try transaction.executeBatch(Self.speakerIdentityMigrationSchema)
            } catch {
                throw CallStoreError.migrationStepFailed(3, String(reflecting: error))
            }
            try Self.ensureForeignKeyIntegrity(transaction)
            _ = try transaction.execute(
                "INSERT INTO call_recorder_migrations (id, applied_at) VALUES (?, ?)",
                [Self.speakerIdentityMigrationID, Date().timeIntervalSince1970]
            )
            transaction.commit()
        } catch {
            transaction.rollback()
            throw error
        }
    }

    private func migrateSpeakerReviewSchema() throws {
        guard try connection.query(
            "SELECT 1 FROM call_recorder_migrations WHERE id = ? LIMIT 1",
            [Self.speakerReviewMigrationID]
        ).next() == nil else { return }

        let transaction = try connection.transaction()
        do {
            do {
                try transaction.executeBatch(Self.speakerReviewMigrationSchema)
            } catch {
                throw CallStoreError.migrationStepFailed(4, String(reflecting: error))
            }
            try Self.ensureForeignKeyIntegrity(transaction)
            _ = try transaction.execute(
                "INSERT INTO call_recorder_migrations (id, applied_at) VALUES (?, ?)",
                [Self.speakerReviewMigrationID, Date().timeIntervalSince1970]
            )
            transaction.commit()
        } catch {
            transaction.rollback()
            throw error
        }
    }

    private func migrateSpeakerReviewRequestSchema() throws {
        guard try connection.query(
            "SELECT 1 FROM call_recorder_migrations WHERE id = ? LIMIT 1",
            [Self.speakerReviewRequestMigrationID]
        ).next() == nil else { return }

        let transaction = try connection.transaction()
        do {
            do {
                try transaction.executeBatch(Self.speakerReviewRequestMigrationSchema)
            } catch {
                throw CallStoreError.migrationStepFailed(5, String(reflecting: error))
            }
            try Self.ensureForeignKeyIntegrity(transaction)
            _ = try transaction.execute(
                "INSERT INTO call_recorder_migrations (id, applied_at) VALUES (?, ?)",
                [Self.speakerReviewRequestMigrationID, Date().timeIntervalSince1970]
            )
            transaction.commit()
        } catch {
            transaction.rollback()
            throw error
        }
    }

    /// Adds the reopen action to the request ledger so a decided speaker can go back to review.
    /// The table must be rebuilt because SQLite cannot widen a CHECK constraint in place.
    /// The rebuild runs on its own connection: SQLite rejects DROP TABLE while the long-lived
    /// connection still holds a foreign-key check cursor over the table.
    private func migrateSpeakerReopenSchema() throws {
        let migrationConnection = try database.connect()
        try migrationConnection.executeBatch(Self.connectionPragmas)
        guard try migrationConnection.query(
            "SELECT 1 FROM call_recorder_migrations WHERE id = ? LIMIT 1",
            [Self.speakerReopenMigrationID]
        ).next() == nil else { return }

        let transaction = try migrationConnection.transaction()
        do {
            do {
                for statement in Self.speakerReopenMigrationStatements {
                    _ = try transaction.execute(statement)
                }
            } catch {
                throw CallStoreError.migrationStepFailed(6, String(reflecting: error))
            }
            try Self.ensureForeignKeyIntegrity(transaction)
            _ = try transaction.execute(
                "INSERT INTO call_recorder_migrations (id, applied_at) VALUES (?, ?)",
                [Self.speakerReopenMigrationID, Date().timeIntervalSince1970]
            )
            transaction.commit()
        } catch {
            transaction.rollback()
            throw error
        }
    }

    private func callExists(_ callID: CallID) throws -> Bool {
        try connection.query(
            "SELECT 1 FROM calls WHERE id = ? LIMIT 1",
            [callID.rawValue.uuidString]
        ).next() != nil
    }

    private func migrateSpeakerLineRequestSchema() throws {
        let migrationConnection = try database.connect()
        try migrationConnection.executeBatch(Self.connectionPragmas)
        guard try migrationConnection.query(
            "SELECT 1 FROM call_recorder_migrations WHERE id = ? LIMIT 1",
            [Self.speakerLineRequestMigrationID]
        ).next() == nil else { return }

        let transaction = try migrationConnection.transaction()
        do {
            do {
                for statement in Self.speakerLineRequestMigrationStatements {
                    _ = try transaction.execute(statement)
                }
            } catch {
                throw CallStoreError.migrationStepFailed(8, String(reflecting: error))
            }
            try Self.ensureForeignKeyIntegrity(transaction)
            _ = try transaction.execute(
                "INSERT INTO call_recorder_migrations (id, applied_at) VALUES (?, ?)",
                [Self.speakerLineRequestMigrationID, Date().timeIntervalSince1970]
            )
            transaction.commit()
        } catch {
            transaction.rollback()
            throw error
        }
    }

    /// Adds the column that says whether the other side of a call was captured.
    ///
    /// The measurement needs the source files, and the cleanup removes them. After that the only
    /// place the answer can live is the call's own row, which is also where the surface reads it.
    private func migrateSystemAudioSchema() throws {
        let migrationConnection = try database.connect()
        try migrationConnection.executeBatch(Self.connectionPragmas)
        guard try migrationConnection.query(
            "SELECT 1 FROM call_recorder_migrations WHERE id = ? LIMIT 1",
            [Self.systemAudioMigrationID]
        ).next() == nil else { return }

        let transaction = try migrationConnection.transaction()
        do {
            do {
                _ = try transaction.execute(Self.systemAudioSchema)
            } catch {
                throw CallStoreError.migrationStepFailed(9, String(reflecting: error))
            }
            try Self.ensureForeignKeyIntegrity(transaction)
            _ = try transaction.execute(
                "INSERT INTO call_recorder_migrations (id, applied_at) VALUES (?, ?)",
                [Self.systemAudioMigrationID, Date().timeIntervalSince1970]
            )
            transaction.commit()
        } catch {
            transaction.rollback()
            throw error
        }
    }

    private func migrateSpeakerLineOverrideSchema() throws {
        let migrationConnection = try database.connect()
        try migrationConnection.executeBatch(Self.connectionPragmas)
        guard try migrationConnection.query(
            "SELECT 1 FROM call_recorder_migrations WHERE id = ? LIMIT 1",
            [Self.speakerLineOverrideMigrationID]
        ).next() == nil else { return }

        let transaction = try migrationConnection.transaction()
        do {
            do {
                _ = try transaction.execute(Self.speakerLineOverrideSchema)
            } catch {
                throw CallStoreError.migrationStepFailed(7, String(reflecting: error))
            }
            try Self.ensureForeignKeyIntegrity(transaction)
            _ = try transaction.execute(
                "INSERT INTO call_recorder_migrations (id, applied_at) VALUES (?, ?)",
                [Self.speakerLineOverrideMigrationID, Date().timeIntervalSince1970]
            )
            transaction.commit()
        } catch {
            transaction.rollback()
            throw error
        }
    }

    public func processingJob(callID: CallID) throws -> ProcessingJob? {
        guard let row = try connection.query(
            "SELECT call_id, stage, execution_state, attempt_count, created_at, updated_at, "
                + "started_at, completed_at, latest_event_id FROM processing_jobs "
                + "WHERE call_id = ?",
            [callID.rawValue.uuidString]
        ).next() else { return nil }
        return try Self.processingJob(from: row)
    }

    private func withWriteRetry<Result>(
        _ operation: () throws -> Result
    ) async throws -> Result {
        for delay in [250, 500, 1_000, 2_000, 3_000] {
            do {
                return try operation()
            } catch {
                guard Self.isTemporaryWriteLock(error) else { throw error }
                try reconnect()
                try await Task.sleep(for: .milliseconds(delay))
            }
        }
        return try operation()
    }

    private func reconnect() throws {
        connection = try database.connect()
        try connection.executeBatch(Self.connectionPragmas)
    }

    private static func isTemporaryWriteLock(_ error: any Error) -> Bool {
        let message = String(reflecting: error).lowercased()
        return message.contains("database is locked")
            || message.contains("database is busy")
            || message.contains("sqlite_busy")
    }

    private static func ensureForeignKeyIntegrity<Store: Prepareable>(_ store: Store) throws {
        do {
            guard try store.query("PRAGMA foreign_key_check").next() == nil else {
                throw CallStoreError.foreignKeyIntegrityFailed
            }
        } catch let error as CallStoreError {
            throw error
        } catch {
            let message = String(reflecting: error).lowercased()
            guard message.contains("foreign key constraint failed") else { throw error }
            throw CallStoreError.foreignKeyIntegrityFailed
        }
    }

    private static func nextStage(after stage: ProcessingStage) -> ProcessingStage? {
        guard let index = ProcessingStage.allCases.firstIndex(of: stage) else { return nil }
        let nextIndex = ProcessingStage.allCases.index(after: index)
        guard nextIndex < ProcessingStage.allCases.endIndex else { return nil }
        return ProcessingStage.allCases[nextIndex]
    }

    private static func callStatus(for stage: ProcessingStage) -> CallStatus? {
        switch stage {
        case .awaitingParticipants, .queued: .metadata
        case .transcribing, .diarizing, .attributing: .transcribing
        case .indexing: .indexing
        case .finalizingArtifacts: nil
        case .ready: .ready
        }
    }

    private static func cleanedName(_ value: String) throws -> String {
        let cleaned = value.split(whereSeparator: \ .isWhitespace).joined(separator: " ")
        guard !cleaned.isEmpty else { throw CallStoreError.invalidName }
        return cleaned
    }

    private static func normalizedName(_ value: String) -> String {
        value.precomposedStringWithCompatibilityMapping.lowercased()
    }

    private static func cleanedOptional(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = value.split(whereSeparator: \ .isWhitespace).joined(separator: " ")
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func uuid(from value: String) throws -> UUID {
        guard let uuid = UUID(uuidString: value) else {
            throw CallStoreError.invalidStoredIdentifier(value)
        }
        return uuid
    }

    /// Returns the identifier exactly as stored. Foreign keys compare text byte for byte,
    /// so a caller-supplied identifier with different casing fails the constraint.
    private static func storedParticipantID(_ participantID: ParticipantID, in handle: some Prepareable) throws -> String {
        guard let stored = try storedParticipantIDIfPresent(participantID, in: handle) else {
            throw CallStoreError.participantNotFound(participantID)
        }
        return stored
    }

    /// The identifier exactly as stored, or nil when the person is no longer in the table.
    ///
    /// A repair has to survive a row that has gone. Resolving the identifier only to throw would
    /// stop the repair on one stale reference, which is the state that left this library with
    /// speaker names that could not be corrected at all.
    private static func storedParticipantIDIfPresent(
        _ participantID: ParticipantID,
        in handle: some Prepareable
    ) throws -> String? {
        try handle.query(
            "SELECT id FROM participants WHERE id = ? COLLATE NOCASE",
            [participantID.rawValue.uuidString]
        ).next().map { try $0.getString(0) }
    }

    private static func optionalDate(_ value: Value) throws -> Date? {
        switch value {
        case let .real(seconds): return Date(timeIntervalSince1970: seconds)
        case .null: return nil
        default: throw CallStoreError.invalidStoredValue
        }
    }

    private static func optionalString(_ value: Value) throws -> String? {
        switch value {
        case let .text(value): return value
        case .null: return nil
        default: throw CallStoreError.invalidStoredValue
        }
    }

    private static func optionalSystemAudio(_ value: Value) throws -> SystemAudioState? {
        guard let raw = try optionalString(value) else { return nil }
        // An unrecognised label is unknown rather than a reason to refuse the refresh: the value
        // only decides whether a row carries a warning chip.
        return SystemAudioState(rawValue: raw)
    }

    private static func optionalInt(_ value: Value) throws -> Int? {
        switch value {
        case let .integer(value): return Int(value)
        case .null: return nil
        default: throw CallStoreError.invalidStoredValue
        }
    }

    private static func glossaryTerm(from row: Row) throws -> GlossaryTerm {
        let aliasesJSON = try row.getString(2)
        guard let data = aliasesJSON.data(using: .utf8) else {
            throw CallStoreError.invalidStoredAliases
        }
        return GlossaryTerm(
            id: GlossaryTermID(rawValue: try uuid(from: row.getString(0))),
            preferred: try row.getString(1),
            aliases: try JSONDecoder().decode([String].self, from: data)
        )
    }

    private static func participant(from row: Row) throws -> Participant {
        Participant(
            id: ParticipantID(rawValue: try uuid(from: row.getString(0))),
            name: try row.getString(1),
            role: try optionalString(row.get(2)),
            company: try optionalString(row.get(3)),
            email: try optionalString(row.get(4))
        )
    }

    private static func processingJob(from row: Row) throws -> ProcessingJob {
        let stageValue = try row.getString(1)
        guard let stage = ProcessingStage(rawValue: stageValue) else {
            throw CallStoreError.invalidStoredStatus(stageValue)
        }
        let stateValue = try row.getString(2)
        guard let executionState = ProcessingExecutionState(rawValue: stateValue) else {
            throw CallStoreError.invalidStoredStatus(stateValue)
        }
        return ProcessingJob(
            callID: CallID(rawValue: try uuid(from: row.getString(0))),
            stage: stage,
            executionState: executionState,
            attemptCount: try row.getInt(3),
            createdAt: Date(timeIntervalSince1970: try row.getDouble(4)),
            updatedAt: Date(timeIntervalSince1970: try row.getDouble(5)),
            startedAt: try optionalDate(row.get(6)),
            completedAt: try optionalDate(row.get(7)),
            latestEventID: try optionalString(row.get(8)).map(uuid(from:))
        )
    }

    private static func processingEvent(from row: Row) throws -> ProcessingEvent {
        let stageValue = try row.getString(2)
        guard let stage = ProcessingStage(rawValue: stageValue) else {
            throw CallStoreError.invalidStoredStatus(stageValue)
        }
        let severityValue = try row.getString(3)
        guard let severity = ProcessingEventSeverity(rawValue: severityValue) else {
            throw CallStoreError.invalidStoredStatus(severityValue)
        }
        return ProcessingEvent(
            id: try uuid(from: row.getString(0)),
            callID: CallID(rawValue: try uuid(from: row.getString(1))),
            stage: stage,
            severity: severity,
            summary: try row.getString(4),
            errorType: try optionalString(row.get(5)),
            details: try optionalString(row.get(6)),
            stderr: try optionalString(row.get(7)),
            createdAt: Date(timeIntervalSince1970: try row.getDouble(8))
        )
    }

    private static func integrityReport(connection: Connection) throws -> DatabaseIntegrityReport {
        let quickCheckMessages = try connection.query("PRAGMA quick_check").map { row in
            try row.getString(0)
        }
        let foreignKeyViolations = try connection.query("PRAGMA foreign_key_check").map { row in
            try [0, 1, 2, 3]
                .map { try valueDescription(row.get(Int32($0))) }
                .joined(separator: ":")
        }
        return DatabaseIntegrityReport(
            quickCheckMessages: quickCheckMessages,
            foreignKeyViolations: foreignKeyViolations
        )
    }

    private static func prepareBackupForStorage(at databaseURL: URL) throws -> DatabaseIntegrityReport {
        let database = try Database(databaseURL.path)
        let connection = try database.connect()
        try connection.executeBatch("""
            PRAGMA wal_checkpoint(TRUNCATE);
            PRAGMA journal_mode = DELETE;
            """)
        return try integrityReport(connection: connection)
    }

    private static func pruneBackups(
        in directory: URL,
        preserving current: URL,
        keeping limit: Int
    ) throws {
        let backups = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter {
            $0.pathExtension == "db" && $0.lastPathComponent.hasPrefix("calls-")
        }
        let currentName = current.lastPathComponent
        let older = backups
            .filter { $0.lastPathComponent != currentName }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for backup in older.dropFirst(max(0, limit - 1)) {
            try removeBackupSidecars(for: backup)
            try FileManager.default.removeItem(at: backup)
        }
    }

    private static func removeBackupSidecars(for databaseURL: URL) throws {
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(filePath: databaseURL.path + suffix)
            if FileManager.default.fileExists(atPath: sidecar.path) {
                try FileManager.default.removeItem(at: sidecar)
            }
        }
    }

    private static func valueDescription(_ value: Value) throws -> String {
        switch value {
        case let .integer(value): String(value)
        case let .text(value): value
        case let .blob(value): value.base64EncodedString()
        case let .real(value): String(value)
        case .null: "null"
        }
    }

    private static let connectionPragmas = """
        PRAGMA foreign_keys = ON;
        PRAGMA busy_timeout = 3000;
        """

    private static let baseSchema = """
        CREATE TABLE IF NOT EXISTS calls (
            id TEXT PRIMARY KEY,
            started_at REAL NOT NULL,
            ended_at REAL,
            audio_path TEXT,
            status TEXT NOT NULL CHECK(status IN ('recording','metadata','transcribing','indexing','ready','failed'))
        );
        CREATE TABLE IF NOT EXISTS participants (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            normalized_name TEXT NOT NULL UNIQUE
        );
        CREATE TABLE IF NOT EXISTS call_participants (
            call_id TEXT NOT NULL REFERENCES calls(id) ON DELETE CASCADE,
            participant_id TEXT NOT NULL REFERENCES participants(id) ON DELETE RESTRICT,
            PRIMARY KEY (call_id, participant_id)
        );
        CREATE TABLE IF NOT EXISTS glossary_terms (
            id TEXT PRIMARY KEY,
            preferred TEXT NOT NULL,
            normalized_preferred TEXT NOT NULL UNIQUE,
            aliases_json TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS transcripts (
            call_id TEXT PRIMARY KEY REFERENCES calls(id) ON DELETE CASCADE,
            language TEXT NOT NULL,
            model TEXT NOT NULL,
            text TEXT NOT NULL,
            markdown_path TEXT NOT NULL,
            json_path TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS index_jobs (
            call_id TEXT PRIMARY KEY REFERENCES calls(id) ON DELETE CASCADE,
            status TEXT NOT NULL CHECK(status IN ('pending','running','ready','failed')),
            error TEXT
        );
        """

    private static let processingMigrationID = "processing-v1"
    private static let participantProfileMigrationID = "participant-profile-v1"
    private static let speakerIdentityMigrationID = "speaker-identity-v1"
    private static let speakerReviewMigrationID = "speaker-review-v1"
    private static let speakerReviewRequestMigrationID = "speaker-review-request-v1"
    private static let speakerReopenMigrationID = "speaker-review-reopen-v1"

    private static let speakerLineOverrideMigrationID = "speaker-line-override-v1"

    private static let speakerLineRequestMigrationID = "speaker-line-request-v1"

    private static let systemAudioMigrationID = "call-system-audio-v1"

    /// The state of the call's system track, written while its sources are still on disk.
    ///
    /// NULL means unknown: every call recorded before this column existed, and any call whose two
    /// sources could not be told apart when it was transcribed.
    private static let systemAudioSchema = "ALTER TABLE calls ADD COLUMN system_audio TEXT;"

    /// The review-request table with the two line actions.
    ///
    /// A request that names a run of lines carries its range, and one that names a voice does not.
    /// The check states that in the table rather than leaving it to the writer: a row with an
    /// action and no range is a request the app could only fail on, and failing it at the point of
    /// writing is one repair instead of a queue of them.
    ///
    /// A range request names the call rather than the voice, because the lines worth moving are
    /// often on a voice that has already been named or kept anonymous, and neither is in the review
    /// list a caller would otherwise have to look them up in. Exactly one of the two is set: a voice
    /// request has a cluster and a line request has a call.
    private static let speakerLineRequestMigrationStatements = [
        """
        CREATE TABLE speaker_review_requests_rebuild (
            id TEXT PRIMARY KEY,
            cluster_id TEXT REFERENCES pending_speaker_clusters(id) ON DELETE CASCADE,
            call_id TEXT REFERENCES calls(id) ON DELETE CASCADE,
            participant_id TEXT REFERENCES participants(id) ON DELETE RESTRICT,
            action TEXT NOT NULL CHECK(action IN (
                'confirm','keepUnknown','reopen','assignLines','releaseLines'
            )),
            status TEXT NOT NULL CHECK(status IN ('pending','running','completed','failed')),
            start_ms INTEGER,
            end_ms INTEGER,
            error TEXT,
            claim_token TEXT UNIQUE,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            CHECK(
                (action = 'confirm' AND cluster_id IS NOT NULL AND call_id IS NULL
                    AND participant_id IS NOT NULL
                    AND start_ms IS NULL AND end_ms IS NULL)
                OR (action IN ('keepUnknown','reopen') AND cluster_id IS NOT NULL
                    AND call_id IS NULL AND participant_id IS NULL
                    AND start_ms IS NULL AND end_ms IS NULL)
                OR (action = 'assignLines' AND cluster_id IS NULL AND call_id IS NOT NULL
                    AND participant_id IS NOT NULL
                    AND start_ms IS NOT NULL AND end_ms IS NOT NULL AND end_ms > start_ms)
                OR (action = 'releaseLines' AND cluster_id IS NULL AND call_id IS NOT NULL
                    AND participant_id IS NULL
                    AND start_ms IS NOT NULL AND end_ms IS NOT NULL AND end_ms > start_ms)
            )
        )
        """,
        """
        INSERT INTO speaker_review_requests_rebuild
            (id, cluster_id, participant_id, action, status, error, claim_token,
             created_at, updated_at)
            SELECT id, cluster_id, participant_id, action, status, error, claim_token,
                created_at, updated_at
            FROM speaker_review_requests
        """,
        "DROP TABLE speaker_review_requests",
        "ALTER TABLE speaker_review_requests_rebuild RENAME TO speaker_review_requests",
        """
        CREATE UNIQUE INDEX IF NOT EXISTS speaker_review_requests_active
            ON speaker_review_requests(cluster_id)
            WHERE status IN ('pending','running')
        """,
        """
        CREATE UNIQUE INDEX IF NOT EXISTS speaker_review_requests_active_lines
            ON speaker_review_requests(call_id, start_ms, end_ms)
            WHERE status IN ('pending','running') AND action IN ('assignLines','releaseLines')
        """,
    ]

    /// The lines a person was moved onto, per call.
    ///
    /// Keyed by the call and the range the user assigned, so assigning the same excerpt twice
    /// corrects the first answer rather than adding a second. The person is a real reference, so
    /// merging two people carries their corrections with them and deleting one takes them away.
    private static let speakerLineOverrideSchema = """
        CREATE TABLE IF NOT EXISTS speaker_line_overrides (
            call_id TEXT NOT NULL REFERENCES calls(id) ON DELETE CASCADE,
            start_ms INTEGER NOT NULL,
            end_ms INTEGER NOT NULL,
            participant_id TEXT NOT NULL REFERENCES participants(id) ON DELETE CASCADE,
            created_at REAL NOT NULL,
            PRIMARY KEY (call_id, start_ms, end_ms),
            CHECK(end_ms > start_ms)
        );
        CREATE INDEX IF NOT EXISTS speaker_line_overrides_call
            ON speaker_line_overrides(call_id);
        """

    private static let speakerReopenMigrationStatements = [
        """
        CREATE TABLE speaker_review_requests_rebuild (
            id TEXT PRIMARY KEY,
            cluster_id TEXT NOT NULL REFERENCES pending_speaker_clusters(id) ON DELETE CASCADE,
            participant_id TEXT REFERENCES participants(id) ON DELETE RESTRICT,
            action TEXT NOT NULL CHECK(action IN ('confirm','keepUnknown','reopen')),
            status TEXT NOT NULL CHECK(status IN ('pending','running','completed','failed')),
            error TEXT,
            claim_token TEXT UNIQUE,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            CHECK(
                (action = 'confirm' AND participant_id IS NOT NULL)
                OR (action IN ('keepUnknown','reopen') AND participant_id IS NULL)
            )
        )
        """,
        """
        INSERT INTO speaker_review_requests_rebuild
            (id, cluster_id, participant_id, action, status, error, claim_token,
             created_at, updated_at)
            SELECT id, cluster_id, participant_id, action, status, error, claim_token,
                created_at, updated_at
            FROM speaker_review_requests
        """,
        "DROP TABLE speaker_review_requests",
        "ALTER TABLE speaker_review_requests_rebuild RENAME TO speaker_review_requests",
        """
        CREATE UNIQUE INDEX IF NOT EXISTS speaker_review_requests_active
            ON speaker_review_requests(cluster_id)
            WHERE status IN ('pending','running')
        """,
    ]

    private static let migrationLedgerSchema = """
        CREATE TABLE IF NOT EXISTS call_recorder_migrations (
            id TEXT PRIMARY KEY,
            applied_at REAL NOT NULL
        );
        """

    private static let processingMigrationSchema = """
        CREATE TABLE processing_events (
            id TEXT PRIMARY KEY,
            call_id TEXT NOT NULL REFERENCES calls(id) ON DELETE CASCADE,
            stage TEXT NOT NULL CHECK(stage IN (
                'awaitingParticipants','queued','transcribing','diarizing',
                'attributing','indexing','finalizingArtifacts','ready'
            )),
            severity TEXT NOT NULL CHECK(severity IN ('info','warning','error')),
            summary TEXT NOT NULL,
            error_type TEXT,
            details TEXT,
            stderr TEXT,
            created_at REAL NOT NULL
        );

        CREATE TABLE processing_jobs (
            call_id TEXT PRIMARY KEY REFERENCES calls(id) ON DELETE CASCADE,
            stage TEXT NOT NULL CHECK(stage IN (
                'awaitingParticipants','queued','transcribing','diarizing',
                'attributing','indexing','finalizingArtifacts','ready'
            )),
            execution_state TEXT NOT NULL CHECK(execution_state IN ('pending','running','failed','complete')),
            attempt_count INTEGER NOT NULL DEFAULT 0 CHECK(attempt_count >= 0),
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            started_at REAL,
            completed_at REAL,
            latest_event_id TEXT REFERENCES processing_events(id) ON DELETE SET NULL,
            claim_token TEXT UNIQUE
        );

        INSERT INTO processing_jobs (
            call_id, stage, execution_state, attempt_count, created_at, updated_at,
            started_at, completed_at, latest_event_id
        )
        SELECT
            calls.id,
            CASE calls.status
                WHEN 'recording' THEN 'awaitingParticipants'
                WHEN 'metadata' THEN 'awaitingParticipants'
                WHEN 'transcribing' THEN 'transcribing'
                WHEN 'indexing' THEN 'indexing'
                WHEN 'ready' THEN 'ready'
                WHEN 'failed' THEN 'transcribing'
                WHEN 'processing' THEN CASE WHEN index_jobs.call_id IS NULL THEN 'transcribing' ELSE 'indexing' END
                WHEN 'discarded' THEN 'ready'
            END,
            CASE
                WHEN calls.status IN ('recording', 'failed') THEN 'failed'
                WHEN calls.status IN ('ready', 'discarded') THEN 'complete'
                WHEN calls.status = 'indexing' AND index_jobs.status = 'failed' THEN 'failed'
                ELSE 'pending'
            END,
            0,
            calls.started_at,
            COALESCE(calls.ended_at, calls.started_at),
            NULL,
            CASE WHEN calls.status IN ('ready', 'discarded') THEN COALESCE(calls.ended_at, calls.started_at) ELSE NULL END,
            NULL
        FROM calls
        LEFT JOIN index_jobs ON index_jobs.call_id = calls.id;

        UPDATE calls SET status = 'failed' WHERE status = 'recording';
        """

    private static let participantProfileMigrationSchema = """
        ALTER TABLE participants ADD COLUMN role TEXT;
        ALTER TABLE participants ADD COLUMN company TEXT;
        ALTER TABLE participants ADD COLUMN email TEXT;
        """

    private static let speakerIdentityMigrationSchema = """
        CREATE TABLE pending_speaker_clusters (
            id TEXT PRIMARY KEY,
            call_id TEXT NOT NULL REFERENCES calls(id) ON DELETE CASCADE,
            speaker_index INTEGER NOT NULL CHECK(speaker_index >= 0),
            speaker_label TEXT NOT NULL,
            model_version TEXT NOT NULL,
            encrypted_embedding BLOB NOT NULL,
            speech_ms INTEGER NOT NULL CHECK(speech_ms >= 0),
            created_at REAL NOT NULL,
            expires_at REAL NOT NULL,
            UNIQUE(call_id, speaker_index)
        );

        CREATE TABLE participant_voice_samples (
            id TEXT PRIMARY KEY,
            participant_id TEXT NOT NULL REFERENCES participants(id) ON DELETE CASCADE,
            model_version TEXT NOT NULL,
            encrypted_embedding BLOB NOT NULL,
            speech_ms INTEGER NOT NULL CHECK(speech_ms >= 0),
            confirmed_call_id TEXT REFERENCES calls(id) ON DELETE SET NULL,
            created_at REAL NOT NULL,
            source_cluster_id TEXT UNIQUE REFERENCES pending_speaker_clusters(id) ON DELETE SET NULL
        );

        CREATE TABLE speaker_assignments (
            cluster_id TEXT PRIMARY KEY REFERENCES pending_speaker_clusters(id) ON DELETE CASCADE,
            call_id TEXT NOT NULL REFERENCES calls(id) ON DELETE CASCADE,
            speaker_index INTEGER NOT NULL CHECK(speaker_index >= 0),
            participant_id TEXT REFERENCES participants(id) ON DELETE RESTRICT,
            state TEXT NOT NULL CHECK(state IN ('automatic','suggested','unknown','confirmed')),
            confidence_band TEXT NOT NULL CHECK(confidence_band IN ('high','review','none')),
            updated_at REAL NOT NULL,
            UNIQUE(call_id, speaker_index)
        );

        CREATE INDEX participant_voice_samples_lookup
            ON participant_voice_samples(model_version, participant_id, created_at);
        CREATE INDEX pending_speaker_clusters_expiry
            ON pending_speaker_clusters(expires_at);
        """

    private static let speakerReviewMigrationSchema = """
        ALTER TABLE speaker_assignments ADD COLUMN reviewed_at REAL;

        CREATE TABLE voice_sample_recovery (
            id TEXT PRIMARY KEY,
            participant_id TEXT NOT NULL REFERENCES participants(id) ON DELETE CASCADE,
            model_version TEXT NOT NULL,
            encrypted_embedding BLOB NOT NULL,
            speech_ms INTEGER NOT NULL CHECK(speech_ms >= 0),
            confirmed_call_id TEXT REFERENCES calls(id) ON DELETE SET NULL,
            created_at REAL NOT NULL,
            deleted_at REAL NOT NULL,
            purge_after REAL NOT NULL
        );

        CREATE INDEX voice_sample_recovery_expiry
            ON voice_sample_recovery(purge_after);
        """

    private static let speakerReviewRequestMigrationSchema = """
        CREATE TABLE IF NOT EXISTS speaker_review_requests (
            id TEXT PRIMARY KEY,
            cluster_id TEXT NOT NULL REFERENCES pending_speaker_clusters(id) ON DELETE CASCADE,
            participant_id TEXT REFERENCES participants(id) ON DELETE RESTRICT,
            action TEXT NOT NULL CHECK(action IN ('confirm','keepUnknown')),
            status TEXT NOT NULL CHECK(status IN ('pending','running','completed','failed')),
            error TEXT,
            claim_token TEXT UNIQUE,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            CHECK(
                (action = 'confirm' AND participant_id IS NOT NULL)
                OR (action = 'keepUnknown' AND participant_id IS NULL)
            )
        );

        CREATE UNIQUE INDEX IF NOT EXISTS speaker_review_requests_active
            ON speaker_review_requests(cluster_id)
            WHERE status IN ('pending','running');
        """
}
