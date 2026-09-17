import Foundation
import Testing
@testable import CallRecorderCore

@Suite("Transcript header rows")
struct TranscriptHeaderRowTests {
    private func temporaryDatabasePath() -> String {
        FileManager.default.temporaryDirectory
            .appending(path: "call-recorder-header-tests-\(UUID().uuidString).db")
            .path
    }

    @Test("lists every transcript with the participant names the database holds")
    func listsTranscriptsWithNames() async throws {
        let databasePath = temporaryDatabasePath()
        defer { try? FileManager.default.removeItem(atPath: databasePath) }
        let store = try CallStore(path: databasePath)
        try await store.migrate()
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "header-rows-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let older = CallID(rawValue: UUID())
        let newer = CallID(rawValue: UUID())
        try await store.createCall(
            CallRecord.started(id: older, at: Date(timeIntervalSince1970: 1_000))
        )
        try await store.createCall(
            CallRecord.started(id: newer, at: Date(timeIntervalSince1970: 2_000))
        )
        let dana = try await store.upsertParticipant(name: "Dana Holt")
        let sam = try await store.upsertParticipant(name: "Sam")
        try await store.setParticipants([dana.id, sam.id], for: older)
        try await store.setParticipants([sam.id], for: newer)
        for callID in [older, newer] {
            let markdown = directory.appending(path: "\(callID.rawValue.uuidString).md")
            let json = directory.appending(path: "\(callID.rawValue.uuidString).json")
            try "Participants: Not specified".write(to: markdown, atomically: true, encoding: .utf8)
            try "{}".write(to: json, atomically: true, encoding: .utf8)
            try await store.saveTranscript(
                TranscriptRecord(
                    callID: callID, language: "en", model: "small", text: "text",
                    markdownPath: markdown.path, jsonPath: json.path
                ),
                queueIndexing: false
            )
        }

        let rows = try await store.transcriptHeaderRows()

        #expect(rows.count == 2)
        #expect(rows.first?.callID == newer)
        #expect(rows.first?.names == ["Sam"])
        #expect(rows.last?.names == ["Dana Holt", "Sam"])
    }
}
