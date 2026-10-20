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

    // MARK: - The microphone a Bluetooth headset delivers

    /// One buffer of float PCM in the shape the capture delivers it.
    private func buffer(
        samples: [Float],
        sampleRate: Double,
        channels: Int
    ) throws -> CMSampleBuffer {
        var description = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
                | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var format: CMAudioFormatDescription?
        #expect(
            CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                asbd: &description,
                layoutSize: 0,
                layout: nil,
                magicCookieSize: 0,
                magicCookie: nil,
                extensions: nil,
                formatDescriptionOut: &format
            ) == noErr
        )
        let frames = samples.count / channels
        var block: CMBlockBuffer?
        let byteCount = frames * 4 * channels
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block
        )
        #expect(blockStatus == noErr, "CMBlockBufferCreateWithMemoryBlock status \(blockStatus)")
        let blockBuffer = try #require(block)
        var lengthAtOffset = 0
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<CChar>?
        _ = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: &lengthAtOffset,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )
        let destination = try #require(dataPointer)
        _ = samples.withUnsafeBytes { source in
            memcpy(destination, source.baseAddress, source.count)
        }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        )
        var sampleSizes = [4]
        var sample: CMSampleBuffer?
        #expect(
            CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault,
                dataBuffer: blockBuffer,
                formatDescription: try #require(format),
                sampleCount: frames,
                sampleTimingEntryCount: 1,
                sampleTimingArray: &timing,
                sampleSizeEntryCount: 1,
                sampleSizeArray: &sampleSizes,
                sampleBufferOut: &sample
            ) == noErr
        )
        return try #require(sample)
    }

    @Test("the rate a track is encoded at follows the format the capture delivered")
    func theRateFollowsTheFormat() {
        // The system track: 48 kHz stereo keeps the 128 kbps it has always been written at.
        var system = AudioStreamBasicDescription()
        system.mSampleRate = 48_000
        system.mChannelsPerFrame = 2
        #expect(AudioSampleWriter.bitRate(for: system) == 128_000)

        // A Bluetooth headset's microphone: 24 kHz mono, which AAC refuses 128 kbps for when the
        // source format hint says what the source is. Measured on 2026-10-09: every recording made
        // on AirPods dropped its microphone track with "Cannot Encode Media" (-11861 / -12651).
        var headset = AudioStreamBasicDescription()
        headset.mSampleRate = 24_000
        headset.mChannelsPerFrame = 1
        #expect(AudioSampleWriter.bitRate(for: headset) == 48_000)
    }

    @Test("a microphone that delivers 24 kHz mono becomes a readable track")
    func writesABluetoothMicrophonesFormat() async throws {
        // Given the format an AirPods microphone delivers, handed over the way the capture hands
        // it over: a source format hint on the first buffer, which is what the encoder refused the
        // app's fixed 128 kbps for.
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "audio-headset-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appending(path: "microphone-001.m4a")
        let writer = AudioSampleWriter(destination: destination)

        // When a quarter of a second of quiet room is written a buffer at a time.
        var written = 0
        for step in 0..<12 {
            var samples = [Float](repeating: 0.01, count: 500)
            samples[0] = Float(0.05 * sin(Double(step)))
            let sample = try buffer(samples: samples, sampleRate: 24_000, channels: 1)
            try writer.append(sample)
            written += 1
        }
        let captured = try await writer.finish()

        // Then the track is there. Without the derived rate this is where the writer answered
        // "Cannot Encode Media" and the whole microphone side of the call was dropped.
        let source = try #require(captured)
        #expect(written == 12)
        #expect(FileManager.default.fileExists(atPath: source.fileURL.path))
        let asset = AVURLAsset(url: source.fileURL)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let rate = try await track.load(.naturalTimeScale)
        #expect(rate == 24_000)
    }
}
