import CallRecorderCore
import Foundation
import Testing
@testable import CallRecorderApp

/// What the transcription script answers with, as the app reads it.
///
/// The shape is the contract between the Python the app runs and the Swift that reads it: a change
/// on either side stops a call from being read, so it is checked here rather than only on a call.
@Suite("Transcription output")
struct QwenTranscriptDecodingTests {
    private let sample = """
    {
      "language": "auto",
      "detectedLanguage": "ru",
      "duration": 25.75,
      "segments": [
        { "start": 0.0, "end": 25.75, "text": "Так, начинаем обзор. Первое решение — тарифная карта." }
      ],
      "dropped": 1,
      "generationTokens": 730,
      "seconds": 27.2
    }
    """

    @Test("a reading the script wrote decodes into placed pieces")
    func decodesScriptOutput() throws {
        let document = try JSONDecoder().decode(
            QwenTranscriptDocument.self,
            from: Data(sample.utf8)
        )

        #expect(document.detectedLanguage == "ru")
        #expect(document.dropped == 1)
        #expect(document.segments.count == 1)
        #expect(document.segments[0].start == 0)
        #expect(document.segments[0].end == 25.75)
        #expect(document.segments[0].text.contains("тарифная карта"))
    }

    @Test("a language the model named is what the transcript says it was read in")
    func namesTheDetectedLanguage() throws {
        // A named language on the transcript is what the header prints and what later stages read.
        #expect(TranscriptLanguage.naming(requested: "auto", text: "Привет, как дела") == "ru")
        #expect(TranscriptLanguage.naming(requested: "auto", text: "Hello there") == "en")
        // A language the setting named is the answer, whatever the words look like.
        #expect(TranscriptLanguage.naming(requested: "ru", text: "Hello there") == "ru")
    }
}

/// The engine, driven against the real model on audio this test makes.
///
/// A stub reader covers the transcriber's own work; this covers the other half of the contract:
/// the interpreter, the modules, the model folder, and the script, run the way a call runs them.
/// It is skipped on a Mac where the runtime or the model is not installed, which is every machine
/// that has not been set up for transcription yet.
@Suite("Transcription model", .enabled(if: TestEnvironment.canRunTranscriptionModel))
struct QwenEngineTests {
    @Test("the engine reads speech into words", .timeLimit(.minutes(3)))
    func readsGeneratedSpeech() async throws {
        let work = FileManager.default.temporaryDirectory
            .appending(path: "qwen-engine-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        // Speech the machine makes, so the test carries no recording of anybody's call.
        let spoken = work.appending(path: "spoken.aiff")
        let say = Process()
        say.executableURL = TestEnvironment.speechSynthesiser
        say.arguments = [
            "-o", spoken.path,
            "The meeting starts at nine, and the warehouse report is on the table.",
        ]
        try say.run()
        say.waitUntilExit()
        try #require(say.terminationStatus == 0)

        let engine = try QwenEngineTestsSupport.engine()
        let transcript = try await engine.transcribe(
            audio: spoken,
            language: "en",
            hotwords: [],
            cancellation: nil
        )

        let text = transcript.text.lowercased()
        #expect(!transcript.segments.isEmpty)
        // Say reads the words clearly, so most of them must come back. The check is on words a
        // misreading could not produce by accident rather than on the whole sentence.
        let expected = ["meeting", "nine", "warehouse", "report", "table"]
        let found = expected.filter { text.contains($0) }
        #expect(found.count >= 3, "read only \(found) from \(text.prefix(200))")
    }

}

/// The engine reading a real recording, when one is named.
///
/// The suite above proves the engine works on speech the machine makes. This reads a call of the
/// user's own, which is the only way to see what a meeting costs in wall-clock time and how many
/// words of a Russian call that mixes English product names come back. The path is named by
/// `CALL_RECORDER_TRANSCRIBE_AUDIO`, so no recording is committed and no run of the suite depends
/// on one being here:
///
///   CALL_RECORDER_TRANSCRIBE_AUDIO=/path/to/track.m4a swift test --filter RealCallTests
///
/// The reading is written beside the audio, so the words can be read and the timing compared
/// against the notes in docs. What it measures is written to the log rather than asserted: a
/// number a recording happens to produce is not a rule the next call has to satisfy.
@Suite("A real call", .enabled(if: TestEnvironment.canReadNamedRecording))
struct RealCallTests {
    @Test("the app's engine reads a named recording", .timeLimit(.minutes(30)))
    func readsNamedRecording() async throws {
        let audio = try #require(TestEnvironment.namedRecording, "name a recording to read")
        try #require(FileManager.default.fileExists(atPath: audio.path))

        let engine = try QwenEngineTestsSupport.engine()
        let started = Date()
        let transcript = try await engine.transcribe(
            audio: audio,
            language: "auto",
            hotwords: [],
            cancellation: nil
        )
        let seconds = Date().timeIntervalSince(started)
        let words = transcript.segments.reduce(0) { count, segment in
            count + segment.text.split(whereSeparator: { $0 == " " }).count
        }
        print(
            "READ \(audio.lastPathComponent): \(words) words in \(transcript.segments.count) "
                + "pieces, \(String(format: "%.1f", seconds))s, language \(transcript.language)"
        )
        if let last = transcript.segments.last {
            print("LAST \(last.endMs / 1000)s: \(last.text.suffix(160))")
        }
        #expect(!transcript.segments.isEmpty)
    }
}

/// The engine as the app wires it, for the suites outside the one that owns the helper.
enum QwenEngineTestsSupport {
    /// The engine, wired the way the app wires it.
    ///
    /// The script comes from the checkout the suite was built from. The app finds its copy at run
    /// time, in the bundle it was packaged into, and a test run is no bundle: `Bundle.main` here is
    /// the toolchain's test helper, which holds no resources. The packaging step copies this same
    /// file into the app, so this runs the file that ships; only the path differs from a call.
    static func engine() throws -> QwenEngine {
        let script = try #require(
            {
                let url = TestEnvironment.packageRoot.appending(
                    path: "Sources/CallRecorderApp/qwen_asr.py"
                )
                return FileManager.default.fileExists(atPath: url.path) ? url : nil
            }(),
            "the shipping script is in the checkout"
        )
        let model = try #require(TestEnvironment.transcriptionModel)
        let python = try #require(TestEnvironment.speechRuntimePython)
        let ffmpeg = try #require(ToolLocator.standard.locate("ffmpeg"))
        return QwenEngine(python: python, script: script, ffmpeg: ffmpeg, model: model)
    }
}
