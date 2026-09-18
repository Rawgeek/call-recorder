import AVFoundation
import CallRecorderCore
import Foundation
import Testing
@testable import CallRecorderApp

@Suite("Native media processor")
struct NativeMediaProcessorTests {
    @Test("native finalization keeps sources, timing gaps, and one-track outputs")
    func finalizesSourcesAndPreservesGaps() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "native-media-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appending(path: "system-001.wav")
        let second = directory.appending(path: "system-002.wav")
        let microphone = directory.appending(path: "microphone-001.wav")
        try makeTone(at: first, frequency: 440, duration: 0.10)
        try makeTone(at: second, frequency: 660, duration: 0.10)
        try makeTone(at: microphone, frequency: 880, duration: 0.10)
        let segments = [
            try CaptureSegment(
                index: 1,
                system: CapturedAudioSource(
                    fileURL: first,
                    firstPresentationSeconds: 10,
                    durationSeconds: 0.10
                ),
                microphone: CapturedAudioSource(
                    fileURL: microphone,
                    firstPresentationSeconds: 10.05,
                    durationSeconds: 0.10
                )
            ),
            try CaptureSegment(
                index: 2,
                system: CapturedAudioSource(
                    fileURL: second,
                    firstPresentationSeconds: 10.35,
                    durationSeconds: 0.10
                ),
                microphone: nil
            ),
        ]

        let result = try await NativeMediaProcessor().finalizeSources(
            segments: segments,
            destination: directory
        )

        let system = try #require(result.system)
        let microphoneOutput = try #require(result.microphone)
        #expect(system.deletingPathExtension().lastPathComponent == "system")
        #expect(microphoneOutput.deletingPathExtension().lastPathComponent == "microphone")
        #expect(result.compatibilityMix.deletingPathExtension().lastPathComponent == "call")
        for source in [first, second, microphone] {
            #expect(FileManager.default.fileExists(atPath: source.path))
        }
        for output in [result.system, result.microphone, result.compatibilityMix].compactMap({ $0 }) {
            let asset = AVURLAsset(url: output)
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            #expect(tracks.count == 1)
            #expect(CMTimeGetSeconds(try await asset.load(.duration)) > 0)
            let descriptions = try await tracks[0].load(.formatDescriptions)
            let description = try #require(descriptions.first)
            let stream = try #require(
                CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee
            )
            switch output.pathExtension {
            case "m4a":
                #expect(stream.mFormatID == kAudioFormatMPEG4AAC)
            case "wav":
                #expect(stream.mFormatID == kAudioFormatLinearPCM)
                #expect(stream.mSampleRate == 48_000)
                #expect(stream.mChannelsPerFrame == 2)
                #expect(stream.mBitsPerChannel == 16)
                #expect(stream.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0)
            default:
                Issue.record("Unexpected native output extension: \(output.pathExtension)")
            }
        }
        let systemDuration = CMTimeGetSeconds(try await AVURLAsset(url: system).load(.duration))
        #expect(systemDuration > 0.40)
        #expect(systemDuration < 0.60)
        let partials = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.contains(".partial.") || $0.contains(".mix.") || $0.hasSuffix(".caf") }
        #expect(partials.isEmpty)
    }

    @Test("native finalization reuses honest WAV fallback sources")
    func reusesWAVFallbackSources() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "native-media-fallback-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let capturedSystem = directory.appending(path: "captured-system.wav")
        let capturedMicrophone = directory.appending(path: "captured-microphone.wav")
        try makeTone(at: capturedSystem, frequency: 440, duration: 0.10)
        try makeTone(at: capturedMicrophone, frequency: 880, duration: 0.10)
        let system = directory.appending(path: "system.wav")
        let microphone = directory.appending(path: "microphone.wav")
        let mix = directory.appending(path: "call.wav")
        try makeTone(at: system, frequency: 440, duration: 0.10, channels: 2)
        try makeTone(at: microphone, frequency: 880, duration: 0.10, channels: 2)
        try makeTone(at: mix, frequency: 660, duration: 0.10, channels: 2)

        let result = try await NativeMediaProcessor().finalizeSources(
            segments: [
                try CaptureSegment(
                    index: 1,
                    system: CapturedAudioSource(
                        fileURL: capturedSystem,
                        firstPresentationSeconds: 10,
                        durationSeconds: 0.10
                    ),
                    microphone: CapturedAudioSource(
                        fileURL: capturedMicrophone,
                        firstPresentationSeconds: 10,
                        durationSeconds: 0.10
                    )
                ),
            ],
            destination: directory
        )

        #expect(result.system == system)
        #expect(result.microphone == microphone)
        #expect(result.compatibilityMix == mix)
    }

    @Test("native Whisper chunks are signed 16-bit, mono, and 16 kHz")
    func preparesWhisperWAVChunks() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "native-whisper-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = directory.appending(path: "source.wav")
        try makeTone(at: audio, frequency: 440, duration: 0.28)
        let chunkDirectory = directory.appending(path: "chunks", directoryHint: .isDirectory)

        let chunks = try await NativeMediaProcessor().prepareWhisperChunks(
            audio: audio,
            directory: chunkDirectory,
            maximumDurationSeconds: 0.12
        )

        #expect(chunks.count == 3)
        #expect(chunks.map(\.startMilliseconds) == [0, 120, 240])
        for chunk in chunks {
            let file = try AVAudioFile(forReading: chunk.fileURL)
            #expect(file.fileFormat.sampleRate == 16_000)
            #expect(file.fileFormat.channelCount == 1)
            #expect(file.fileFormat.commonFormat == .pcmFormatInt16)
            #expect(file.length > 0)
        }
    }

    @Test("chunk ranges cap each chunk at five minutes and retain the actual final offset")
    func calculatesChunkRanges() throws {
        let ranges = NativeMediaProcessor.chunkRanges(durationSeconds: 601.25)

        #expect(ranges.count == 3)
        #expect(ranges.map(\.start) == [0, 300, 600])
        #expect(ranges.map(\.duration) == [300, 300, 1.25])
        #expect(ranges.allSatisfy { $0.duration <= 300 })
    }

    @Test("cancellation remains cancellation and publishes no Whisper chunks")
    func cancelledPreparationPublishesNothing() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "native-cancel-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = directory.appending(path: "source.wav")
        try makeTone(at: audio, frequency: 440, duration: 0.28)
        let chunks = directory.appending(path: "chunks", directoryHint: .isDirectory)
        let cancellation = ProcessCancellation()
        cancellation.cancel()

        await #expect(throws: CancellationError.self) {
            try await NativeMediaProcessor().prepareWhisperChunks(
                audio: audio,
                directory: chunks,
                maximumDurationSeconds: 0.12,
                cancellation: cancellation
            )
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: chunks.path).isEmpty)
    }

    private func makeTone(
        at url: URL,
        frequency: Double,
        duration: Double,
        channels: AVAudioChannelCount = 1
    ) throws {
        let format = try #require(
            AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: 48_000,
                channels: channels,
                interleaved: false
            )
        )
        let frameCount = AVAudioFrameCount((duration * format.sampleRate).rounded())
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        let channelData = try #require(buffer.int16ChannelData)
        for channel in 0..<Int(channels) {
            for frame in 0..<Int(frameCount) {
                channelData[channel][frame] = Int16(
                    sin(2 * .pi * frequency * Double(frame) / format.sampleRate)
                        * Double(Int16.max) * 0.2
                )
            }
        }
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatInt16,
            interleaved: false
        )
        try file.write(from: buffer)
    }
}
