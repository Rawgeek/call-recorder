import Foundation
import Testing
@testable import CallRecorderApp
@testable import CallRecorderCore

/// A row in the transcripts table can outlive the file it names. A call is transcribed into a
/// working folder, the transcript is promoted to the recordings folder, and the working folder is
/// removed. Where the row was not repointed at the promoted file first, it went on naming the
/// folder that cleanup removed, and Open on that row did nothing at all. These check the two
/// pieces that let the repair work on one call and describe what it did.
@Suite("Transcript file repair")
struct TranscriptFileRepairTests {
    private func temporaryDatabasePath() -> String {
        FileManager.default.temporaryDirectory
            .appending(path: "call-recorder-file-repair-\(UUID().uuidString).db")
            .path
    }

    private func seedCall(
        in store: CallStore,
        at startedAt: Date,
        text: String,
        folder: URL
    ) async throws -> CallID {
        let callID = CallID(rawValue: UUID())
        try await store.createCall(CallRecord.started(id: callID, at: startedAt))
        let markdown = folder.appending(path: "\(callID.rawValue.uuidString).md")
        let json = folder.appending(path: "\(callID.rawValue.uuidString).json")
        try "Participants: Not specified".write(to: markdown, atomically: true, encoding: .utf8)
        try "{}".write(to: json, atomically: true, encoding: .utf8)
        try await store.saveTranscript(
            TranscriptRecord(
                callID: callID, language: "en", model: "small", text: text,
                markdownPath: markdown.path, jsonPath: json.path
            ),
            queueIndexing: false
        )
        return callID
    }

    @Test("one call reads the same on its own as it does in the whole list")
    func singleRecordMatchesTheList() async throws {
        let databasePath = temporaryDatabasePath()
        defer { try? FileManager.default.removeItem(atPath: databasePath) }
        let store = try CallStore(path: databasePath)
        try await store.migrate()
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "file-repair-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let callID = try await seedCall(in: store, at: startedAt, text: "Hello there.", folder: folder)

        let one = try await store.transcriptFileRecord(for: callID)
        let listed = try await store.transcriptFileRecords()

        #expect(one?.callID == callID)
        #expect(one?.startedAt == startedAt)
        #expect(one?.text == listed.first?.text)
        #expect(one?.markdownPath == listed.first?.markdownPath)
    }

    @Test("a call with no transcript has no file to read")
    func unknownCallHasNoRecord() async throws {
        let databasePath = temporaryDatabasePath()
        defer { try? FileManager.default.removeItem(atPath: databasePath) }
        let store = try CallStore(path: databasePath)
        try await store.migrate()

        let record = try await store.transcriptFileRecord(for: CallID(rawValue: UUID()))

        #expect(record == nil)
    }

    @Test("stored text comes back as one segment per line")
    @MainActor
    func storedTextBecomesSegments() {
        let body = """
            First line.

            Second line.
            """

        let transcript = AppModel.transcript(fromStoredText: body, language: "ru")

        #expect(transcript.language == "ru")
        #expect(transcript.segments.map(\.text) == ["First line.", "Second line."])
    }

    @Test("a rebuild that wrote nothing says so instead of reporting success")
    @MainActor
    func summaryNamesEachOutcome() {
        #expect(
            AppModel.restoreSummary(restored: 0, empty: 0, failed: 0)
                == "No transcript file was missing."
        )
        let mixed = AppModel.restoreSummary(restored: 3, empty: 3, failed: 0)
        #expect(mixed.contains("Wrote back 3 transcript files"))
        #expect(mixed.contains("3 calls held no speech, so they kept no file."))
        let single = AppModel.restoreSummary(restored: 1, empty: 0, failed: 0)
        #expect(single.contains("Wrote back 1 transcript file "))
        let failure = AppModel.restoreSummary(restored: 0, empty: 0, failed: 2)
        #expect(failure.contains("2 files could not be written"))
    }

    @Test("launch stays quiet when the repair changed nothing")
    @MainActor
    func launchDoesNotReportHousekeeping() {
        // The three rows that hold no speech are found and refused on every start. Reporting that
        // at launch would put a sentence in the Diagnostics footnote that reads as the result of
        // something the user did, every time the app opens.
        #expect(!AppModel.shouldReportRestore(restored: 0, failed: 0, announceWhenClean: false))
        // A button press is a question, so it always gets an answer, including "nothing to do".
        #expect(AppModel.shouldReportRestore(restored: 0, failed: 0, announceWhenClean: true))
        // A launch that changed something, or broke, speaks.
        #expect(AppModel.shouldReportRestore(restored: 3, failed: 0, announceWhenClean: false))
        #expect(AppModel.shouldReportRestore(restored: 0, failed: 1, announceWhenClean: false))
    }
}
