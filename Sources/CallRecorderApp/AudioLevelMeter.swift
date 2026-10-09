import CallRecorderCore
import CoreMedia
import Foundation

/// How loud the audio arriving from the capture is, and when it last held anything but room tone.
///
/// Two audio threads write to this a hundred times a second and the main actor reads it when it
/// asks whether a recording has gone quiet, so it is a lock and three values rather than a queue.
///
/// The meter reports the silence it measured and nothing else. It is deliberately not able to say
/// "silent" before it has measured anything: a buffer whose format it does not understand, and a
/// capture that has not delivered a buffer yet, both leave it unable to answer, and the rail that
/// reads it then does nothing. Stopping a real call because the meter was broken is the one
/// failure this type must not have.
final class AudioLevelMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var firstMeasuredAt: Date?
    private var lastSpeechAt: Date?
    private var measuredBuffers = 0
    private var loudestDecibels = -Double.infinity
    private var latestDecibels: Double?
    private var latestBufferAt: Date?

    /// Starts a segment's count over, so silence is measured from the moment audio arrives again
    /// rather than across a pause the person asked for.
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        lastSpeechAt = nil
        firstMeasuredAt = nil
        measuredBuffers = 0
        loudestDecibels = -.infinity
        latestDecibels = nil
        latestBufferAt = nil
    }

    /// Reads one buffer of captured audio.
    func observe(_ sampleBuffer: CMSampleBuffer, at date: Date = Date()) {
        guard let peak = Self.peak(of: sampleBuffer) else { return }
        observe(peak: peak, at: date)
    }

    /// Reads one buffer of audio whose loudest sample is already known.
    ///
    /// A capture that arrives as a sample buffer and one that arrives as a playback buffer compute
    /// their peak in their own way, and both end up here: what counts as speech, what counts as
    /// room tone, and how long the room has been quiet are answered in one place.
    func observe(peak: Float, at date: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        if firstMeasuredAt == nil { firstMeasuredAt = date }
        measuredBuffers += 1
        let decibels = AudioLevels.decibels(peak: peak)
        if decibels > loudestDecibels { loudestDecibels = decibels }
        if AudioLevels.isSpeech(peak: peak) { lastSpeechAt = date }
        latestDecibels = decibels
        latestBufferAt = date
    }

    /// The newest buffer's loudness, or nil when nothing arrived recently enough to be this moment.
    ///
    /// The Settings row draws this as a live bar, and a reading is only an answer while the audio
    /// is still arriving: a capture that stopped leaves its last buffer behind, and a bar that went
    /// on showing it would say the microphone is hearing something when nothing is listening.
    func currentDecibels(now: Date = Date(), freshWithin: TimeInterval = 0.5) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        guard let latestBufferAt, let latestDecibels,
              now.timeIntervalSince(latestBufferAt) <= freshWithin
        else { return nil }
        return latestDecibels
    }

    /// How long the capture has held nothing but room tone, or nil when that cannot be said.
    ///
    /// A segment that has heard nothing at all is silent from the moment its audio started arriving,
    /// which is the state a call enters when the meeting ends and its app keeps the microphone: the
    /// clock runs from the first buffer, not from a moment of speech that never came.
    ///
    /// Nil means no buffer has been read yet, which is the state at the start of a segment and the
    /// state of a capture this meter cannot measure. Both are reported the same way on purpose:
    /// neither is evidence that the room was quiet.
    func silentSeconds(at now: Date = Date()) -> TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        guard measuredBuffers > 0, let start = lastSpeechAt ?? firstMeasuredAt else { return nil }
        return max(0, now.timeIntervalSince(start))
    }

    /// The loudest buffer read since the last reset, for a diagnostic.
    var loudest: Double {
        lock.lock()
        defer { lock.unlock() }
        return loudestDecibels
    }

    /// The loudest sample in one buffer, or nil when the buffer is not 32-bit float PCM.
    ///
    /// This runs on the audio thread, so it looks at every fourth sample: a peak is not improved by
    /// reading all of them, and four samples at 48 kHz is 0.08 ms of audio.
    private static func peak(of sampleBuffer: CMSampleBuffer) -> Float? {
        guard
            let description = CMSampleBufferGetFormatDescription(sampleBuffer),
            let stream = CMAudioFormatDescriptionGetStreamBasicDescription(description),
            stream.pointee.mFormatID == kAudioFormatLinearPCM,
            stream.pointee.mBitsPerChannel == 32,
            stream.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0
        else { return nil }

        // The list is asked for its size first, because the buffers inside it are one per channel
        // and a struct with room for one is not room for two.
        var needed = 0
        guard
            CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                sampleBuffer,
                bufferListSizeNeededOut: &needed,
                bufferListOut: nil,
                bufferListSize: 0,
                blockBufferAllocator: nil,
                blockBufferMemoryAllocator: nil,
                flags: 0,
                blockBufferOut: nil
            ) == noErr,
            needed > 0
        else { return nil }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: needed,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        var blockBuffer: CMBlockBuffer?
        guard
            CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                sampleBuffer,
                bufferListSizeNeededOut: nil,
                bufferListOut: raw.assumingMemoryBound(to: AudioBufferList.self),
                bufferListSize: needed,
                blockBufferAllocator: kCFAllocatorDefault,
                blockBufferMemoryAllocator: kCFAllocatorDefault,
                flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
                blockBufferOut: &blockBuffer
            ) == noErr
        else { return nil }

        var peak: Float = 0
        for buffer in UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self)
        ) {
            guard let data = buffer.mData else { continue }
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            guard count > 0 else { continue }
            let samples = data.assumingMemoryBound(to: Float.self)
            var index = 0
            while index < count {
                let value = abs(samples[index])
                if value > peak { peak = value }
                index += 4
            }
        }
        return peak
    }
}
