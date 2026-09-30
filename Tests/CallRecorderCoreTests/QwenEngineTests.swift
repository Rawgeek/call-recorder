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

/// The rule the reader uses to decide that a piece of an answer is a loop.
///
/// A piece this calls a loop is read again through a narrower window and dropped when it loops a
/// second time, so the line this rule draws is the line between a piece a call keeps and a piece it
/// loses. On 2026-09-29 two lessons were read twice each and neither transcript was written at all:
/// the answers repeated a phrase and the app's own guard refused the whole recording for it. The
/// examples are answered by the shipping script, which needs no model for that.
@Suite("Transcription loop rule")
struct QwenLoopRuleTests {
    @Test("a phrase said three times is a loop, and a person repeating words is not")
    func answersTheBuiltInExamples() throws {
        let script = TestEnvironment.packageRoot
            .appending(path: "Sources/CallRecorderApp/qwen_asr.py")
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/python3")
        process.arguments = [script.path, "--self-check"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        // The script answers with its own exit code, and with what it answered for each example.
        #expect(process.terminationStatus == 0)
        let answered = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: [String: Any]]
        )
        for (example, answer) in answered {
            #expect(answer["looping"] as? Bool == answer["expected"] as? Bool, "\(example)")
        }
        // The two sides of the line, named: the shape that cost the two lessons is a loop, and the
        // shape the guard was narrowed for on 2026-09-23 is a person.
        #expect(answered["a phrase three times and nothing else"]?["looping"] as? Bool == true)
        #expect(
            answered["a person agreeing six times in one breath"]?["looping"] as? Bool == false
        )
    }
}

/// What the reader does with a piece of a call it could not keep.
///
/// A piece the model raised on, looped on, or said nothing about is read again as both of its
/// halves, front first, and each half keeps the times it has in the call. The retry used to read the
/// front half alone, which left the back half of a fumbled piece out of the transcript without
/// saying so: a log line that the piece had been read again, and nothing in the reading for what was
/// in its second half. The scenarios are answered by the shipping script, which needs no model.
@Suite("Transcription retry rule")
struct QwenRetryRuleTests {
    /// One scenario as the script reports it: what it read, what it kept, and its counts.
    struct Scenario: Decodable {
        let calls: [[Double]]
        let segments: [[Double]]
        let texts: [String]
        let unreadable: Int
        let failedAttempts: Int
        let dropped: Int
        let kept: Bool
    }

    /// The scenarios, answered by the shipping script.
    private func scenarios() throws -> [String: Scenario] {
        let script = TestEnvironment.packageRoot
            .appending(path: "Sources/CallRecorderApp/qwen_asr.py")
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/python3")
        process.arguments = [script.path, "--retry-check"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        // The script answers with its own verdict as well as with what it read and kept.
        #expect(process.terminationStatus == 0)
        return try JSONDecoder().decode([String: Scenario].self, from: data)
    }

    @Test("a piece that answers is read once, as the piece it is")
    func readsAWholePieceOnce() throws {
        let scenario = try #require(try scenarios()["a whole piece that answers is read once"])
        #expect(scenario.calls == [[0, 15]])
        #expect(scenario.segments == [[0, 15]])
        #expect(scenario.dropped == 0)
    }

    @Test("a piece that failed or looped is read as both halves, in the call's own time")
    func readsBothHalves() throws {
        let answered = try scenarios()
        for name in [
            "a whole piece that failed is read as both halves",
            "a whole piece that loops is read as both halves",
        ] {
            let scenario = try #require(answered[name], "\(name)")
            // The whole piece was read first, and the retry is both halves: the half the model
            // fumbled is read rather than left out.
            #expect(scenario.calls == [[0, 15], [0, 7.5], [7.5, 15]], "\(name)")
            // Both halves are kept, each with the time it has in the call rather than the time it
            // has in the half.
            #expect(scenario.segments == [[0, 7.5], [7.5, 15]], "\(name)")
            let starts = scenario.segments.map { $0[0] }
            #expect(starts == starts.sorted(), "\(name)")
        }
        #expect(answered["a whole piece that failed is read as both halves"]?.failedAttempts == 1)
        #expect(answered["a whole piece that loops is read as both halves"]?.unreadable == 1)
    }

    @Test("a half that failed keeps the half that answered")
    func keepsTheHalfThatAnswered() throws {
        let scenario = try #require(
            try scenarios()["a half that failed keeps the half that answered"]
        )
        #expect(scenario.calls == [[0, 15], [0, 7.5], [7.5, 15]])
        // The half the model read is kept where it belongs in the call rather than being dropped
        // with the half that failed, and the failures are still counted.
        #expect(scenario.segments == [[7.5, 15]])
        #expect(scenario.texts == ["the second half of the piece"])
        #expect(scenario.failedAttempts == 2)
        #expect(scenario.dropped == 0)
    }

    @Test("a piece that said nothing is dropped rather than read as a fault")
    func keepsTheEmptyAnswer() throws {
        let scenario = try #require(
            try scenarios()["a whole piece that said nothing is read as both halves"]
        )
        #expect(scenario.calls == [[0, 15], [0, 7.5], [7.5, 15]])
        // Both halves were asked about and answered nothing, so the piece is dropped and neither
        // count moves: a quiet recording is still read rather than reported as a failed runtime.
        #expect(scenario.segments.isEmpty)
        #expect(scenario.unreadable == 0)
        #expect(scenario.failedAttempts == 0)
        #expect(scenario.dropped == 1)
    }

    @Test("every scenario answers the way the script says it should")
    func passesItsOwnCheck() throws {
        let answered = try scenarios()
        #expect(answered.count == 5)
        for (name, scenario) in answered {
            #expect(scenario.kept, "\(name)")
        }
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
