import AVFoundation
import CallRecorderCore
import CoreMedia
import Foundation
import OSLog

/// Reads the audio a recording is already capturing, and cuts it into chunks a transcriber can read.
///
/// The recording's own writers are untouched: this reads the same buffers the router hands them and
/// does nothing else with them. Two rules come with being on that path.
///
/// The audio thread is never blocked. A buffer is copied and put on a bounded queue under a lock,
/// and every other thing — format conversion, accumulation, and the writing of chunk files — happens
/// on this tap's own serial queue. Amanu's recorder learned the same lesson from the other side: a
/// live feature that falls behind must lose live audio, never recording audio.
///
/// The queue is bounded and drops its oldest entry rather than growing. A machine that cannot keep
/// up with two sides of a call is a machine whose memory must not be spent on a preview of it.
final class LiveAudioTap: @unchecked Sendable {
    /// One closed piece of one side, on disk, waiting to be read.
    struct Chunk: Equatable, Sendable {
        let source: LiveAudioSource
        /// Which chunk of its own side this is.
        let index: Int
        /// Where it starts, in seconds from the start of the recording.
        let startSeconds: Double
        let durationSeconds: Double
        let fileURL: URL
    }

    /// The format whisper.cpp is handed: the rate and shape every speech model here expects.
    private static let targetFormat: AVAudioFormat = {
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false
            )
        else {
            preconditionFailure("16 kHz mono float PCM is a format Core Audio always has")
        }
        return format
    }()

    /// How much audio may wait to be converted, in buffers.
    ///
    /// A capture delivers a buffer of about ten milliseconds, so this is roughly two seconds of
    /// slack. Reaching it at all means the machine could not convert audio faster than it arrives.
    private static let maximumPendingBuffers = 200

    private let directory: URL
    private let offsetSeconds: Double
    private let chunkSeconds: Double
    private let queue = DispatchQueue(label: "local.callrecorder.live.tap")
    private let sink: @Sendable (Chunk) -> Void
    private let logger = Logger(subsystem: "local.callrecorder.app", category: "live")

    private let lock = NSLock()
    private var pending: [(source: LiveAudioSource, buffer: AVAudioPCMBuffer)] = []
    private var states: [LiveAudioSource: SourceState] = [:]
    private var draining = false
    private var closed = false
    private var droppedBuffers = 0
    private var saidUnreadableFormat = false

    /// What one side has converted so far.
    private final class SourceState {
        var converter: AVAudioConverter?
        var inputFormat: AVAudioFormat?
        var accumulator: LiveAudioAccumulator

        init(chunkSeconds: Double) {
            accumulator = LiveAudioAccumulator(chunkSeconds: chunkSeconds)
        }
    }

    /// - Parameters:
    ///   - directory: where chunk files are written. Removed by the caller when the call ends.
    ///   - offsetSeconds: how much of the recording has already happened, so a chunk of the second
    ///     segment is placed after the first rather than at zero.
    ///   - sink: called on the tap's own queue with each closed chunk that holds speech.
    init(
        directory: URL,
        offsetSeconds: Double,
        chunkSeconds: Double = 15,
        sink: @escaping @Sendable (Chunk) -> Void
    ) {
        self.directory = directory
        self.offsetSeconds = max(0, offsetSeconds)
        self.chunkSeconds = chunkSeconds
        self.sink = sink
    }

    /// Adds one captured buffer. Called on the capture queue for its side.
    func append(_ sampleBuffer: CMSampleBuffer, source: LiveAudioSource) {
        guard let copy = Self.copyOf(sampleBuffer) else {
            noteUnreadableFormat(of: sampleBuffer, source: source)
            return
        }
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        pending.append((source, copy))
        if pending.count > Self.maximumPendingBuffers {
            // The oldest audio goes first: a preview is worth most at the end of the call, and the
            // recording itself is unaffected either way.
            pending.removeFirst()
            droppedBuffers += 1
        }
        let shouldDrain = !draining
        if shouldDrain { draining = true }
        lock.unlock()
        if shouldDrain { queue.async { self.drain() } }
    }

    /// Closes the tap and waits for the tail of both sides to be written.
    ///
    /// It waits because the caller is about to stop the transcriber, and a chunk written after that
    /// is a sentence the call's closing words alone would be missing. What it waits for is one small
    /// conversion and one small file, on a queue that is no longer being fed.
    func finish() {
        lock.lock()
        closed = true
        lock.unlock()
        queue.sync {}
        for (source, state) in statesForFinish() {
            guard let tail = state.accumulator.finish() else { continue }
            write(tail, for: source)
        }
        if droppedBuffers > 0 {
            logger.notice(
                "live audio dropped \(self.droppedBuffers, privacy: .public) buffers it could not convert in time"
            )
        }
    }

    // MARK: - The worker

    private func drain() {
        while true {
            lock.lock()
            guard !pending.isEmpty else {
                draining = false
                lock.unlock()
                return
            }
            let item = pending.removeFirst()
            lock.unlock()
            convertAndCut(item.buffer, from: item.source)
        }
    }

    private func convertAndCut(_ buffer: AVAudioPCMBuffer, from source: LiveAudioSource) {
        let state = state(for: source)
        guard let samples = convert(buffer, using: state) else { return }
        for chunk in state.accumulator.append(samples) {
            write(chunk, for: source)
        }
    }

    /// One buffer's samples, resampled to what a speech model reads.
    private func convert(_ buffer: AVAudioPCMBuffer, using state: SourceState) -> [Float]? {
        if state.converter == nil || state.inputFormat != buffer.format {
            state.converter = AVAudioConverter(from: buffer.format, to: Self.targetFormat)
            state.inputFormat = buffer.format
        }
        guard let converter = state.converter else { return nil }
        let ratio = Self.targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard
            let output = AVAudioPCMBuffer(pcmFormat: Self.targetFormat, frameCapacity: capacity)
        else { return nil }
        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            guard !supplied else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, output.frameLength > 0, let channel = output.floatChannelData?[0]
        else { return nil }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }

    private func write(_ chunk: LiveAudioChunk, for source: LiveAudioSource) {
        // Silence is not sent to a model. It costs the same as speech and comes back as words
        // nobody said, which is worse than a gap in a preview.
        guard chunk.holdsSpeech else { return }
        let name = "\(source.rawValue)-\(String(format: "%04d", chunk.index)).wav"
        let url = directory.appending(path: name)
        do {
            try LiveAudioChunkWriter.write(chunk, to: url)
        } catch {
            logger.notice("live chunk not written: \(error.localizedDescription, privacy: .public)")
            return
        }
        sink(
            Chunk(
                source: source,
                index: chunk.index,
                startSeconds: offsetSeconds + chunk.startSeconds,
                durationSeconds: chunk.durationSeconds,
                fileURL: url
            )
        )
    }

    private func state(for source: LiveAudioSource) -> SourceState {
        lock.lock()
        defer { lock.unlock() }
        if let state = states[source] { return state }
        let state = SourceState(chunkSeconds: chunkSeconds)
        states[source] = state
        return state
    }

    /// The two sides as they stand, for the closing flush.
    private func statesForFinish() -> [(LiveAudioSource, SourceState)] {
        lock.lock()
        defer { lock.unlock() }
        return states.map { ($0.key, $0.value) }
    }

    /// An owned copy of one captured buffer, in the format it arrived in.
    ///
    /// The buffer a capture hands over is borrowed and does not outlive the callback, so the copy
    /// is what makes the rest of the work safe to do somewhere else.
    private static func copyOf(_ sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard
            let description = CMSampleBufferGetFormatDescription(sampleBuffer),
            let stream = CMAudioFormatDescriptionGetStreamBasicDescription(description),
            stream.pointee.mFormatID == kAudioFormatLinearPCM
        else { return nil }
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0 else { return nil }
        guard let format = Self.format(from: stream.pointee) else {
            return Self.downmixed(sampleBuffer, stream: stream.pointee, frames: frames)
        }
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
        else { return nil }
        copy.frameLength = AVAudioFrameCount(frames)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frames),
            into: copy.mutableAudioBufferList
        )
        guard status == noErr else { return nil }
        return copy
    }

    /// A buffer in a layout `AVAudioFormat` has no form for, read channel by channel into one.
    ///
    /// `AVAudioFormat` describes one or two channels interleaved, and any number of channels laid
    /// out apart. The microphone of the 2026-09-23 browser call was neither: three channels of
    /// packed float at 48 kHz, interleaved, which is what the tap skipped until this path existed.
    /// A preview is read as one channel anyway — whisper takes one — and every voice has to be in
    /// it rather than a positional mix, so the channels are averaged here. Anything that is not
    /// packed float in more than two interleaved channels is still left alone.
    private static func downmixed(
        _ sampleBuffer: CMSampleBuffer,
        stream: AudioStreamBasicDescription,
        frames: Int
    ) -> AVAudioPCMBuffer? {
        let channels = Int(stream.mChannelsPerFrame)
        guard
            stream.mFormatFlags & kAudioFormatFlagIsFloat != 0,
            stream.mFormatFlags & kAudioFormatFlagIsPacked != 0,
            stream.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0,
            stream.mBitsPerChannel == 32,
            channels > 2,
            let mono = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: stream.mSampleRate,
                channels: 1,
                interleaved: true
            )
        else { return nil }
        var interleaved = [Float](repeating: 0, count: frames * channels)
        let status = interleaved.withUnsafeMutableBytes { raw -> OSStatus in
            var list = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: UInt32(channels),
                    mDataByteSize: UInt32(raw.count),
                    mData: raw.baseAddress
                )
            )
            return CMSampleBufferCopyPCMDataIntoAudioBufferList(
                sampleBuffer,
                at: 0,
                frameCount: Int32(frames),
                into: &list
            )
        }
        guard status == noErr, let output = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: AVAudioFrameCount(frames)),
            let channel = output.floatChannelData?[0]
        else { return nil }
        let divisor = Float(channels)
        for frame in 0..<frames {
            var sum: Float = 0
            let base = frame * channels
            for channel in 0..<channels { sum += interleaved[base + channel] }
            channel[frame] = sum / divisor
        }
        output.frameLength = AVAudioFrameCount(frames)
        return output
    }

    /// The format of one captured buffer, read from the fields of its own description.
    ///
    /// Two things are wrong with `AVAudioFormat(cmAudioFormatDescription:)`, and both were measured
    /// on 2026-09-23 with the microphone capture of a browser call. It is imported as non-optional
    /// while it answers nil for a description it cannot read; and a LinearPCM description that
    /// carries no channel builds an `AVAudioFormat` of zero channels rather than nothing at all.
    /// Either one reaches `AVAudioPCMBuffer(pcmFormat:)`, which dies inside itself on the capture
    /// callback's own queue — the two crash reports are that, EXC_BAD_ACCESS at address 0 in
    /// AVFAudio, four and five seconds into recordings that had started by themselves. The numbers
    /// are read here instead, so a description the app cannot describe costs a moment of a preview
    /// rather than the app. Only the layouts a capture delivers are built: linear PCM, float or
    /// signed integer, packed, with at least one channel.
    static func format(from stream: AudioStreamBasicDescription) -> AVAudioFormat? {
        guard stream.mSampleRate > 0, stream.mChannelsPerFrame > 0 else { return nil }
        let isFloat = stream.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let isSignedInteger = stream.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0
        let isPacked = stream.mFormatFlags & kAudioFormatFlagIsPacked != 0
        let common: AVAudioCommonFormat
        switch (isFloat, isSignedInteger, isPacked, stream.mBitsPerChannel) {
        case (true, _, true, 32): common = .pcmFormatFloat32
        case (true, _, true, 64): common = .pcmFormatFloat64
        case (false, true, true, 16): common = .pcmFormatInt16
        case (false, true, true, 32): common = .pcmFormatInt32
        default: return nil
        }
        return AVAudioFormat(
            commonFormat: common,
            sampleRate: stream.mSampleRate,
            channels: AVAudioChannelCount(stream.mChannelsPerFrame),
            interleaved: stream.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        )
    }

    /// Says once what a buffer the tap could not read was made of.
    ///
    /// The fault repeats with every buffer, and the first one already carries the answer: the
    /// numbers say whether a device changed under the capture or whether the shape was one this
    /// app has never seen. One line per call, because sixty a second would bury the log.
    private func noteUnreadableFormat(of sampleBuffer: CMSampleBuffer, source: LiveAudioSource) {
        lock.lock()
        let alreadySaid = saidUnreadableFormat
        saidUnreadableFormat = true
        lock.unlock()
        guard !alreadySaid else { return }
        let stream = CMSampleBufferGetFormatDescription(sampleBuffer)
            .flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0) }?.pointee
        logger.notice(
            "live audio skipped a \(source.rawValue, privacy: .public) buffer the tap could not read: rate \(stream?.mSampleRate ?? 0, privacy: .public), channels \(stream?.mChannelsPerFrame ?? 0, privacy: .public), bits \(stream?.mBitsPerChannel ?? 0, privacy: .public), flags \(stream?.mFormatFlags ?? 0, privacy: .public)"
        )
    }
}
