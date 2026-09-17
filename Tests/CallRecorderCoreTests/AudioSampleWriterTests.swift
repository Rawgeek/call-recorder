import AVFoundation
import CallRecorderCore
import Foundation
import Testing
@testable import CallRecorderApp

@Suite("Audio sample writer")
struct AudioSampleWriterTests {
    @Test("PCM sample buffers become one readable AAC source")
    func writesReadableAudioFromSampleBuffers() async throws {
        // Given
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "audio-writer-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "source.m4a")
        let destination = directory.appending(path: "system-001.m4a")
        let ffmpeg = URL(filePath: "/opt/homebrew/bin/ffmpeg")
        let generated = try ProcessRunner.run(
            executable: ffmpeg,
            arguments: [
                "-v", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=0.2",
                "-c:a", "aac", source.path,
            ]
        )
        #expect(generated.exitCode == 0)
        let asset = AVURLAsset(url: source)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM]
        )
        reader.add(output)
        #expect(reader.startReading())
        let writer = AudioSampleWriter(destination: destination)

        // When
        while let sampleBuffer = output.copyNextSampleBuffer() {
            try writer.append(sampleBuffer)
        }
        let captured = try #require(try await writer.finish())

        // Then
        #expect(captured.fileURL == destination)
        #expect(captured.durationSeconds > 0.15)
        let probe = try ProcessRunner.run(
            executable: URL(filePath: "/opt/homebrew/bin/ffprobe"),
            arguments: [
                "-v", "error", "-show_entries", "format=duration",
                "-of", "default=noprint_wrappers=1:nokey=1", destination.path,
            ]
        )
        #expect(probe.exitCode == 0)
        #expect((Double(probe.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) > 0.15)
    }

    @Test("a writer with no samples has no captured source")
    func emptyWriterReturnsNoSource() async throws {
        // Given
        let destination = FileManager.default.temporaryDirectory
            .appending(path: "empty-writer-\(UUID().uuidString).m4a")
        let writer = AudioSampleWriter(destination: destination)

        // When
        let captured = try await writer.finish()

        // Then
        #expect(captured == nil)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }
}
