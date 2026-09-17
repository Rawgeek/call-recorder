import AVFoundation
import CallRecorderCore
import Foundation
import Testing
@testable import CallRecorderApp

@Suite("Audio sample writer")
struct AudioSampleWriterTests {
    @Test("PCM sample buffers become one readable AAC source", .enabled(if: TestEnvironment.hasFFmpeg))
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

    @Test("a manifest written before dropped samples were counted still reads")
    func capturedSourceDecodesWithoutACount() throws {
        // Given a segment written by a build that did not count drops.
        let legacy = Data(
            #"{"fileURL":"file:///tmp/system-001.m4a","firstPresentationSeconds":0,"durationSeconds":1.5}"#
                .utf8
        )

        // When
        let source = try JSONDecoder().decode(CapturedAudioSource.self, from: legacy)

        // Then the recording reads as it always did, and nothing is claimed about drops.
        #expect(source.durationSeconds == 1.5)
        #expect(source.droppedSamples == nil)
    }

    @Test("a counted drop survives the manifest round trip")
    func capturedSourceCarriesItsDropCount() throws {
        // Given a segment that lost samples to a busy encoder.
        let source = CapturedAudioSource(
            fileURL: URL(filePath: "/tmp/microphone-001.m4a"),
            firstPresentationSeconds: 0,
            durationSeconds: 2,
            droppedSamples: 3
        )

        // Then the count is still there after the trip through the manifest.
        let data = try JSONEncoder().encode(source)
        #expect(try JSONDecoder().decode(CapturedAudioSource.self, from: data).droppedSamples == 3)
    }

    @Test("a writer fed faster than realtime still saves its audio", .enabled(if: TestEnvironment.hasFFmpeg))
    func writingFasterThanRealtimeStillSaves() async throws {
        // Given a minute of audio handed over as fast as the machine can, which is what a busy
        // disk and a running finalizer look like from the encoder's side.
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "audio-pressure-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "source.m4a")
        let destination = directory.appending(path: "system-001.m4a")
        let ffmpeg = URL(filePath: "/opt/homebrew/bin/ffmpeg")
        try ProcessRunner.runChecked(
            executable: ffmpeg,
            arguments: [
                "-v", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=60",
                "-ar", "48000", "-ac", "2", "-c:a", "aac", source.path,
            ]
        )
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

        // When every buffer is appended without waiting for the clock.
        var appended = 0
        while let sampleBuffer = output.copyNextSampleBuffer() {
            try writer.append(sampleBuffer)
            appended += 1
        }
        let captured = try #require(try await writer.finish())

        // Then the recording is there. A sample the encoder could not take in time is counted and
        // dropped, which costs a click: it no longer costs the whole track, which is what throwing
        // here used to cost.
        #expect(appended > 0)
        #expect(captured.durationSeconds > 55)
        #expect(captured.durationSeconds < 61)
        if let dropped = captured.droppedSamples {
            #expect(dropped > 0)
        }
    }
}
