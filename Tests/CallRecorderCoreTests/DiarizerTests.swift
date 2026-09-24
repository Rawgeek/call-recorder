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
            // The turn model is named beside the embedder, because a voice print is only compared
            // with one stored under the same string. A reader that does not know the key has to
            // pass it by rather than refuse the whole answer.
            "turnModel": "nvidia/Nemotron-3-Diarization@revision",
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

    @Test(
        "a call read in windows is one call of turns, and one voice keeps one name",
        .enabled(if: TestEnvironment.canRunSpeakerScript)
    )
    func joinsWindowsAndVoices() throws {
        // The rules the script applies to a long call are plain functions over plain data, so they
        // are checked here without a model: which stretches a call is read in, which runs are
        // joined, and which voices of two stretches are one person.
        let script = TestEnvironment.packageRoot
            .appending(path: "Sources/CallRecorderApp/diarize.py")
        let driver = FileManager.default.temporaryDirectory
            .appending(path: "window-driver-\(UUID().uuidString).py")
        defer { try? FileManager.default.removeItem(at: driver) }
        try """
        import importlib.util, sys

        spec = importlib.util.spec_from_file_location("diarize", sys.argv[1])
        diarize = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(diarize)

        def fail(message):
            raise SystemExit(message)

        # A nineteen-minute call is read in one stretch; a seventy-minute call is read in windows
        # that cover it end to end, none longer than the limit.
        if diarize.window_slices(int(1140 * diarize.SAMPLING_RATE)) != [(0.0, 0, 1140 * 16000)]:
            fail("a call under the threshold was split")
        slices = diarize.window_slices(int(4200 * diarize.SAMPLING_RATE))
        if len(slices) != 9:
            fail("seventy minutes came out in %d windows" % len(slices))
        if slices[0][1] != 0 or slices[-1][2] != 4200 * 16000:
            fail("the windows do not cover the call")
        if any(b != c for (_, _, b), (_, c, _) in zip(slices, slices[1:])):
            fail("the windows leave a gap")
        if any((last - first) / diarize.SAMPLING_RATE > diarize.WINDOW_SECONDS for _, first, last in slices):
            fail("a window is longer than the limit")

        # A run too short to be speech is dropped, and two runs of one voice 0.2 s apart are one
        # turn -- unless another voice speaks inside the pause, which keeps them apart.
        turns = [
            {"Start": 5.0, "End": 5.1, "Speaker": 0},
            {"Start": 6.0, "End": 6.9, "Speaker": 0},
            {"Start": 7.1, "End": 8.0, "Speaker": 0},
            {"Start": 20.0, "End": 21.0, "Speaker": 1},
            {"Start": 21.2, "End": 22.0, "Speaker": 1},
        ]
        kept = diarize.long_enough(turns)
        if [segment["speaker"] for segment in kept] != ["SPEAKER_00", "SPEAKER_00", "SPEAKER_01", "SPEAKER_01"]:
            fail("a run under a quarter of a second was kept: %r" % kept)
        joined = diarize.joined_runs(kept)
        if joined[0] != {"start": 6.0, "end": 8.0, "speaker": "SPEAKER_00"}:
            fail("two runs of one voice did not join: %r" % joined[0])
        if len(joined) != 2 or joined[1]["end"] != 22.0:
            fail("the other voice's runs did not join: %r" % joined)
        interrupted = diarize.joined_runs([
            {"start": 6.0, "end": 6.9, "speaker": "SPEAKER_00"},
            {"start": 6.95, "end": 7.05, "speaker": "SPEAKER_01"},
            {"start": 7.1, "end": 8.0, "speaker": "SPEAKER_00"},
        ])
        if len(interrupted) != 3:
            fail("a pause with another voice in it was joined: %r" % interrupted)

        # The same person in the second window is named as the first window named them, and a
        # person who only appears in the second window is a voice of their own.
        def value(index):
            vector = [0.0] * diarize.EMBEDDING_DIMENSION
            vector[index] = 1.0
            return vector

        def window(start, pairs, turns):
            return {
                "turns": turns,
                "prints": {label: value(index) for label, index in pairs.items()},
                "seconds": {label: 30.0 for label in pairs},
                "arrival": {label: start + position for position, label in enumerate(pairs)},
            }

        segments, speakers = diarize.joined_windows([
            window(0.0, {"SPEAKER_00": 0, "SPEAKER_01": 1}, [
                {"start": 0.0, "end": 30.0, "speaker": "SPEAKER_00"},
                {"start": 30.0, "end": 60.0, "speaker": "SPEAKER_01"},
            ]),
            window(480.0, {"SPEAKER_00": 1, "SPEAKER_02": 2}, [
                {"start": 480.0, "end": 510.0, "speaker": "SPEAKER_00"},
                {"start": 510.0, "end": 540.0, "speaker": "SPEAKER_02"},
            ]),
        ])
        if [segment["speaker"] for segment in segments] != [
            "SPEAKER_00", "SPEAKER_01", "SPEAKER_01", "SPEAKER_02"
        ]:
            fail("a voice of the second window was not joined to its own name: %r" % segments)
        if [voice["speaker"] for voice in speakers] != ["SPEAKER_00", "SPEAKER_01", "SPEAKER_02"]:
            fail("the call came out with the wrong voices: %r" % speakers)
        print("ok")
        """.write(to: driver, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/python3")
        process.arguments = [driver.path, script.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let reported = String(decoding: data, as: UTF8.self)
        #expect(process.terminationStatus == 0, "\(reported)")
        #expect(reported.contains("ok"))
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

        // The third fragment is one second long and starts a second after the last turn ended. It
        // used to come out unlabelled, and the renderer turned that into a "Speaker 1" that no
        // diarization had found. A fragment too short to hold a turn takes the voice of the turn
        // beside it, which is what the user's 2026-09-18 transcript needed.
        #expect(merged.map(\.speakerIndex) == [0, 1, 1])
    }

    @Test("a long fragment no turn covers stays unlabelled")
    func leavesALongUncoveredFragmentAlone() {
        // Ten seconds of speech is a turn, and giving it a neighbour's voice would be inventing a
        // claim the diarization did not make. Only fragments too short to hold a turn are filled.
        let segments = [
            TranscriptSegment(startMs: 0, endMs: 10_000, text: "Первая реплика, длинная и содержательная."),
            TranscriptSegment(startMs: 30_000, endMs: 40_000, text: "Вторая реплика, тоже длинная и без разметки."),
        ]
        let turns = [DiarizationTurn(start: 0, end: 11, speakerLabel: "SPEAKER_00")]

        let merged = SegmentMerger.merge(whisperSegments: segments, diarization: turns)

        #expect(merged.map(\.speakerIndex) == [0, nil])
    }

    @Test("a short fragment inside a turn keeps the voice that was speaking")
    func holdsATurnTogether() {
        // The shape the 2026-09-18 call was made of: a long turn of one voice, and a short fragment
        // straddling the boundary that the next turn covers half of. Greatest overlap alone hands
        // the fragment to the next voice, and the name flips in the middle of a monologue.
        let segments = [
            TranscriptSegment(
                startMs: 0, endMs: 30_000,
                text: "Длинная реплика одного человека про заказ и доставку.", source: .system
            ),
            TranscriptSegment(startMs: 30_500, endMs: 31_500, text: "Ну да.", source: .system),
            TranscriptSegment(
                startMs: 32_000, endMs: 60_000,
                text: "И вот что мы с этим будем делать дальше.", source: .system
            ),
        ]
        let turns = [
            // The fragment straddles the boundary: the voice that was speaking covers 0.45s of it
            // and the next turn covers 0.55s, so greatest overlap alone hands the fragment to the
            // next voice and the name flips in the middle of a monologue.
            DiarizationTurn(start: 0, end: 30.95, speakerLabel: "SPEAKER_00"),
            DiarizationTurn(start: 30.95, end: 60.0, speakerLabel: "SPEAKER_01"),
        ]

        let outcome = SegmentMerger.merging(whisperSegments: segments, diarization: turns)

        // The voice already open on the line before keeps the fragment, because it was active in
        // most of it. The turn after the fragment is a real one and keeps its own voice.
        #expect(outcome.segments.map(\.speakerIndex) == [0, 0, 1])
        #expect(outcome.snappedSegments == 1)
        #expect(outcome.labelChanges == 1)
    }

    @Test("a short run of another voice between two runs is folded into the run before it")
    func absorbsAShortRun() {
        let segments = [
            TranscriptSegment(startMs: 0, endMs: 20_000, text: "Первая длинная реплика участника."),
            TranscriptSegment(startMs: 20_000, endMs: 21_000, text: "Да, конечно."),
            TranscriptSegment(startMs: 21_000, endMs: 40_000, text: "Продолжение той же самой реплики."),
        ]
        let turns = [
            DiarizationTurn(start: 0, end: 20.2, speakerLabel: "SPEAKER_00"),
            DiarizationTurn(start: 20.2, end: 20.9, speakerLabel: "SPEAKER_01"),
            DiarizationTurn(start: 20.9, end: 40.0, speakerLabel: "SPEAKER_00"),
        ]

        let outcome = SegmentMerger.merging(whisperSegments: segments, diarization: turns)

        #expect(outcome.segments.map(\.speakerIndex) == [0, 0, 0])
        #expect(outcome.absorbedRuns == 1)
        #expect(outcome.labelChanges == 0)
    }

    @Test("a real speaker change between two long turns is left alone")
    func keepsARealTurnChange() {
        let segments = [
            TranscriptSegment(
                startMs: 0, endMs: 12_000,
                text: "Первый участник говорит довольно долго о своём."
            ),
            TranscriptSegment(
                startMs: 12_500, endMs: 25_000,
                text: "Второй участник отвечает ему не менее подробно."
            ),
        ]
        let turns = [
            DiarizationTurn(start: 0, end: 12.2, speakerLabel: "SPEAKER_00"),
            DiarizationTurn(start: 12.2, end: 25.0, speakerLabel: "SPEAKER_01"),
        ]

        let outcome = SegmentMerger.merging(whisperSegments: segments, diarization: turns)

        #expect(outcome.segments.map(\.speakerIndex) == [0, 1])
        #expect(outcome.labelChanges == 1)
        #expect(outcome.snappedSegments == 0)
        #expect(outcome.absorbedRuns == 0)
    }

    // MARK: - A voice that came back in pieces

    /// A 256-value centroid pointing at one direction per index, the shape the detector returns.
    private func centroid(_ index: Int) -> [Float] {
        var embedding = Array(repeating: Float.zero, count: 256)
        embedding[index] = 1
        return embedding
    }

    /// A centroid that leans towards a second direction, for a voice heard through another channel.
    private func blendedCentroid(_ first: Int, _ second: Int, blend: Float) -> [Float] {
        var embedding = Array(repeating: Float.zero, count: 256)
        embedding[first] = 1 - blend
        embedding[second] = blend
        return embedding
    }

    @Test("two clusters of one voice are joined before anything is named")
    func joinsAVoiceThatCameBackInPieces() {
        // The shape of the 2026-09-18 17:47 call: one speaker separated into two pieces of a couple
        // of minutes each, next to a long cluster of somebody else. The review window offered three
        // people where there were two, and the transcript drew two names for one voice.
        let result = DiarizationResult(
            modelVersion: "model-v1",
            turns: [
                DiarizationTurn(start: 0, end: 100, speakerLabel: "SPEAKER_00"),
                DiarizationTurn(start: 100, end: 220, speakerLabel: "SPEAKER_01"),
                DiarizationTurn(start: 220, end: 900, speakerLabel: "SPEAKER_02"),
            ],
            clusters: [
                DiarizedSpeakerCluster(
                    speakerLabel: "SPEAKER_00",
                    embedding: centroid(0),
                    speechDurationSeconds: 100
                ),
                DiarizedSpeakerCluster(
                    speakerLabel: "SPEAKER_01",
                    embedding: blendedCentroid(0, 1, blend: 0.1),
                    speechDurationSeconds: 120
                ),
                DiarizedSpeakerCluster(
                    speakerLabel: "SPEAKER_02",
                    embedding: centroid(5),
                    speechDurationSeconds: 700
                ),
            ]
        )

        let outcome = DiarizationVoiceMerge.mergingSplitVoices(result, policy: .default)

        #expect(outcome.mergedClusters == 1)
        #expect(outcome.result.clusters.count == 2)
        // The longer piece keeps its label, and the turns of both pieces take it.
        #expect(outcome.result.clusters.map(\.speakerLabel) == ["SPEAKER_01", "SPEAKER_02"])
        #expect(outcome.result.turns.map(\.speakerLabel) == ["SPEAKER_01", "SPEAKER_01", "SPEAKER_02"])
        // The speech of both pieces is kept: a merged voice holds everything the two said.
        #expect(outcome.result.clusters.first?.speechDurationSeconds == 220)
    }

    @Test("two voices that sound different stay two people")
    func keepsDistinctVoicesApart() {
        let result = DiarizationResult(
            modelVersion: "model-v1",
            turns: [
                DiarizationTurn(start: 0, end: 100, speakerLabel: "SPEAKER_00"),
                DiarizationTurn(start: 100, end: 200, speakerLabel: "SPEAKER_01"),
            ],
            clusters: [
                DiarizedSpeakerCluster(
                    speakerLabel: "SPEAKER_00",
                    embedding: centroid(0),
                    speechDurationSeconds: 100
                ),
                DiarizedSpeakerCluster(
                    speakerLabel: "SPEAKER_01",
                    embedding: centroid(9),
                    speechDurationSeconds: 100
                ),
            ]
        )

        let outcome = DiarizationVoiceMerge.mergingSplitVoices(result, policy: .default)

        #expect(outcome.mergedClusters == 0)
        #expect(outcome.result == result)
    }

    @Test("a separation of one voice is returned as it was")
    func leavesASingleVoiceAlone() {
        let result = DiarizationResult(
            modelVersion: "model-v1",
            turns: [DiarizationTurn(start: 0, end: 100, speakerLabel: "SPEAKER_00")],
            clusters: [
                DiarizedSpeakerCluster(
                    speakerLabel: "SPEAKER_00",
                    embedding: centroid(0),
                    speechDurationSeconds: 100
                )
            ]
        )

        let outcome = DiarizationVoiceMerge.mergingSplitVoices(result, policy: .default)

        #expect(outcome.mergedClusters == 0)
        #expect(outcome.result == result)
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

    @Test(
        "a voice the speaker script cannot embed keeps its turns and loses only matching",
        .enabled(if: TestEnvironment.canRunSpeakerScript)
    )
    func passesOverAVoiceWithoutACentroid() throws {
        // Given: the real speaker script, asked to put built-in centroids through its own rules.
        // One voice carries a value that is not a number and one carries a centroid of the wrong
        // length, which is the pair that ended every pass on the 2026-09-22 13:44 call. Pyannote
        // is not loaded, so the check runs on any Mac.
        let script = TestEnvironment.packageRoot
            .appending(path: "Sources/CallRecorderApp/diarize.py")
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/python3")
        process.arguments = [script.path, "--self-check"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)

        // When
        let result = try Diarizer.decode(data)

        // Then: every voice kept its turns, and only the one with a usable centroid is offered for
        // matching.
        #expect(result.turns.map(\.speakerLabel) == ["SPEAKER_00", "SPEAKER_01", "SPEAKER_02"])
        #expect(result.clusters.map(\.speakerLabel) == ["SPEAKER_00"])
        #expect(result.clusters.first?.embedding.count == 256)
    }
}
