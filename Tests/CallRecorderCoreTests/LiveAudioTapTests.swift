import AVFoundation
import CoreAudio
import CoreMedia
import Foundation
import Testing
@testable import CallRecorderApp

/// The format the live tap reads a captured buffer in.
///
/// The tests that matter here are the two refusals. The microphone side of a browser call delivered
/// a description with no channel in it on 2026-09-23, `AVAudioFormat(cmAudioFormatDescription:)`
/// answered with a format of zero channels rather than nothing, and `AVAudioPCMBuffer(pcmFormat:)`
/// died inside itself on the capture callback's own queue — twice, four and five seconds into
/// recordings that had started by themselves. Measured in a probe: a LinearPCM description with
/// `mChannelsPerFrame` set to 0 kills the buffer's initializer at address 0.
@Suite("Live audio tap format")
struct LiveAudioTapFormatTests {
    private func stream(
        rate: Double = 48_000,
        channels: UInt32 = 1,
        bits: UInt32 = 32,
        flags: AudioFormatFlags = kAudioFormatFlagIsFloat
            | kAudioFormatFlagIsPacked
            | kAudioFormatFlagIsNonInterleaved
    ) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: rate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: flags,
            mBytesPerPacket: bits / 8,
            mFramesPerPacket: 1,
            mBytesPerFrame: bits / 8,
            mChannelsPerFrame: channels,
            mBitsPerChannel: bits,
            mReserved: 0
        )
    }

    @Test("the shape a microphone delivers is described, in the layout it arrived in")
    func describesTheCaptureFormat() {
        let format = LiveAudioTap.format(from: stream())
        #expect(format?.commonFormat == .pcmFormatFloat32)
        #expect(format?.sampleRate == 48_000)
        #expect(format?.channelCount == 1)
        #expect(format?.isInterleaved == false)
    }

    @Test("a description with no rate in it is refused rather than used")
    func refusesNoRate() {
        #expect(LiveAudioTap.format(from: stream(rate: 0)) == nil)
    }

    @Test("a description with no channel in it is refused rather than used")
    func refusesNoChannel() {
        #expect(LiveAudioTap.format(from: stream(channels: 0)) == nil)
    }

    @Test("an interleaved integer capture is described as interleaved")
    func describesInterleavedInteger() {
        let format = LiveAudioTap.format(
            from: stream(
                channels: 2,
                bits: 16,
                flags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
            )
        )
        #expect(format?.commonFormat == .pcmFormatInt16)
        #expect(format?.channelCount == 2)
        #expect(format?.isInterleaved == true)
    }

    @Test("a sample shape the app does not read is refused")
    func refusesUnknownLayouts() {
        #expect(
            LiveAudioTap.format(
                from: stream(bits: 8, flags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked)
            ) == nil
        )
        // Float samples that are not packed are not a layout a capture hands over.
        #expect(LiveAudioTap.format(from: stream(flags: kAudioFormatFlagIsFloat)) == nil)
    }

    // MARK: - The buffer as the capture hands it over

    /// A captured buffer, built the way a capture builds one, for the tests below.
    ///
    /// A description with no channel is what the microphone stream of a browser call delivered on
    /// 2026-09-23. Core Audio builds that description happily, and the buffer built from it is the
    /// one that kills `AVAudioPCMBuffer(pcmFormat:)`.
    private func capturedBuffer(
        channels: UInt32,
        frames: Int = 4_800,
        perChannel: [Float] = [0],
        flags: AudioFormatFlags = kAudioFormatFlagIsFloat
            | kAudioFormatFlagIsPacked
            | kAudioFormatFlagIsNonInterleaved
    ) -> CMSampleBuffer? {
        var stream = stream(channels: channels, flags: flags)
        // The frames are sized as the layout says, with one channel's worth for the description that
        // carries no channel at all: that pair is the shape the crash probe found, and Core Audio
        // builds the description without complaint.
        let bytesPerFrame = 4 * max(channels, 1)
        stream.mBytesPerPacket = bytesPerFrame
        stream.mBytesPerFrame = bytesPerFrame
        var description: CMAudioFormatDescription?
        guard
            CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                asbd: &stream,
                layoutSize: 0,
                layout: nil,
                magicCookieSize: 0,
                magicCookie: nil,
                extensions: nil,
                formatDescriptionOut: &description
            ) == noErr,
            let description
        else { return nil }
        let bytes = frames * Int(bytesPerFrame)
        var block: CMBlockBuffer?
        guard
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: bytes,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: bytes,
                flags: 0,
                blockBufferOut: &block
            ) == noErr,
            let block
        else { return nil }
        if perChannel.contains(where: { $0 != 0 }) {
            var pointer: UnsafeMutablePointer<CChar>?
            var length = 0
            guard
                // The block was made without memory of its own, so the memory is asked for before
                // it is written into: reading the pointer first answers no pointer at all.
                CMBlockBufferAssureBlockMemory(block) == noErr,
                CMBlockBufferGetDataPointer(
                    block,
                    atOffset: 0,
                    lengthAtOffsetOut: nil,
                    totalLengthOut: &length,
                    dataPointerOut: &pointer
                ) == noErr,
                let pointer
            else { return nil }
            let samples = UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: Float.self)
            // One value per channel, repeated frame by frame, so a test can say what a mix of the
            // channels has to be: a pick of one channel and a mean of them are different numbers.
            let count = length / MemoryLayout<Float>.size
            let width = max(1, Int(channels))
            for index in 0..<count { samples[index] = perChannel[(index % width) % perChannel.count] }
        }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 48_000),
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        )
        var buffer: CMSampleBuffer?
        let status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: description,
            sampleCount: frames,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &buffer
        )
        return status == noErr ? buffer : nil
    }

    @Test("a buffer whose description has no channel is skipped, not turned into a frame")
    func tapSkipsChannelwiseDegenerateBuffer() throws {
        let buffer = try #require(capturedBuffer(channels: 0), "Core Audio builds this description")
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "live-tap-" + UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tap = LiveAudioTap(directory: directory, offsetSeconds: 0) { _ in }
        tap.append(buffer, source: .microphone)
        tap.finish()
        let written = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(written.isEmpty)
    }

    @Test("a buffer with no usable format does not cancel the side it belongs to")
    func writerSkipsUnusableFormat() throws {
        let buffer = try #require(capturedBuffer(channels: 0), "Core Audio builds this description")
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "writer-" + UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = AudioSampleWriter(destination: directory.appending(path: "microphone.m4a"))
        // Throwing here is what the router reads as a failed track, which cancels the whole side.
        try writer.append(buffer)
    }

    /// What the tap handed over, collected from the tap's own queue.
    private final class ChunkBox: @unchecked Sendable {
        private let lock = NSLock()
        private var collected: [LiveAudioTap.Chunk] = []

        func append(_ chunk: LiveAudioTap.Chunk) {
            lock.withLock { collected.append(chunk) }
        }

        var chunks: [LiveAudioTap.Chunk] { lock.withLock { collected } }
    }

    @Test("a microphone stream in a layout AVAudioFormat has no form for is still read")
    func downmixesWideInterleavedAudio() throws {
        // Measured on 2026-09-23 from the running app: the microphone of a browser call arrived as
        // three channels of packed float at 48 kHz, interleaved. AVAudioFormat describes one or two
        // channels interleaved and any number laid out apart, so the tap skipped every buffer of
        // that call, and the live window showed the far side of it and none of the near one.
        let buffer = try #require(
            capturedBuffer(
                channels: 3,
                // A fifth of a second, so the resampler's output is past the tenth of a second the
                // tap cuts a chunk at with room to spare: a converted buffer can arrive a sample or
                // two short of the arithmetic, and the chunk would wait for the next one.
                frames: 9_600,
                // One channel loud, one half, one silent. Their mean is the half, and a pass that
                // took the first channel, the last, or the loudest would answer with another number.
                perChannel: [1, 0.5, 0],
                flags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
            )
        )
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "live-tap-" + UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let box = ChunkBox()
        let tap = LiveAudioTap(directory: directory, offsetSeconds: 0, chunkSeconds: 0.1) {
            box.append($0)
        }
        tap.append(buffer, source: .microphone)
        tap.finish()
        let chunk = try #require(box.chunks.first)
        let file = try AVAudioFile(forReading: chunk.fileURL)
        #expect(file.fileFormat.channelCount == 1)
        #expect(abs(file.fileFormat.sampleRate - 16_000) < 50)
        let read = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4_000))
        try file.read(into: read)
        // Three channels of the same sample average to that sample: the mix is a mean of every
        // channel, because a preview needs every voice in it and not a pick of one. The loudest of
        // the read samples is compared rather than the first, because a resampler settles over its
        // first few frames and that is a property of the converter, not of the mix.
        let channel = try #require(read.floatChannelData?[0])
        let peak = (0..<Int(read.frameLength)).map { abs(channel[$0]) }.max() ?? 0
        #expect(abs(Double(peak) - 0.5) < 0.05)
    }
}
