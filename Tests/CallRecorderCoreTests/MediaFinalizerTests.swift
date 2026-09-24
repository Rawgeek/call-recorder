import CallRecorderCore
import Foundation
import Testing
@testable import CallRecorderApp

@Suite("Media finalizer")
struct MediaFinalizerTests {
    @Test("two capture segments become one readable audio file without deleting sources", .enabled(if: TestEnvironment.hasFFmpeg))
    func joinsSegmentsAndRetainsSources() async throws {
        // Given
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "call-recorder-finalizer-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ffmpeg = URL(filePath: "/opt/homebrew/bin/ffmpeg")
        let ffprobe = URL(filePath: "/opt/homebrew/bin/ffprobe")
        let segments = try [440, 880].enumerated().map { index, frequency in
            let url = directory.appending(path: "segment-00\(index + 1).mp4")
            let result = try ProcessRunner.run(
                executable: ffmpeg,
                arguments: [
                    "-v", "error", "-f", "lavfi",
                    "-i", "sine=frequency=\(frequency):duration=0.2",
                    "-c:a", "aac", url.path,
                ]
            )
            #expect(result.exitCode == 0)
            return CaptureSegment(index: index + 1, fileURL: url)
        }

        // When the recording is finalized, and then the file a person plays it from is asked for.
        // The mix is a separate step on purpose: it is a second encode of the whole call, and the
        // transcript is written from the two sides rather than from it.
        let finalizer = MediaFinalizer(ffmpeg: ffmpeg, ffprobe: ffprobe)
        let tracks = try await finalizer.finalizeTracks(segments: segments, destination: directory)
        let finalURL = try await finalizer.writeCompatibilityMix(
            system: tracks.system,
            microphone: tracks.microphone,
            destination: directory
        )

        // Then
        #expect(finalURL == directory.appending(path: "call.m4a"))
        #expect(FileManager.default.fileExists(atPath: finalURL.path))
        #expect(segments.allSatisfy { FileManager.default.fileExists(atPath: $0.fileURL.path) })
        let probe = try ProcessRunner.run(
            executable: ffprobe,
            arguments: [
                "-v", "error", "-show_entries", "format=duration",
                "-of", "default=noprint_wrappers=1:nokey=1", finalURL.path,
            ]
        )
        #expect(probe.exitCode == 0)
        #expect((Double(probe.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) > 0.3)
    }

    @Test("microphone and system segments remain separate after finalization", .enabled(if: TestEnvironment.hasFFmpeg))
    func finalizesIndependentAudioSources() async throws {
        // Given
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "source-finalizer-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ffmpeg = URL(filePath: "/opt/homebrew/bin/ffmpeg")
        let ffprobe = URL(filePath: "/opt/homebrew/bin/ffprobe")
        var segments: [CaptureSegment] = []
        for index in 1...2 {
            let system = directory.appending(path: String(format: "system-%03d.m4a", index))
            let microphone = directory.appending(path: String(format: "microphone-%03d.m4a", index))
            for (url, frequency) in [(system, 400 + index * 10), (microphone, 800 + index * 10)] {
                let generated = try ProcessRunner.run(
                    executable: ffmpeg,
                    arguments: [
                        "-v", "error", "-f", "lavfi",
                        "-i", "sine=frequency=\(frequency):duration=0.2",
                        "-c:a", "aac", url.path,
                    ]
                )
                #expect(generated.exitCode == 0)
            }
            segments.append(
                try CaptureSegment(
                    index: index,
                    system: CapturedAudioSource(
                        fileURL: system,
                        firstPresentationSeconds: Double(index),
                        durationSeconds: 0.2
                    ),
                    microphone: CapturedAudioSource(
                        fileURL: microphone,
                        firstPresentationSeconds: Double(index) + 0.01,
                        durationSeconds: 0.2
                    )
                )
            )
        }

        // When
        let result = try await MediaFinalizer(ffmpeg: ffmpeg, ffprobe: ffprobe)
            .finalizeTracks(segments: segments, destination: directory)

        // Then
        #expect(result.system == directory.appending(path: "system.m4a"))
        #expect(result.microphone == directory.appending(path: "microphone.m4a"))
        for output in [result.system, result.microphone].compactMap({ $0 }) {
            let probe = try ProcessRunner.run(
                executable: ffprobe,
                arguments: [
                    "-v", "error", "-show_entries", "format=duration",
                    "-of", "default=noprint_wrappers=1:nokey=1", output.path,
                ]
            )
            #expect(probe.exitCode == 0)
            #expect((Double(probe.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) > 0.3)
        }
    }

    @Test("source presentation times remain aligned in finalized audio", .enabled(if: TestEnvironment.hasFFmpeg))
    func preservesSourceTimelineOffsets() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "source-timeline-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ffmpeg = URL(filePath: "/opt/homebrew/bin/ffmpeg")
        let ffprobe = URL(filePath: "/opt/homebrew/bin/ffprobe")
        var segments: [CaptureSegment] = []
        for (index, presentation) in [10.0, 10.5].enumerated() {
            let source = directory.appending(path: String(format: "system-%03d.m4a", index + 1))
            _ = try ProcessRunner.runChecked(
                executable: ffmpeg,
                arguments: [
                    "-v", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=0.2",
                    "-c:a", "aac", source.path,
                ]
            )
            segments.append(
                try CaptureSegment(
                    index: index + 1,
                    system: CapturedAudioSource(
                        fileURL: source,
                        firstPresentationSeconds: presentation,
                        durationSeconds: 0.2
                    ),
                    microphone: nil
                )
            )
        }

        let result = try await MediaFinalizer(ffmpeg: ffmpeg, ffprobe: ffprobe)
            .finalizeTracks(segments: segments, destination: directory)
        let output = try #require(result.system)
        let probe = try ProcessRunner.runChecked(
            executable: ffprobe,
            arguments: [
                "-v", "error", "-show_entries", "format=duration",
                "-of", "default=noprint_wrappers=1:nokey=1", output.path,
            ]
        )
        let duration = try #require(
            Double(probe.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines))
        )
        #expect(duration > 0.65)
        #expect(duration < 0.9)
    }

    @Test("a single unbroken track is copied, not encoded a second time", .enabled(if: TestEnvironment.hasFFmpeg))
    func singleSegmentTrackIsCopiedRatherThanEncoded() async throws {
        // Given one segment holding both sides, which is what a call without a pause produces.
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "single-segment-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ffmpeg = URL(filePath: "/opt/homebrew/bin/ffmpeg")
        let ffprobe = URL(filePath: "/opt/homebrew/bin/ffprobe")
        let systemSource = directory.appending(path: "system-001.m4a")
        let microphoneSource = directory.appending(path: "microphone-001.m4a")
        for (url, frequency) in [(systemSource, 440), (microphoneSource, 880)] {
            try ProcessRunner.runChecked(
                executable: ffmpeg,
                arguments: [
                    "-v", "error", "-f", "lavfi", "-i", "sine=frequency=\(frequency):duration=0.2",
                    "-c:a", "aac", url.path,
                ]
            )
        }
        let segments = [
            try CaptureSegment(
                index: 1,
                system: CapturedAudioSource(
                    fileURL: systemSource,
                    firstPresentationSeconds: 0,
                    durationSeconds: 0.2
                ),
                microphone: CapturedAudioSource(
                    fileURL: microphoneSource,
                    firstPresentationSeconds: 0,
                    durationSeconds: 0.2
                )
            )
        ]

        // When
        let finalizer = MediaFinalizer(ffmpeg: ffmpeg, ffprobe: ffprobe)
        let result = try await finalizer.finalizeTracks(segments: segments, destination: directory)

        // Then each track is the recorded stream packet for packet, so nothing was decoded and
        // encoded again on the way to disk.
        let system = try #require(result.system)
        let microphone = try #require(result.microphone)
        #expect(try packetHash(of: system, ffmpeg: ffmpeg) == packetHash(of: systemSource, ffmpeg: ffmpeg))
        #expect(
            try packetHash(of: microphone, ffmpeg: ffmpeg)
                == packetHash(of: microphoneSource, ffmpeg: ffmpeg)
        )
        // And the mix still carries both sides.
        let mix = try await finalizer.writeCompatibilityMix(
            system: result.system,
            microphone: result.microphone,
            destination: directory
        )
        let probe = try ProcessRunner.runChecked(
            executable: ffprobe,
            arguments: [
                "-v", "error", "-show_entries", "format=duration",
                "-of", "default=noprint_wrappers=1:nokey=1", mix.path,
            ]
        )
        #expect(
            (Double(probe.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) > 0.15
        )
    }

    @Test("a track is copied even when the manifest arrives without durations", .enabled(if: TestEnvironment.hasFFmpeg))
    func copiesATrackWithoutDurations() async throws {
        // Given one source per side, shaped the way a finished recording hands it over: the URLs,
        // and no durations, because a queue that carries only paths loses the numbers.
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "no-durations-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ffmpeg = URL(filePath: "/opt/homebrew/bin/ffmpeg")
        let ffprobe = URL(filePath: "/opt/homebrew/bin/ffprobe")
        let systemSource = directory.appending(path: "system-001.m4a")
        try ProcessRunner.runChecked(
            executable: ffmpeg,
            arguments: [
                "-v", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=0.2",
                "-c:a", "aac", systemSource.path,
            ]
        )
        let segments = [
            try CaptureSegment(
                index: 1,
                system: CapturedAudioSource(
                    fileURL: systemSource,
                    firstPresentationSeconds: 0,
                    durationSeconds: 0
                ),
                microphone: nil
            )
        ]

        // When
        let result = try await MediaFinalizer(ffmpeg: ffmpeg, ffprobe: ffprobe)
            .finalizeTracks(segments: segments, destination: directory)

        // Then the file is the recorded stream packet for packet: a remux rather than a decode into
        // a wave with an encode behind it. A zero duration used to send this exact shape to the
        // wave renderer — the 2026-09-21 call spent minutes there, and the phase it was in read
        // "Writing the audio file" while it did.
        let system = try #require(result.system)
        #expect(try packetHash(of: system, ffmpeg: ffmpeg) == packetHash(of: systemSource, ffmpeg: ffmpeg))
    }

    /// The hash of a file's audio packets as they are, without decoding them.
    private func packetHash(of url: URL, ffmpeg: URL) throws -> String {
        let result = try ProcessRunner.runChecked(
            executable: ffmpeg,
            arguments: [
                "-v", "error", "-i", url.path, "-map", "0:a:0", "-c", "copy",
                "-f", "hash", "-hash", "sha256", "-",
            ]
        )
        return result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
