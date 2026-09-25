import CallRecorderCore
import Foundation
import Testing
@testable import CallRecorderApp

/// A reader that answers from a table instead of from a model.
///
/// The transcriber's own work is what these tests are about: two tracks merged in order, the
/// glossary applied before anything is written, a loop refused, and an existing file left alone.
/// None of that needs two and a half gigabytes of weights, so the reader is a stub and the audio
/// is a file with a byte in it.
private struct FakeReader: SpeechReading {
    /// What each track answers with, by file name. A name that is not here reads as empty.
    var answers: [String: [TranscriptSegment]]
    var language: String = "ru"
    var failure: (any Error)?

    func transcribe(
        audio: URL,
        language: String,
        hotwords: [String],
        cancellation: ProcessCancellation?
    ) async throws -> SpeechTranscript {
        if let failure { throw failure }
        return SpeechTranscript(
            language: language == "auto" ? self.language : language,
            segments: answers[audio.lastPathComponent] ?? []
        )
    }
}

private func makeCallDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "transcriber-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for name in ["system.m4a", "microphone.m4a", "call.m4a"] {
        try Data([0x00]).write(to: directory.appending(path: name))
    }
    return directory
}

@Suite("Transcriber")
struct TranscriberTests {
    @Test("two tracks are read and saved as one transcript")
    func mergesTwoTracks() async throws {
        let directory = try makeCallDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let reader = FakeReader(answers: [
            "system.m4a": [
                TranscriptSegment(startMs: 0, endMs: 4_000, text: "Так, начинаем.")
            ],
            "microphone.m4a": [
                TranscriptSegment(startMs: 1_000, endMs: 3_000, text: "Да, я на месте.")
            ],
        ])

        let transcript = try await Transcriber(engine: reader).transcribe(
            callID: CallID(rawValue: UUID()),
            audio: directory.appending(path: "call.m4a"),
            modelID: "Qwen3-ASR 1.7B",
            participants: [],
            glossary: [],
            directory: directory
        )

        // Both sides are in the file, and the microphone is named as the local speaker rather
        // than left as a voice the diarization would have to find.
        #expect(transcript.text.contains("начинаем"))
        #expect(transcript.text.contains("на месте"))
        let document = try JSONDecoder().decode(
            NormalizedTranscript.self,
            from: Data(contentsOf: directory.appending(path: "transcript.json"))
        )
        #expect(document.model == "Qwen3-ASR 1.7B")
        #expect(document.segments.contains { $0.source == .microphone })
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "transcript.md").path))
    }

    @Test("the glossary is applied before anything is written")
    func correctsTheGlossary() async throws {
        let directory = try makeCallDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let reader = FakeReader(answers: [
            "system.m4a": [
                TranscriptSegment(startMs: 0, endMs: 2_000, text: "Груз для Глобекс готов.")
            ]
        ])
        let term = GlossaryTerm(
            id: GlossaryTermID(rawValue: UUID()),
            preferred: "Globex",
            aliases: ["Глобекс"]
        )

        _ = try await Transcriber(engine: reader).transcribe(
            callID: CallID(rawValue: UUID()),
            audio: directory.appending(path: "call.m4a"),
            modelID: "Qwen3-ASR 1.7B",
            participants: [],
            glossary: [term],
            directory: directory
        )

        let markdown = try String(
            contentsOf: directory.appending(path: "transcript.md"),
            encoding: .utf8
        )
        #expect(markdown.contains("Globex"))
        #expect(!markdown.contains("Глобекс"))
    }

    @Test("a reading that loops is refused instead of saved")
    func refusesALoop() async throws {
        let directory = try makeCallDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let looped = (0..<40).map { index in
            TranscriptSegment(startMs: index * 1_000, endMs: index * 1_000 + 900, text: "с с с с")
        }
        let reader = FakeReader(answers: ["system.m4a": looped])

        await #expect(throws: TranscriberError.self) {
            try await Transcriber(engine: reader).transcribe(
                callID: CallID(rawValue: UUID()),
                audio: directory.appending(path: "call.m4a"),
                modelID: "Qwen3-ASR 1.7B",
                participants: [],
                glossary: [],
                directory: directory
            )
        }
        #expect(
            !FileManager.default.fileExists(atPath: directory.appending(path: "transcript.json").path)
        )
    }

    @Test("a failed reading writes nothing")
    func failedReadingWritesNothing() async throws {
        let directory = try makeCallDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let reader = FakeReader(answers: [:], failure: QwenEngineError.runtimeMissing)

        await #expect(throws: (any Error).self) {
            try await Transcriber(engine: reader).transcribe(
                callID: CallID(rawValue: UUID()),
                audio: directory.appending(path: "call.m4a"),
                modelID: "Qwen3-ASR 1.7B",
                participants: [],
                glossary: [],
                directory: directory
            )
        }
        #expect(
            !FileManager.default.fileExists(atPath: directory.appending(path: "transcript.md").path)
        )
    }

    @Test("transcript files that are already there are left alone")
    func keepsExistingFiles() async throws {
        let directory = try makeCallDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let callID = CallID(rawValue: UUID())
        let document = NormalizedTranscript(
            callId: callID.rawValue.uuidString,
            language: "ru",
            model: "Qwen3-ASR 1.7B",
            participants: [],
            glossary: [],
            segments: [TranscriptSegment(startMs: 0, endMs: 1_000, text: "Уже прочитано.")]
        )
        let encoder = JSONEncoder()
        try encoder.encode(document).write(to: directory.appending(path: "transcript.json"))
        try Data("# Meeting Transcript\n".utf8).write(to: directory.appending(path: "transcript.md"))

        let transcript = try await Transcriber(engine: FakeReader(answers: [:])).transcribe(
            callID: callID,
            audio: directory.appending(path: "call.m4a"),
            modelID: "Qwen3-ASR 1.7B",
            participants: [],
            glossary: [],
            directory: directory
        )

        #expect(transcript.text.contains("Уже прочитано"))
    }

    @Test("the names and terms given to the reader lead with the people on the call")
    func hotwordsLeadWithNames() {
        let participants = [
            Participant(id: ParticipantID(rawValue: UUID()), name: "Arcady"),
            Participant(id: ParticipantID(rawValue: UUID()), name: "Elizaveta"),
        ]
        let terms = [
            GlossaryTerm(id: GlossaryTermID(rawValue: UUID()), preferred: "Globex", aliases: []),
            GlossaryTerm(id: GlossaryTermID(rawValue: UUID()), preferred: "3PL", aliases: []),
        ]

        let hotwords = PromptBuilder.hotwords(participants: participants, glossary: terms)

        #expect(hotwords.first == "Arcady")
        #expect(hotwords.contains("Elizaveta"))
        #expect(hotwords.contains("Globex"))
        #expect(hotwords.count == Set(hotwords.map { $0.lowercased() }).count)
    }
}
