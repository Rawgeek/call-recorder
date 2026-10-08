import AudioToolbox
import CallRecorderCore
import CoreMedia
import Foundation
import Testing
@testable import CallRecorderApp

/// The measure behind the quiet rail, and the meter that takes it.
///
/// The numbers are the ones measured on four recordings in the library, and the cases that matter
/// most are the ones where the meter cannot answer: a rail that reads a broken meter as silence
/// stops a call that was only quiet.
@Suite("Audio levels")
struct AudioLevelTests {
    /// One buffer of audio in the shape the capture delivers: 32-bit float PCM.
    ///
    /// Built here rather than decoded from a file, so the test states the format the meter is
    /// written against and needs nothing on the machine to run.
    private func buffer(
        _ samples: [Float],
        float: Bool = true,
        bitsPerChannel: UInt32 = 32
    ) throws -> CMSampleBuffer {
        var description = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsPacked | (float ? kAudioFormatFlagIsFloat : 0),
            mBytesPerPacket: float ? 4 : 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: float ? 4 : 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: bitsPerChannel,
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
        let bytesPerFrame = Int(description.mBytesPerFrame)
        let byteCount = samples.count * bytesPerFrame
        var block: CMBlockBuffer?
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
        let pointerStatus = CMBlockBufferGetDataPointer(
                blockBuffer,
                atOffset: 0,
                lengthAtOffsetOut: &lengthAtOffset,
                totalLengthOut: &totalLength,
                dataPointerOut: &dataPointer
            )
        #expect(pointerStatus == noErr, "CMBlockBufferGetDataPointer status \(pointerStatus) length \(totalLength)")
        if float {
            let destination = try #require(dataPointer)
            _ = samples.withUnsafeBytes { source in
                memcpy(destination, source.baseAddress, source.count)
            }
        }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 48_000),
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        )
        var sampleSizes = [bytesPerFrame]
        var sample: CMSampleBuffer?
        #expect(
            CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault,
                dataBuffer: blockBuffer,
                formatDescription: try #require(format),
                sampleCount: samples.count,
                sampleTimingEntryCount: 1,
                sampleTimingArray: &timing,
                sampleSizeEntryCount: 1,
                sampleSizeArray: &sampleSizes,
                sampleBufferOut: &sample
            ) == noErr
        )
        return try #require(sample)
    }

    // MARK: - The measure

    @Test("the room tone of a quiet room is not speech, and a voice is")
    func theMeasureSeparatesRoomToneFromSpeech() {
        // The band measured on the library: room tone at -53 to -71 dBFS, speech at -42 and above.
        #expect(!AudioLevels.isSpeech(peak: 0.0005))   // about -66 dBFS
        #expect(!AudioLevels.isSpeech(peak: 0.0022))   // about -53 dBFS
        #expect(AudioLevels.isSpeech(peak: 0.008))     // about -42 dBFS
        #expect(AudioLevels.isSpeech(peak: 0.5))       // about -6 dBFS
    }

    @Test("digital silence has no level at all, and is not speech")
    func digitalSilenceIsNotSpeech() {
        // Given / When / Then
        #expect(AudioLevels.decibels(peak: 0) == -.infinity)
        #expect(!AudioLevels.isSpeech(peak: 0))
        // A full-scale sample is the zero the scale is named for.
        #expect(abs(AudioLevels.decibels(peak: 1)) < 0.0001)
    }

    // MARK: - The meter

    @Test("a meter that has read nothing cannot say the room is quiet")
    func nothingMeasuredIsNotSilence() {
        // Given
        let meter = AudioLevelMeter()

        // When / Then: the rail reads nil and stays out of the way.
        #expect(meter.silentSeconds() == nil)
    }

    @Test("a format the meter cannot read is not silence either")
    func aFormatItCannotReadIsNotSilence() throws {
        // Given: 16-bit integer audio, which the capture never delivers and another source could.
        let sample = try buffer([0, 0, 0, 0], float: false, bitsPerChannel: 16)

        // When
        let meter = AudioLevelMeter()
        meter.observe(sample)

        // Then: nothing was measured, so nothing is claimed.
        #expect(meter.silentSeconds() == nil)
    }

    @Test("a tone counts as speech and holds the silence clock at zero")
    func aToneCountsAsSpeech() throws {
        // Given: a quarter of a second of a full-scale tone, which is what a voice looks like to a
        // peak measure.
        let samples = (0..<12_000).map { index in
            Float(sin(2 * Double.pi * 440 * Double(index) / 48_000)) * 0.5
        }
        let meter = AudioLevelMeter()
        let start = Date()

        // When
        meter.observe(try buffer(samples), at: start)

        // Then: the clock reads from the last speech, so it is at zero then and counts on from it.
        #expect(meter.silentSeconds(at: start) == 0)
        #expect((meter.silentSeconds(at: start.addingTimeInterval(30)) ?? 0) > 29.9)
        #expect(meter.loudest > -20)
    }

    @Test("silence counts as silence")
    func silenceCountsAsSilence() throws {
        // Given: a quarter of a second of digital silence.
        let meter = AudioLevelMeter()
        let start = Date()

        // When
        meter.observe(try buffer(Array(repeating: 0, count: 12_000)), at: start)

        // Then: the buffer was read and none of it was speech, so ten minutes later the rail has
        // the evidence it needs.
        #expect((meter.silentSeconds(at: start.addingTimeInterval(600)) ?? 0) > 599)
        #expect(meter.loudest == -.infinity)
    }

    @Test("room tone below the threshold counts as silence too")
    func roomToneCountsAsSilence() throws {
        // Given: the quietest recording in the library, whose microphone sits at about -66 dBFS.
        let meter = AudioLevelMeter()
        let start = Date()

        // When
        meter.observe(try buffer(Array(repeating: 0.0005, count: 12_000)), at: start)

        // Then
        #expect((meter.silentSeconds(at: start.addingTimeInterval(600)) ?? 0) > 599)
    }

    @Test("a reset starts the count over, which is what a pause is")
    func resetStartsTheCountOver() throws {
        // Given
        let meter = AudioLevelMeter()
        let start = Date()
        meter.observe(try buffer(Array(repeating: 0, count: 1_000)), at: start)
        #expect(meter.silentSeconds(at: start.addingTimeInterval(60)) != nil)

        // When: the next segment begins.
        meter.reset()

        // Then: nothing has been measured in this segment, so there is no silence to act on.
        #expect(meter.silentSeconds(at: start.addingTimeInterval(600)) == nil)
    }

    // MARK: - The live reading

    @Test("a meter that has read nothing has no live reading either")
    func noLiveReadingBeforeAnythingArrives() {
        #expect(AudioLevelMeter().currentDecibels() == nil)
    }

    @Test("the live reading is the newest buffer, and it goes stale on its own")
    func liveReadingIsTheNewestBuffer() throws {
        // Given: a meter that has just heard somebody.
        let meter = AudioLevelMeter()
        let start = Date()
        meter.observe(try buffer(Array(repeating: 0.05, count: 512)), at: start)
        let heard = try #require(meter.currentDecibels(now: start))
        #expect(abs(heard - AudioLevels.decibels(peak: 0.05)) < 0.0001)

        // When: the capture stops delivering, which is what a stopped microphone looks like from
        // here. The reading is no longer an answer about now, so it is not given as one.
        #expect(meter.currentDecibels(now: start.addingTimeInterval(2)) == nil)

        // And a reset, which is what the next segment does, leaves nothing behind either.
        meter.reset()
        #expect(meter.currentDecibels(now: start) == nil)
    }

    @Test("a reading taken from a peak the caller already knows feeds the same meter")
    func aKnownPeakFeedsTheMeter() {
        // The Settings check measures a playback buffer rather than a sample buffer, and the two
        // meet here: one place decides what counts as speech and what the live level is.
        let meter = AudioLevelMeter()
        let start = Date()
        meter.observe(peak: 0.25, at: start)

        #expect(meter.currentDecibels(now: start) != nil)
        #expect(AudioLevels.isSpeech(peak: 0.25))
        #expect(meter.loudest > -20)
    }

    // MARK: - The bar

    @Test("a level sits on the bar between the floor and the ceiling")
    func theBarHasTwoEnds() {
        #expect(AudioLevels.meterFraction(decibels: AudioLevels.meterFloorDecibels) == 0)
        #expect(AudioLevels.meterFraction(decibels: AudioLevels.meterCeilingDecibels) == 1)
        // A quiet room and a slammed door are drawn at the ends rather than past them.
        #expect(AudioLevels.meterFraction(decibels: -80) == 0)
        #expect(AudioLevels.meterFraction(decibels: 3) == 1)
        // Digital silence has no level at all, and belongs at the floor.
        #expect(AudioLevels.meterFraction(decibels: -.infinity) == 0)
    }

    @Test("the speech threshold is marked along the bar, not at one of its ends")
    func theThresholdIsSomewhereReadable() {
        let position = AudioLevels.meterFraction(
            decibels: AudioLevels.speechThresholdDecibels
        )

        // The mark is what says whether the bar is showing a voice or the room, so it has to sit
        // inside the bar with room on both sides of it.
        #expect(position > 0.1)
        #expect(position < 0.4)
        // And a level above it is further along than the mark.
        #expect(AudioLevels.meterFraction(decibels: -20) > position)
    }
}
