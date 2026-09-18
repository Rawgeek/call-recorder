import CallRecorderCore
import Foundation
import Libsql
import Testing
@testable import CallRecorderApp

@Suite("Native transcript index")
struct NativeTranscriptIndexTests {
    @Test("normalized Unicode segments become deterministic searchable chunks")
    func indexesNormalizedSegmentsDeterministically() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appending(path: "calls.db")
        let jsonURL = root.appending(path: "transcript.json")
        try Data(#"{"segments":[{"startMs":0,"endMs":1200,"text":"[MUSIC] Привет   мир","speakerIndex":0},{"startMs":1200,"endMs":2400,"text":"Обсудим релиз","speakerName":"Ирина"}]}"#.utf8)
            .write(to: jsonURL)
        let store = try CallStore(path: databaseURL.path)
        try await store.migrate()
        let callID = try await saveTranscript(
            in: store,
            text: "Привет мир. Обсудим релиз.",
            jsonPath: jsonURL.path
        )

        let indexer: any TranscriptIndexing = NativeTranscriptIndexer()
        try await indexer.index(callID: callID, store: store, cancellation: nil)

        #expect(try await store.indexIsReady(for: callID))
        let matches = try await store.searchNativeTranscripts("мир")
        #expect(matches.count == 1)
        #expect(matches[0].callID == callID)
        #expect(matches[0].text == "Speaker 1: Привет мир Ирина: Обсудим релиз")
        let firstRows = try chunkRows(at: databaseURL, callID: callID)
        let firstArtifact = try artifact(at: databaseURL, callID: callID)
        #expect(firstRows.count == 1)
        #expect(firstRows.allSatisfy { $0.text.count <= 1_200 })
        #expect(firstArtifact.backend == "lexical-v1")
        #expect(firstArtifact.digest.count == 64)
        #expect(firstArtifact.count == firstRows.count)

        try await store.saveTranscript(
            TranscriptRecord(
                callID: callID,
                language: "ru",
                model: "fixture",
                text: "Привет мир. Обсудим релиз.",
                markdownPath: root.appending(path: "transcript.md").path,
                jsonPath: jsonURL.path
            ),
            queueIndexing: false
        )
        try await indexer.index(callID: callID, store: store, cancellation: nil)

        #expect(try chunkRows(at: databaseURL, callID: callID) == firstRows)
        #expect(try artifact(at: databaseURL, callID: callID) == firstArtifact)

        try Data(#"[{"startMs":0,"endMs":900,"text":"Новая версия","speakerName":"Ирина"}]"#.utf8)
            .write(to: jsonURL)
        try await store.saveTranscript(
            TranscriptRecord(
                callID: callID,
                language: "ru",
                model: "fixture",
                text: "Новая версия",
                markdownPath: root.appending(path: "transcript.md").path,
                jsonPath: jsonURL.path
            ),
            queueIndexing: false
        )
        try await indexer.index(callID: callID, store: store, cancellation: nil)

        #expect(try await store.searchNativeTranscripts("Привет").isEmpty)
        #expect(try await store.searchNativeTranscripts("Новая").map(\.text) == ["Ирина: Новая версия"])
        #expect(try chunkRows(at: databaseURL, callID: callID).count == 1)
    }

    @Test("an empty cleaned transcript is a ready zero-chunk artifact")
    func emptyTranscriptIsValid() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appending(path: "calls.db")
        let store = try CallStore(path: databaseURL.path)
        try await store.migrate()
        let callID = try await saveTranscript(
            in: store,
            text: " [BLANK_AUDIO]   [silence] ",
            jsonPath: root.appending(path: "missing.json").path
        )

        try await NativeTranscriptIndexer().index(callID: callID, store: store)

        #expect(try await store.indexIsReady(for: callID))
        #expect(try chunkRows(at: databaseURL, callID: callID).isEmpty)
        let stored = try artifact(at: databaseURL, callID: callID)
        #expect(stored.backend == "lexical-v1")
        #expect(stored.count == 0)
    }

    @Test("a failed replacement rolls back chunks and artifact without readiness")
    func failedReplacementRollsBack() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appending(path: "calls.db")
        let store = try CallStore(path: databaseURL.path)
        try await store.migrate()
        let callID = try await saveTranscript(
            in: store,
            text: "Старый индекс остается.",
            jsonPath: root.appending(path: "missing.json").path
        )
        try await NativeTranscriptIndexer().index(callID: callID, store: store)
        let oldRows = try chunkRows(at: databaseURL, callID: callID)
        let oldArtifact = try artifact(at: databaseURL, callID: callID)

        try await store.saveTranscript(
            TranscriptRecord(
                callID: callID,
                language: "ru",
                model: "fixture",
                text: "Новый индекс не должен частично сохраниться.",
                markdownPath: root.appending(path: "transcript.md").path,
                jsonPath: root.appending(path: "missing.json").path
            ),
            queueIndexing: false
        )
        do {
            let connection = try Database(databaseURL.path).connect()
            try connection.executeBatch("""
                CREATE TRIGGER reject_native_chunk
                BEFORE INSERT ON native_transcript_chunks BEGIN
                    SELECT RAISE(ABORT, 'fixture rejects replacement');
                END;
                """)
        }

        var replacementFailed = false
        do {
            try await NativeTranscriptIndexer().index(callID: callID, store: store)
        } catch {
            replacementFailed = true
        }

        #expect(replacementFailed)
        #expect(try await store.indexIsReady(for: callID) == false)
        #expect(try chunkRows(at: databaseURL, callID: callID) == oldRows)
        #expect(try artifact(at: databaseURL, callID: callID) == oldArtifact)
        #expect(try await store.searchNativeTranscripts("Старый").count == 1)
        #expect(try await store.searchNativeTranscripts("Новый").isEmpty)
    }

    @Test("native migration leaves the Bun transcript table intact")
    func preservesBunSchema() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appending(path: "calls.db")
        let store = try CallStore(path: databaseURL.path)
        try await store.migrate()
        do {
            let connection = try Database(databaseURL.path).connect()
            try connection.executeBatch("""
                CREATE TABLE transcript_chunks (
                    id TEXT PRIMARY KEY,
                    call_id TEXT,
                    text TEXT NOT NULL
                );
                INSERT INTO transcript_chunks (id, call_id, text) VALUES ('bun-row', NULL, 'kept');
                """)
        }

        try await store.migrate()

        let connection = try Database(databaseURL.path).connect()
        let bunText = try connection.query(
            "SELECT text FROM transcript_chunks WHERE id = 'bun-row'"
        ).next()?.getString(0)
        let nativeExists = try connection.query(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' "
                + "AND name = 'native_transcript_chunks'"
        ).next() != nil
        #expect(bunText == "kept")
        #expect(nativeExists)
    }

    private struct ChunkRow: Equatable {
        let id: String
        let start: Int
        let end: Int
        let text: String
    }

    private struct Artifact: Equatable {
        let backend: String
        let digest: String
        let count: Int
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "native-index-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func saveTranscript(
        in store: CallStore,
        text: String,
        jsonPath: String
    ) async throws -> CallID {
        let callID = CallID(rawValue: UUID())
        try await store.createCall(
            .started(id: callID, at: Date(timeIntervalSince1970: 1_800_000_000))
        )
        try await store.saveTranscript(
            TranscriptRecord(
                callID: callID,
                language: "ru",
                model: "fixture",
                text: text,
                markdownPath: "/tmp/transcript.md",
                jsonPath: jsonPath
            ),
            queueIndexing: false
        )
        return callID
    }

    private func chunkRows(at databaseURL: URL, callID: CallID) throws -> [ChunkRow] {
        let connection = try Database(databaseURL.path).connect()
        return try connection.query(
            "SELECT id, start_ms, end_ms, text FROM native_transcript_chunks "
                + "WHERE call_id = ? ORDER BY start_ms, end_ms, id",
            [callID.rawValue.uuidString]
        ).map { row in
            ChunkRow(
                id: try row.getString(0),
                start: try row.getInt(1),
                end: try row.getInt(2),
                text: try row.getString(3)
            )
        }
    }

    private func artifact(at databaseURL: URL, callID: CallID) throws -> Artifact {
        let connection = try Database(databaseURL.path).connect()
        let row = try #require(try connection.query(
            "SELECT backend, source_digest, chunk_count FROM native_index_artifacts "
                + "WHERE call_id = ?",
            [callID.rawValue.uuidString]
        ).next())
        return Artifact(
            backend: try row.getString(0),
            digest: try row.getString(1),
            count: try row.getInt(2)
        )
    }
}
