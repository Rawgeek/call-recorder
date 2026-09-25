import CallRecorderCore
import Foundation
import Testing
@testable import CallRecorderApp

/// The whole path a finished call takes, driven by the code a call is driven by.
///
/// The suites beside this one prove each stage over stubs: the reader on speech the machine makes,
/// the processor over written stages, the speaker rules over written turns. None of them shows the
/// stages still fit each other, which is what replacing the reader puts at risk: 0.1.33 changed
/// what every call is read with and nothing about the stores, the separation, or the transcript
/// files that follow it. This runs `CallPipeline`, the type `AppModel` calls for a call, over a
/// real recording of a meeting: the call row, the reading, the words on disk, the separation into
/// voices, and the store that holds the result.
///
/// It is skipped unless a recording is named, because it reads minutes of real speech:
///
///   CALL_RECORDER_PIPELINE_AUDIO=/path/to/system.m4a swift test --filter RealPipelineTests
@Suite("A call through the pipeline", .enabled(if: TestEnvironment.canRunWholePipeline))
struct RealPipelineTests {
    /// How much of the recording a run reads.
    ///
    /// Long enough to hold several voices, short enough that the separation over it costs seconds.
    static let seconds = 180

    /// Where the slice starts, as a default rather than a rule.
    ///
    /// The 2026-09-24 14:04 call holds four voices between 26:00 and 29:00, which is the property
    /// the separation is checked for. A recording whose slice starts elsewhere still reads and
    /// separates; only the number of voices is asserted, not which voices they are.
    static let offsetSeconds = 1560

    @Test("a recording becomes a transcript whose voices are separated", .timeLimit(.minutes(20)))
    func readsASliceThroughThePipeline() async throws {
        let source = try #require(TestEnvironment.pipelineRecording, "name a recording to read")
        try #require(FileManager.default.fileExists(atPath: source.path))
        let python = try #require(TestEnvironment.speakerRuntimePython)
        let script = try #require(TestEnvironment.diarizationScript)
        let ffmpeg = try #require(ToolLocator.standard.locate("ffmpeg"))
        let ffprobe = try #require(ToolLocator.standard.locate("ffprobe"))

        // Given: an empty library and a call whose other side is on disk, cut from the recording.
        let root = FileManager.default.temporaryDirectory
            .appending(path: "real-pipeline-\(UUID().uuidString)", directoryHint: .isDirectory)
        let directory = root.appending(path: "2026-09-24T14-04-05", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = directory.appending(path: "system.m4a")
        try Self.cut(from: source, to: audio, ffmpeg: ffmpeg)
        let audioBytes = try #require(
            try FileManager.default.attributesOfItem(atPath: audio.path)[.size] as? Int
        )
        #expect(audioBytes > 0, "the slice holds the recording's own bytes")

        let store = try CallStore(path: root.appending(path: "calls.db").path)
        try await store.migrate()
        let pipeline = CallPipeline(
            store: store, finalizer: MediaFinalizer(ffmpeg: ffmpeg, ffprobe: ffprobe)
        )
        let callID = CallID(rawValue: UUID())
        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        try await pipeline.start(callID: callID, startedAt: startedAt)
        try await store.finalizeAndQueue(
            id: callID,
            endedAt: startedAt.addingTimeInterval(Double(Self.seconds)),
            audioPath: audio.path
        )

        // When: the call is read the way a call is read, by the app's own pipeline.
        let engine = try QwenEngineTestsSupport.engine()
        let readingStarted = Date()
        let record = try await pipeline.transcribe(
            callID: callID,
            audio: audio,
            modelID: SupportingModel.qwen3ASRID,
            participantIDs: [],
            glossary: [],
            directory: directory,
            queueIndexing: false,
            using: Transcriber(language: "auto", includeTimestamps: true, engine: engine)
        )
        let readingSeconds = Date().timeIntervalSince(readingStarted)

        // Then: the words are there, they are placed in the call, and the files the app reads are
        // on disk beside the audio rather than only in the store.
        let words = record.text.split(whereSeparator: { $0.isWhitespace }).count
        print("READ \(Self.seconds)s of recording: \(words) words in \(readingSeconds)s")
        #expect(words > 100, "the slice holds speech, and the reader wrote it")
        #expect(FileManager.default.fileExists(atPath: record.markdownPath))
        #expect(FileManager.default.fileExists(atPath: record.jsonPath))
        var document = try JSONDecoder().decode(
            NormalizedTranscript.self, from: Data(contentsOf: URL(filePath: record.jsonPath))
        )
        #expect(!document.segments.isEmpty)
        #expect(document.segments.allSatisfy { $0.startMs < $0.endMs })
        // The reading covers the slice rather than stopping part way, which is the fault a token
        // budget caused on a whole call before the script read the audio in pieces of its own.
        let lastMs = document.segments.map(\.endMs).max() ?? 0
        #expect(lastMs > Self.seconds * 1_000 * 3 / 4, "the reading reaches the end of the slice")

        // When: the other side is separated into voices by the real speaker script.
        let speakers = SpeakerStore(
            store: store, cipher: try VoiceprintCipher(keyData: Data(0..<32))
        )
        let separationStarted = Date()
        try await pipeline.recognizeSpeakers(
            callID: callID,
            audioDirectory: directory,
            using: Diarizer(python: python, script: script, ffmpeg: ffmpeg),
            speakerStore: speakers,
            revisionManager: TranscriptRevisionManager(root: root),
            timestamps: true
        )
        print("SEPARATED in \(Date().timeIntervalSince(separationStarted))s")

        // Then: every remote word keeps its place and a voice to speak with, at least two voices
        // are named, and the markdown a person reads carries the same call the JSON does.
        document = try JSONDecoder().decode(
            NormalizedTranscript.self, from: Data(contentsOf: URL(filePath: record.jsonPath))
        )
        let remote = document.segments.filter { $0.source != .microphone }
        let voices = Set(remote.compactMap(\.speakerIndex))
        print("VOICES \(voices.sorted()) of \(remote.count) remote segments")
        #expect(!remote.isEmpty, "the reading is the other side of the call")
        #expect(voices.count >= 2, "a meeting slice holds more than one voice")
        #expect(!remote.contains { $0.text.trimmingCharacters(in: .whitespaces).isEmpty })
        let markdown = try String(contentsOfFile: record.markdownPath, encoding: .utf8)
        #expect(markdown.contains("Speaker"))
        #expect(markdown.count > record.text.count / 2)

        // And: the library answers with the call as a transcript that can be opened rather than as
        // work still to do.
        let summary = try #require(try await store.recentCalls(limit: 1).first)
        #expect(summary.id == callID)
        #expect(summary.hasTranscript)
        #expect(summary.hasSpeech)
        #expect(try await store.transcript(for: callID) != nil)
    }

    /// Cuts a slice of a recording into the call folder, without re-encoding it.
    private static func cut(from source: URL, to destination: URL, ffmpeg: URL) throws {
        _ = try ProcessRunner.runChecked(
            executable: ffmpeg,
            arguments: [
                "-nostdin", "-y",
                "-ss", String(offsetSeconds),
                "-t", String(seconds),
                "-i", source.path,
                "-vn", "-c", "copy",
                destination.path,
            ]
        )
        guard FileManager.default.fileExists(atPath: destination.path) else {
            throw PipelineSliceError.nothingWasWritten(destination.path)
        }
    }
}

enum PipelineSliceError: LocalizedError {
    case nothingWasWritten(String)

    var errorDescription: String? {
        switch self {
        case .nothingWasWritten(let path): "the slice was not written to \(path)"
        }
    }
}

/// What this build reads with, and what it must not read with again.
///
/// 0.1.33 replaced the reader and removed the engines and models before it: whisper.cpp, the
/// Silero filter, Parakeet, and the model that wrote the post-call brief. A catalog that still
/// listed one of them would download it, verify it, and offer it beside a reader that never opens
/// it, which is what the removal took out of the list. The catalog is the one place that decides
/// what the app fetches, so the check is here rather than in the window that draws the rows.
@Suite("What this build reads with")
struct SupportingCatalogTests {
    @Test("the catalog holds the reader and the embedder, and nothing else")
    func catalogHoldsTheModelsThisBuildUses() {
        #expect(
            SupportingModel.catalog.map(\.id).sorted()
                == [SupportingModel.embeddingGemmaID, SupportingModel.qwen3ASRID].sorted()
        )
    }

    @Test("no model in the catalog is a second reader or a writer of prose")
    func catalogCarriesNoRemovedEngine() {
        let text = SupportingModel.catalog
            .flatMap { [$0.id, $0.displayName, $0.detail, $0.repository, $0.versionLabel] }
            .joined(separator: " ")
            .lowercased()
        for removed in ["whisper", "parakeet", "silero", "brief", "summar"] {
            #expect(!text.contains(removed), "the catalog still names \(removed)")
        }
    }
}

/// The gate the app puts in front of a reading, checked against the installed pieces.
///
/// `AppModel` reads a call only when the runtime reports the pinned versions and the model is
/// installed. On this Mac both answers have to be yes, and the folder the reader is handed has to
/// be the revision the catalog pins.
@Suite("The gate before a reading", .enabled(if: TestEnvironment.canRunTranscriptionModel))
struct ReadingGateTests {
    @Test("the app finds the pinned runtime and the installed model")
    @MainActor
    func appGateSeesTheRuntimeAndTheModel() throws {
        let python = try #require(TestEnvironment.speechRuntimePython)
        #expect(SpeechRuntime.probe(python: python) == .ready)
        let manager = SupportingModelManager(
            applicationDirectory: TestEnvironment.applicationDirectory
        )
        let model = try #require(
            manager.models.first { $0.id == SupportingModel.qwen3ASRID },
            "the build's own catalog holds the reader it reads with"
        )
        #expect(manager.state(for: model).isInstalled)
        let directory = try #require(
            TestEnvironment.transcriptionModel,
            "the installed folder is the one the manifest names"
        )
        #expect(directory.lastPathComponent == model.revision)
    }
}
