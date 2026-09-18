import CallRecorderCore
import Foundation
import Testing
@testable import CallRecorderApp

struct DiarizerTests {
    @Test(
        "the voice count a call was given reaches the speaker script",
        .enabled(if: TestEnvironment.canRunSpeakerScript)
    )
    func passesTheVoiceCount() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "diarizer-count-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // The script writes down what it was asked for, and answers with an empty separation.
        let script = directory.appending(path: "count.py")
        try """
        import json, os, sys
        here = os.path.dirname(os.path.abspath(__file__))
        open(os.path.join(here, "arguments.txt"), "w").write(" ".join(sys.argv[1:]))
        print(json.dumps({"model": "stub@1", "segments": [], "speakers": []}))
        """.write(to: script, atomically: true, encoding: .utf8)

        // A stand-in for ffmpeg: it writes the file it was asked for and does nothing else.
        let ffmpeg = directory.appending(path: "ffmpeg")
        try "#!/bin/sh\nfor last in \"$@\"; do :; done\n: > \"$last\"\n"
            .write(to: ffmpeg, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: ffmpeg.path
        )
        let audio = directory.appending(path: "call.m4a")
        try Data("audio".utf8).write(to: audio)

        func recordedArguments(voices: Int?) throws -> String {
            _ = try Diarizer(python: URL(filePath: "/usr/bin/python3"), script: script)
                .run(audio: audio, ffmpeg: ffmpeg, numberOfSpeakers: voices)
            return try String(
                contentsOf: directory.appending(path: "arguments.txt"), encoding: .utf8
            )
        }

        // Then the count is asked for by the name the script knows.
        #expect(try recordedArguments(voices: 14).contains("--num-speakers 14"))
        // And a call the app has no count for asks for nothing.
        #expect(try !recordedArguments(voices: nil).contains("--num-speakers"))
    }

    @Test("speaker runtime receives the selected FFmpeg library directory")
    func addsFFmpegLibrariesToChildEnvironment() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "diarizer-environment-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bin = directory.appending(path: "bin", directoryHint: .isDirectory)
        let library = directory.appending(path: "lib", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let ffmpeg = bin.appending(path: "ffmpeg")
        try Data().write(to: ffmpeg)

        let environment = Diarizer.runtimeEnvironment(
            base: ["DYLD_FALLBACK_LIBRARY_PATH": "/existing/lib"],
            ffmpeg: ffmpeg
        )

        #expect(
            environment["DYLD_FALLBACK_LIBRARY_PATH"]
                == "\(library.path):/existing/lib"
        )
    }

    @Test("speaker overlap combines split turns and preserves the source track")
    func choosesCombinedSpeakerActivity() {
        let merged = SegmentMerger.merge(
            whisperSegments: [TranscriptSegment(startMs: 0, endMs: 5_000, text: "Speech.", source: .system)],
            diarization: [
                DiarizationTurn(start: 0, end: 1.5, speakerLabel: "A"),
                DiarizationTurn(start: 1.5, end: 3.5, speakerLabel: "B"),
                DiarizationTurn(start: 3.5, end: 5, speakerLabel: "A"),
            ]
        )
        #expect(merged.first?.speakerIndex == 0)
        #expect(merged.first?.source == .system)
    }

    @Test("missing model access is a recoverable failure, never empty success", .enabled(if: TestEnvironment.canRunSpeakerScript))
    func reportsMissingModelAccess() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appending(path: "failure.py")
        try "import json\nprint(json.dumps({'error': 'No Hugging Face token found'}))\nraise SystemExit(1)".write(
            to: script, atomically: true, encoding: .utf8
        )
        #expect(throws: DiarizerError.scriptFailed("No Hugging Face token found")) {
            try Diarizer(python: URL(filePath: "/usr/bin/python3"), script: script)
                .run(on: directory.appending(path: "unused.wav"), numberOfSpeakers: nil)
        }
    }

    @Test("decodes diarization turns and normalized 256-value speaker centroids")
    func decodesSpeakerCentroids() throws {
        var embedding = Array(repeating: 0.0, count: 256)
        embedding[0] = 1
        let data = try JSONSerialization.data(withJSONObject: [
            "model": "pyannote/speaker-diarization-community-1@revision",
            "segments": [
                ["start": 0.0, "end": 1.5, "speaker": "SPEAKER_00"],
                ["start": 2.0, "end": 3.0, "speaker": "SPEAKER_00"],
            ],
            "speakers": [
                ["speaker": "SPEAKER_00", "embedding": embedding],
            ],
        ])

        let result = try Diarizer.decode(data)

        #expect(result.modelVersion == "pyannote/speaker-diarization-community-1@revision")
        #expect(result.turns.count == 2)
        #expect(result.clusters.count == 1)
        #expect(result.clusters[0].speakerLabel == "SPEAKER_00")
        #expect(result.clusters[0].embedding.count == 256)
        #expect(result.clusters[0].speechDurationSeconds == 2.5)
    }

    @Test("rejects malformed speaker centroids")
    func rejectsMalformedCentroids() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "model": "model@revision",
            "segments": [],
            "speakers": [
                ["speaker": "SPEAKER_00", "embedding": [0.5, 0.5]],
            ],
        ])

        #expect(throws: DiarizerError.invalidEmbedding) {
            try Diarizer.decode(data)
        }
    }

    @Test func assignsSpeakerByGreatestTimestampOverlap() {
        let segments = [
            TranscriptSegment(startMs: 0, endMs: 2_000, text: "Hello."),
            TranscriptSegment(startMs: 2_000, endMs: 4_000, text: "Hi."),
            TranscriptSegment(startMs: 5_000, endMs: 6_000, text: "Unassigned."),
        ]
        let turns = [
            DiarizationTurn(start: 0, end: 1.8, speakerLabel: "SPEAKER_04"),
            DiarizationTurn(start: 1.8, end: 4.0, speakerLabel: "SPEAKER_09"),
        ]

        let merged = SegmentMerger.merge(whisperSegments: segments, diarization: turns)

        #expect(merged.map(\.speakerIndex) == [0, 1, nil])
    }

    @Test func emptyDiarizationLeavesTranscriptUnchanged() {
        let segments = [TranscriptSegment(startMs: 0, endMs: 1_000, text: "Hello.")]

        #expect(SegmentMerger.merge(whisperSegments: segments, diarization: []) == segments)
    }

    @Test("large diarization output is drained before waiting for process exit", .enabled(if: TestEnvironment.canRunSpeakerScript))
    func drainsLargeDiarizationOutput() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "diarizer-output-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appending(path: "large-output.py")
        try """
            import json
            import signal
            # A watchdog, not a deadline: if the reader stops draining the pipe this script blocks
            # on a full buffer and the alarm ends the test. Three seconds was short enough to fire
            # while the machine was busy with the rest of the suite, which failed the test for the
            # load rather than for the drain.
            signal.alarm(30)
            segments = [
                {"start": index / 10, "end": index / 10 + 0.05, "speaker": "SPEAKER_00"}
                for index in range(12000)
            ]
            print(json.dumps(segments))
            """.write(to: script, atomically: true, encoding: .utf8)

        let result = try Diarizer(
            python: URL(filePath: "/usr/bin/python3"),
            script: script
        ).run(on: directory.appending(path: "unused.wav"), numberOfSpeakers: nil)

        #expect(result.turns.count == 12_000)
    }

    @Test("hung diarization is terminated at the configured deadline")
    func timesOutHungProcess() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "diarizer-timeout-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appending(path: "hung.py")
        try "import time\ntime.sleep(5)\n".write(to: script, atomically: true, encoding: .utf8)

        #expect(throws: DiarizerError.timedOut) {
            try Diarizer(
                python: URL(filePath: "/usr/bin/python3"),
                script: script,
                timeout: 0.05
            ).run(on: directory.appending(path: "unused.wav"), numberOfSpeakers: nil)
        }
    }
}
