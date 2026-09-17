import CallRecorderCore
import Foundation
import Testing
@testable import CallRecorderApp

@Suite("Media finalizer")
struct MediaFinalizerTests {
    @Test("two capture segments become one readable audio file without deleting sources")
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

        // When
        let finalURL = try await MediaFinalizer(ffmpeg: ffmpeg, ffprobe: ffprobe)
            .finalize(segments: segments, destination: directory)

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

    @Test("microphone and system segments remain separate after finalization")
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
            .finalizeSources(segments: segments, destination: directory)

        // Then
        #expect(result.system == directory.appending(path: "system.m4a"))
        #expect(result.microphone == directory.appending(path: "microphone.m4a"))
        #expect(result.compatibilityMix == directory.appending(path: "call.m4a"))
        for output in [result.system, result.microphone, result.compatibilityMix].compactMap({ $0 }) {
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

    @Test("source presentation times remain aligned in finalized audio")
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
            .finalizeSources(segments: segments, destination: directory)
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
}
