import Foundation
import Testing
@testable import CallRecorderCore

/// What the recent list knows about a call nobody spoke on.
///
/// The transcriber returns no segments for a silent recording and writes a file with a heading and
/// no words. The file exists, so the row called the call Ready in the ready tone. The library holds
/// exactly one of these: a 4 minute 35 second recording whose peak level is minus 39 decibels, and
/// a 42-byte transcript. The state is now carried out of the store so the row can say what the
/// recording held.
@Suite("A call with no speech")
struct SilentCallRowTests {
    private func store() throws -> CallStore {
        let path = FileManager.default.temporaryDirectory
            .appending(path: "silent-\(UUID().uuidString).db").path
        return try CallStore(path: path)
    }

    private func call(at seconds: Double) -> CallRecord {
        CallRecord.started(
            id: CallID(rawValue: UUID()),
            at: Date(timeIntervalSince1970: seconds)
        )
    }

    @Test("a transcript with no words is reported as having no speech")
    func emptyTranscriptIsReported() async throws {
        let store = try store()
        try await store.migrate()
        let silent = call(at: 1_800_000_000)
        try await store.createCall(silent)
        try await store.saveTranscript(
            TranscriptRecord(
                callID: silent.id,
                language: "en",
                model: "whisper-medium",
                text: "",
                markdownPath: "/tmp/silent.md",
                jsonPath: "/tmp/silent.json"
            )
        )

        let summary = try #require(try await store.recentCalls(limit: 1).first)

        // The file is there, which is what the row used to read, and the words are not.
        #expect(summary.hasTranscript)
        #expect(summary.hasSpeech == false)
    }

    @Test("a transcript with words is reported as having speech")
    func spokenTranscriptIsReported() async throws {
        let store = try store()
        try await store.migrate()
        let spoken = call(at: 1_800_000_000)
        try await store.createCall(spoken)
        try await store.saveTranscript(
            TranscriptRecord(
                callID: spoken.id,
                language: "en",
                model: "whisper-medium",
                text: "**Sam**: Ship it.",
                markdownPath: "/tmp/spoken.md",
                jsonPath: "/tmp/spoken.json"
            )
        )

        let summary = try #require(try await store.recentCalls(limit: 1).first)

        #expect(summary.hasSpeech)
    }

    @Test("a call with no transcript at all has no speech either")
    func callWithoutTranscript() async throws {
        let store = try store()
        try await store.migrate()
        try await store.createCall(call(at: 1_800_000_000))

        let summary = try #require(try await store.recentCalls(limit: 1).first)

        #expect(summary.hasTranscript == false)
        #expect(summary.hasSpeech == false)
    }

    @Test("the silent call and the spoken one are told apart in one list")
    func bothKindsInOneList() async throws {
        let store = try store()
        try await store.migrate()
        let silent = call(at: 1_800_000_000)
        let spoken = call(at: 1_800_000_600)
        try await store.createCall(silent)
        try await store.createCall(spoken)
        try await store.saveTranscript(
            TranscriptRecord(
                callID: silent.id,
                language: "en",
                model: "whisper-medium",
                text: "",
                markdownPath: "/tmp/a.md",
                jsonPath: "/tmp/a.json"
            )
        )
        try await store.saveTranscript(
            TranscriptRecord(
                callID: spoken.id,
                language: "en",
                model: "whisper-medium",
                text: "**Sam**: Hello.",
                markdownPath: "/tmp/b.md",
                jsonPath: "/tmp/b.json"
            )
        )

        let calls = try await store.recentCalls(limit: 2)
        let byID = Dictionary(uniqueKeysWithValues: calls.map { ($0.id, $0) })

        #expect(byID[silent.id]?.hasSpeech == false)
        #expect(byID[spoken.id]?.hasSpeech == true)
        // Both carry a transcript, so the difference the row reports is speech and nothing else.
        #expect(byID[silent.id]?.hasTranscript == true)
        #expect(byID[spoken.id]?.hasTranscript == true)
    }
}

