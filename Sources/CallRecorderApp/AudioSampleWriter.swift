import AVFoundation
import CoreMedia
import Foundation
import OSLog

enum AudioSampleWriterError: LocalizedError {
    case invalidAudioFormat
    case outputExists(URL)
    case writerFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidAudioFormat:
            "The captured audio format is invalid."
        case let .outputExists(url):
            "The audio output already exists: \(url.lastPathComponent)"
        case let .writerFailed(message):
            "The audio writer failed: \(message)"
        }
    }
}

final class AudioSampleWriter: @unchecked Sendable {
    private struct FinishContext {
        let writer: AVAssetWriter
        let firstPresentationTime: CMTime
        let lastPresentationEnd: CMTime
    }

    private let destination: URL
    private let partial: URL
    private let lock = NSLock()
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var firstPresentationTime: CMTime?
    private var lastPresentationEnd: CMTime?
    private var appendError: (any Error)?
    private var droppedSamples = 0
    private let logger = Logger(subsystem: "local.callrecorder.app", category: "capture")

    /// How long a sample may wait for the encoder before it is dropped.
    ///
    /// A capture stream delivers samples in real time, so the wait has to be bounded: the stream
    /// stays in step by losing a sample, never by holding the queue. The budget is well under the
    /// twenty milliseconds one buffer covers, so the next sample still finds the encoder free.
    private static let readinessPatienceMilliseconds = 16

    /// How long one wait step sleeps for.
    private static let readinessStepMilliseconds: UInt32 = 2

    init(destination: URL) {
        self.destination = destination
        let partialName = ".\(destination.deletingPathExtension().lastPathComponent)"
            + "-\(UUID().uuidString).partial.\(destination.pathExtension)"
        partial = destination.deletingLastPathComponent().appending(path: partialName)
    }

    /// Appends one captured buffer. Returns false when bounded back-pressure handling deliberately
    /// drops the sample; callers that prove source readiness must not count that as writable audio.
    @discardableResult
    func append(_ sampleBuffer: CMSampleBuffer) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let appendError { throw appendError }
        do {
            let input = try prepareWriter(for: sampleBuffer)
            guard waitForReadiness(input) else {
                // The encoder is behind. This used to throw, and the router reads any throw as a
                // failed track and cancels that whole source: a disk still busy with the last
                // call's audio cost the next call one entire side of it. A dropped sample is a
                // click; losing the track is a call without the other person in it.
                if let appendError { throw appendError }
                droppedSamples += 1
                return false
            }
            guard input.append(sampleBuffer) else {
                throw AudioSampleWriterError.writerFailed(
                    writer?.error?.localizedDescription ?? "sample append failed"
                )
            }
            let presentation = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let duration = CMSampleBufferGetDuration(sampleBuffer)
            let end = duration.isValid && duration.isNumeric
                ? presentation + duration
                : presentation
            if let previousEnd = lastPresentationEnd {
                if end > previousEnd { lastPresentationEnd = end }
            } else {
                lastPresentationEnd = end
            }
            return true
        } catch {
            appendError = error
            throw error
        }
    }

    func finish() async throws -> CapturedAudioSource? {
        guard let context = try prepareFinish() else {
            if FileManager.default.fileExists(atPath: partial.path) {
                try FileManager.default.removeItem(at: partial)
            }
            return nil
        }

        await context.writer.finishWriting()
        guard context.writer.status == .completed else {
            throw AudioSampleWriterError.writerFailed(
                context.writer.error?.localizedDescription ?? "finish failed"
            )
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw AudioSampleWriterError.outputExists(destination)
        }
        try FileManager.default.moveItem(at: partial, to: destination)
        if droppedSamples > 0 {
            logger.notice(
                "capture dropped \(self.droppedSamples, privacy: .public) samples under back pressure"
            )
        }
        return CapturedAudioSource(
            fileURL: destination,
            firstPresentationSeconds: CMTimeGetSeconds(context.firstPresentationTime),
            durationSeconds: max(
                0,
                CMTimeGetSeconds(context.lastPresentationEnd - context.firstPresentationTime)
            ),
            droppedSamples: droppedSamples > 0 ? droppedSamples : nil
        )
    }

    /// Waits a bounded moment for the encoder to accept another sample.
    ///
    /// The lock is released while waiting, so a stop that arrives during a stall is not held behind
    /// the wait. Returns false when the patience ran out, which is the caller's cue to drop.
    private func waitForReadiness(_ input: AVAssetWriterInput) -> Bool {
        var waited = 0
        while !input.isReadyForMoreMediaData {
            // A failure recorded while waiting is the real answer, and the caller reports it.
            if appendError != nil { return true }
            guard waited < Self.readinessPatienceMilliseconds else { return false }
            lock.unlock()
            usleep(Self.readinessStepMilliseconds * 1_000)
            lock.lock()
            waited += Int(Self.readinessStepMilliseconds)
        }
        return true
    }

    func cancel() {
        lock.lock()
        writer?.cancelWriting()
        lock.unlock()
        if FileManager.default.fileExists(atPath: partial.path) {
            try? FileManager.default.removeItem(at: partial)
        }
    }

    private func prepareFinish() throws -> FinishContext? {
        lock.lock()
        defer { lock.unlock() }
        if let appendError { throw appendError }
        guard let writer, let input, let firstPresentationTime else { return nil }
        input.markAsFinished()
        return FinishContext(
            writer: writer,
            firstPresentationTime: firstPresentationTime,
            lastPresentationEnd: lastPresentationEnd ?? firstPresentationTime
        )
    }

    private func prepareWriter(for sampleBuffer: CMSampleBuffer) throws -> AVAssetWriterInput {
        if let input { return input }
        guard
            let format = CMSampleBufferGetFormatDescription(sampleBuffer),
            CMFormatDescriptionGetMediaType(format) == kCMMediaType_Audio,
            let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)
        else { throw AudioSampleWriterError.invalidAudioFormat }
        let stream = description.pointee
        guard stream.mSampleRate > 0, stream.mChannelsPerFrame > 0 else {
            throw AudioSampleWriterError.invalidAudioFormat
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw AudioSampleWriterError.outputExists(destination)
        }
        let writer = try AVAssetWriter(outputURL: partial, fileType: .m4a)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: stream.mSampleRate,
            AVNumberOfChannelsKey: Int(stream.mChannelsPerFrame),
            AVEncoderBitRateKey: 128_000,
        ]
        let input = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: settings,
            sourceFormatHint: format
        )
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw AudioSampleWriterError.invalidAudioFormat }
        writer.add(input)
        guard writer.startWriting() else {
            throw AudioSampleWriterError.writerFailed(
                writer.error?.localizedDescription ?? "start failed"
            )
        }
        let presentation = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        writer.startSession(atSourceTime: presentation)
        self.writer = writer
        self.input = input
        firstPresentationTime = presentation
        lastPresentationEnd = presentation
        return input
    }
}
