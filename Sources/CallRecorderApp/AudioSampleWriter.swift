import AVFoundation
import CoreMedia
import Foundation

enum AudioSampleWriterError: LocalizedError {
    case invalidAudioFormat
    case outputExists(URL)
    case writerFailed(String)
    case backPressure

    var errorDescription: String? {
        switch self {
        case .invalidAudioFormat:
            "The captured audio format is invalid."
        case let .outputExists(url):
            "The audio output already exists: \(url.lastPathComponent)"
        case let .writerFailed(message):
            "The audio writer failed: \(message)"
        case .backPressure:
            "The audio writer could not accept captured samples."
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

    init(destination: URL) {
        self.destination = destination
        let partialName = ".\(destination.deletingPathExtension().lastPathComponent)"
            + "-\(UUID().uuidString).partial.\(destination.pathExtension)"
        partial = destination.deletingLastPathComponent().appending(path: partialName)
    }

    func append(_ sampleBuffer: CMSampleBuffer) throws {
        lock.lock()
        defer { lock.unlock() }
        if let appendError { throw appendError }
        do {
            let input = try prepareWriter(for: sampleBuffer)
            guard input.isReadyForMoreMediaData else { throw AudioSampleWriterError.backPressure }
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
        return CapturedAudioSource(
            fileURL: destination,
            firstPresentationSeconds: CMTimeGetSeconds(context.firstPresentationTime),
            durationSeconds: max(
                0,
                CMTimeGetSeconds(context.lastPresentationEnd - context.firstPresentationTime)
            )
        )
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
