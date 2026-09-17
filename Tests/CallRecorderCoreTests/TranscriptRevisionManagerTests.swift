import CallRecorderCore
import Foundation
import Testing
@testable import CallRecorderApp

@Suite("Transcript revision manager")
struct TranscriptRevisionManagerTests {
    @Test("failed second write restores both active transcript files")
    func failedReplacementRestoresPriorFiles() throws {
        let harness = try Harness()
        let counter = WriteCounter(failAt: 2)
        let manager = TranscriptRevisionManager(
            root: harness.revisions,
            fileSystem: RevisionFileSystem { data, url in
                try counter.write(data, to: url)
            }
        )

        #expect(throws: (any Error).self) {
            try manager.replace(
                callID: harness.callID,
                markdownURL: harness.markdown,
                jsonURL: harness.json,
                renderedMarkdown: "replacement",
                normalizedJSON: Data(#"{"version":1}"#.utf8)
            )
        }
        #expect(try String(contentsOf: harness.markdown, encoding: .utf8) == "original")
        #expect(try String(contentsOf: harness.json, encoding: .utf8) == #"{"version":0}"#)
    }

    @Test("only the newest three recoverable revisions are retained")
    func keepsNewestThreeRevisions() throws {
        let harness = try Harness()
        let manager = TranscriptRevisionManager(root: harness.revisions)

        for version in 1...4 {
            _ = try manager.replace(
                callID: harness.callID,
                markdownURL: harness.markdown,
                jsonURL: harness.json,
                renderedMarkdown: "v\(version)",
                normalizedJSON: Data("{\"version\":\(version)}".utf8)
            )
        }

        #expect(try manager.revisions(for: harness.callID).count == 3)
        #expect(try String(contentsOf: harness.markdown, encoding: .utf8) == "v4")
    }

    @Test("the glossary line is removed and the file it was removed from is kept")
    func stripGlossaryLineKeepsThePriorFile() throws {
        let harness = try Harness()
        let markdown = "# Meeting Transcript\n\nParticipants: Sam\nGlossary: Globex\n\nHello.\n"
        try Data(markdown.utf8).write(to: harness.markdown)
        let manager = TranscriptRevisionManager(root: harness.revisions)

        let backup = try #require(
            try manager.stripGlossaryLine(
                callID: harness.callID,
                markdownURL: harness.markdown,
                contents: markdown
            )
        )

        #expect(
            try String(contentsOf: harness.markdown, encoding: .utf8)
                == "# Meeting Transcript\n\nParticipants: Sam\n\nHello.\n"
        )
        #expect(try String(contentsOf: backup, encoding: .utf8) == markdown)
        // The JSON records the terms the decode ran with, which is a record of what happened
        // rather than a list to keep in step with the vocabulary.
        #expect(try String(contentsOf: harness.json, encoding: .utf8) == #"{"version":0}"#)
    }

    @Test("a file with no glossary line is left alone")
    func stripGlossaryLineSkipsAFileWithoutTheLine() throws {
        let harness = try Harness()
        let markdown = "# Meeting Transcript\n\nParticipants: Sam\n\nHello.\n"
        try Data(markdown.utf8).write(to: harness.markdown)
        let manager = TranscriptRevisionManager(root: harness.revisions)

        let backup = try manager.stripGlossaryLine(
            callID: harness.callID,
            markdownURL: harness.markdown,
            contents: markdown
        )

        #expect(backup == nil)
        #expect(try String(contentsOf: harness.markdown, encoding: .utf8) == markdown)
        #expect(try manager.revisions(for: harness.callID).isEmpty)
    }

    @Test("editing a completed call's participants refreshes artifacts without touching the body")
    func participantSelectionRefreshesTranscriptMetadata() async throws {
        // Given: a completed call with a transcript whose artifacts name Alice.
        let store = try CallStore(path: temporaryDatabasePath())
        try await store.migrate()
        let alice = try await store.upsertParticipant(name: "Alice")
        let bob = try await store.upsertParticipant(name: "Bob")
        let callID = CallID(rawValue: UUID())
        try await store.createCall(.started(id: callID, at: Date(timeIntervalSince1970: 1_800_000_000)))
        try await store.updateCall(
            id: callID,
            endedAt: Date(timeIntervalSince1970: 1_800_000_060),
            audioPath: "/tmp/call.m4a",
            status: .metadata
        )
        try await store.setParticipants([alice.id], for: callID)
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "participant-artifact-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let markdownURL = directory.appending(path: "transcript.md")
        let jsonURL = directory.appending(path: "transcript.json")
        let body = "**Alice**: Distinctive body line.\n\n**Alice**: Second body line."
        let markdown = """
            # Meeting Transcript

            Participants: Alice
            Glossary: None

            \(body)
            """
        let document = NormalizedTranscript(
            callId: callID.rawValue.uuidString,
            language: "en",
            model: "whisper-small",
            participants: [ParticipantMetadata(id: alice.id.rawValue.uuidString, name: "Alice")],
            glossary: [],
            segments: [
                TranscriptSegment(
                    startMs: 0,
                    endMs: 1_000,
                    text: "Distinctive body line.",
                    speakerIndex: 0,
                    source: .system,
                    participantID: alice.id,
                    speakerName: "Alice"
                ),
                TranscriptSegment(
                    startMs: 1_000,
                    endMs: 2_000,
                    text: "Second body line.",
                    speakerIndex: 0,
                    source: .system,
                    participantID: alice.id,
                    speakerName: "Alice"
                ),
            ]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(document).write(to: jsonURL)
        try Data(markdown.utf8).write(to: markdownURL)
        try await store.saveTranscript(
            TranscriptRecord(
                callID: callID,
                language: "en",
                model: "whisper-small",
                text: body,
                markdownPath: markdownURL.path,
                jsonPath: jsonURL.path
            ),
            queueIndexing: false
        )
        _ = try #require(try await store.processingJobs().first)
        _ = try #require(try await store.claimNextProcessingJob(executableOnly: true))
        _ = try await store.advanceProcessingJob(callID: callID, from: .queued, to: .transcribing)
        _ = try #require(try await store.claimNextProcessingJob(executableOnly: true))
        _ = try await store.advanceProcessingJob(callID: callID, from: .transcribing, to: .diarizing)
        _ = try #require(try await store.claimNextProcessingJob(executableOnly: true))
        _ = try await store.advanceProcessingJob(callID: callID, from: .diarizing, to: .attributing)
        _ = try #require(try await store.claimNextProcessingJob(executableOnly: true))
        _ = try await store.advanceProcessingJob(callID: callID, from: .attributing, to: .indexing)
        _ = try #require(try await store.claimNextProcessingJob(executableOnly: true))
        try await store.markIndexReady(for: callID)
        _ = try await store.advanceProcessingJob(callID: callID, from: .indexing, to: .finalizingArtifacts)
        _ = try #require(try await store.claimNextProcessingJob(executableOnly: true))
        _ = try await store.advanceProcessingJob(callID: callID, from: .finalizingArtifacts, to: .ready)
        _ = try await store.setParticipants([alice.id, bob.id], for: callID)
        let revisions = URL(filePath: directory.path).appending(path: "revisions", directoryHint: .isDirectory)
        let manager = TranscriptRevisionManager(root: revisions)

        // When: the completed call's participant artifacts are refreshed.
        let revision = try await refreshTranscriptParticipants(
            callID: callID,
            store: store,
            revisionManager: manager
        )

        // Then: the header and JSON participants change, the body is untouched, and
        // indexing state is preserved.
        let refreshedMarkdown = try #require(try? String(contentsOf: markdownURL, encoding: .utf8))
        #expect(refreshedMarkdown.contains("Participants: Alice, Bob"))
        #expect(refreshedMarkdown.contains(body))
        #expect(
            refreshedMarkdown.replacingOccurrences(
                of: "Participants: Alice, Bob",
                with: "Participants: Alice"
            ) == markdown
        )
        let refreshed = try JSONDecoder().decode(
            NormalizedTranscript.self,
            from: Data(contentsOf: jsonURL)
        )
        #expect(refreshed.participants.map(\.id) == [alice.id.rawValue.uuidString, bob.id.rawValue.uuidString])
        #expect(refreshed.participants.map(\.name) == ["Alice", "Bob"])
        #expect(refreshed.segments == document.segments)
        #expect(refreshed.language == document.language)
        #expect(refreshed.model == document.model)
        #expect(try await store.processingJobs().first?.stage == .ready)
        #expect(try await store.processingJobs().first?.executionState == .complete)
        #expect(try await store.indexIsReady(for: callID))
        #expect(revision != nil)
        #expect(try manager.revisions(for: callID).count == 1)
    }

    private func temporaryDatabasePath() -> String {
        FileManager.default.temporaryDirectory
            .appending(path: "call-recorder-revision-tests-\(UUID().uuidString).db")
            .path
    }

    private struct Harness {
        let callID = CallID(rawValue: UUID())
        let markdown: URL
        let json: URL
        let revisions: URL

        init() throws {
            let directory = FileManager.default.temporaryDirectory
                .appending(path: "transcript-revision-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            markdown = directory.appending(path: "transcript.md")
            json = directory.appending(path: "transcript.json")
            revisions = directory.appending(path: "revisions", directoryHint: .isDirectory)
            try Data("original".utf8).write(to: markdown)
            try Data(#"{"version":0}"#.utf8).write(to: json)
        }
    }

    private final class WriteCounter: @unchecked Sendable {
        enum Failure: Error { case injected }

        private let lock = NSLock()
        private let failAt: Int
        private var count = 0

        init(failAt: Int) {
            self.failAt = failAt
        }

        func write(_ data: Data, to url: URL) throws {
            lock.lock()
            count += 1
            let shouldFail = count == failAt
            lock.unlock()
            if shouldFail { throw Failure.injected }
            try data.write(to: url, options: .atomic)
        }
    }
}
