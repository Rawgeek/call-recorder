import AVFoundation
import CallRecorderCore
import CoreMedia
import Foundation

enum NativeMediaProcessorError: LocalizedError {
    case invalidAudio(URL)
    case cannotCreateTrack
    case readerFailed(String)
    case writerFailed(String)

    var errorDescription: String? {
        switch self {
        case let .invalidAudio(url):
            "The recording contains no readable audio: \(url.lastPathComponent)"
        case .cannotCreateTrack:
            "A native audio composition track could not be created."
        case let .readerFailed(message):
            "The native audio reader failed: \(message)"
        case let .writerFailed(message):
            "The native audio writer failed: \(message)"
        }
    }
}

struct PreparedAudioChunk: Equatable, Sendable {
    let fileURL: URL
    let startMilliseconds: Int
}

/// AVFoundation-only media work used by the App Store distribution.
///
/// Source recordings are never removed. Every output is written beside its destination under a
/// UUID partial name, verified as a readable one-track asset, and moved into place only after that
/// verification succeeds.
struct NativeMediaProcessor: MediaFinalizing {
    private struct Placement {
        let fileURL: URL
        let start: CMTime
    }

    let externalTools: ExternalMediaToolURLs? = nil

    func finalize(segments: [CaptureSegment], destination: URL) async throws -> URL {
        try await finalizeSources(segments: segments, destination: destination).compatibilityMix
    }

    func finalizeSources(
        segments: [CaptureSegment],
        destination: URL
    ) async throws -> FinalizedAudioSources {
        guard !segments.isEmpty else { throw MediaFinalizerError.noSegments }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let ordered = segments.sorted { $0.index < $1.index }
        let timedSources = ordered.flatMap { [$0.system, $0.microphone].compactMap { $0 } }
            .filter { $0.durationSeconds > 0 && $0.firstPresentationSeconds.isFinite }
        let origin = timedSources.map(\.firstPresentationSeconds).min()
        let system = try await finalizeTrack(
            ordered.compactMap(\.system),
            named: "system.m4a",
            destination: destination,
            origin: origin
        )
        let microphone = try await finalizeTrack(
            ordered.compactMap(\.microphone),
            named: "microphone.m4a",
            destination: destination,
            origin: origin
        )
        guard system != nil || microphone != nil else { throw MediaFinalizerError.noSegments }
        let mix = try await finalizeMix(
            [system, microphone].compactMap { $0 },
            destination: destination
        )
        return FinalizedAudioSources(system: system, microphone: microphone, compatibilityMix: mix)
    }

    func prepareWhisperChunks(
        audio: URL,
        directory: URL,
        maximumDurationSeconds: Double = 300,
        cancellation: ProcessCancellation? = nil
    ) async throws -> [PreparedAudioChunk] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let inputFile = try AVAudioFile(forReading: audio)
        let inputFormat = inputFile.processingFormat
        let duration = Double(inputFile.length) / inputFormat.sampleRate
        guard duration.isFinite, duration > 0 else {
            throw NativeMediaProcessorError.invalidAudio(audio)
        }
        let ranges = Self.chunkRanges(
            durationSeconds: duration,
            maximumDurationSeconds: maximumDurationSeconds
        )
        var chunks: [PreparedAudioChunk] = []
        do {
            for (index, range) in ranges.enumerated() {
                try cancellation?.checkCancelled()
                try Task.checkCancellation()
                let finalURL = directory.appending(
                    path: String(format: "chunk-%03d.wav", index)
                )
                let partialURL = directory.appending(
                    path: ".chunk-\(index)-\(UUID().uuidString).partial.wav"
                )
                defer { try? FileManager.default.removeItem(at: partialURL) }
                try writeWhisperWAV(
                    source: audio,
                    startSeconds: range.start,
                    durationSeconds: range.duration,
                    destination: partialURL,
                    cancellation: cancellation
                )
                try await verify(
                    partialURL,
                    expectedTracks: 1,
                    expectedFormat: (sampleRate: 16_000, channels: 1, bits: 16)
                )
                try FileManager.default.moveItem(at: partialURL, to: finalURL)
                chunks.append(
                    PreparedAudioChunk(
                        fileURL: finalURL,
                        startMilliseconds: Int((range.start * 1_000).rounded())
                    )
                )
            }
            return chunks
        } catch {
            for chunk in chunks { try? FileManager.default.removeItem(at: chunk.fileURL) }
            throw error
        }
    }

    static func chunkRanges(
        durationSeconds: Double,
        maximumDurationSeconds: Double = 300
    ) -> [(start: Double, duration: Double)] {
        guard
            durationSeconds.isFinite,
            durationSeconds > 0,
            maximumDurationSeconds.isFinite,
            maximumDurationSeconds > 0
        else { return [] }
        var ranges: [(start: Double, duration: Double)] = []
        var start = 0.0
        while start < durationSeconds {
            let duration = min(maximumDurationSeconds, durationSeconds - start)
            ranges.append((start: start, duration: duration))
            start += duration
        }
        return ranges
    }

    private func finalizeTrack(
        _ sources: [CapturedAudioSource],
        named fileName: String,
        destination: URL,
        origin: Double?
    ) async throws -> URL? {
        guard !sources.isEmpty else { return nil }
        let preferredURL = destination.appending(path: fileName)
        let fallbackURL = preferredURL.deletingPathExtension().appendingPathExtension("wav")
        if FileManager.default.fileExists(atPath: preferredURL.path) {
            try await verify(
                preferredURL,
                expectedTracks: 1,
                expectedFormatID: kAudioFormatMPEG4AAC
            )
            return preferredURL
        }
        if FileManager.default.fileExists(atPath: fallbackURL.path) {
            try await verify(
                fallbackURL,
                expectedTracks: 1,
                expectedFormat: (sampleRate: 48_000, channels: 2, bits: 16)
            )
            return fallbackURL
        }
        let resolvedOrigin = origin ?? sources.map(\.firstPresentationSeconds).min() ?? 0
        let placements = sources.map {
            Placement(
                fileURL: $0.fileURL,
                start: CMTime(
                    seconds: max(0, $0.firstPresentationSeconds - resolvedOrigin),
                    preferredTimescale: 600
                )
            )
        }
        return try await renderAudio(placements, preferredURL: preferredURL)
    }

    private func finalizeMix(_ sources: [URL], destination: URL) async throws -> URL {
        guard !sources.isEmpty else { throw MediaFinalizerError.noSegments }
        let preferredURL = destination.appending(path: "call.m4a")
        let fallbackURL = destination.appending(path: "call.wav")
        if FileManager.default.fileExists(atPath: preferredURL.path) {
            try await verify(
                preferredURL,
                expectedTracks: 1,
                expectedFormatID: kAudioFormatMPEG4AAC
            )
            return preferredURL
        }
        if FileManager.default.fileExists(atPath: fallbackURL.path) {
            try await verify(
                fallbackURL,
                expectedTracks: 1,
                expectedFormat: (sampleRate: 48_000, channels: 2, bits: 16)
            )
            return fallbackURL
        }
        return try await renderAudio(
            sources.map { Placement(fileURL: $0, start: .zero) },
            preferredURL: preferredURL
        )
    }

    private func renderAudio(_ placements: [Placement], preferredURL: URL) async throws -> URL {
        let fallbackURL = preferredURL.deletingPathExtension().appendingPathExtension("wav")
        let partialURL = preferredURL.deletingLastPathComponent().appending(
            path: ".\(preferredURL.deletingPathExtension().lastPathComponent)-\(UUID().uuidString).partial.m4a"
        )
        let mixURL = preferredURL.deletingLastPathComponent().appending(
            path: ".\(preferredURL.deletingPathExtension().lastPathComponent)-\(UUID().uuidString).mix.wav"
        )
        defer {
            try? FileManager.default.removeItem(at: partialURL)
            try? FileManager.default.removeItem(at: mixURL)
        }
        let renderFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        )!
        var converted: [(file: AVAudioFile, startFrame: AVAudioFramePosition)] = []
        var convertedURLs: [URL] = []
        defer { convertedURLs.forEach { try? FileManager.default.removeItem(at: $0) } }
        var totalFrames: AVAudioFramePosition = 0
        for (index, placement) in placements.enumerated() {
            let startFrame = AVAudioFramePosition(
                (CMTimeGetSeconds(placement.start) * renderFormat.sampleRate).rounded()
            )
            let convertedURL = preferredURL.deletingLastPathComponent().appending(
                path: ".\(preferredURL.deletingPathExtension().lastPathComponent)-\(UUID().uuidString)-\(index).caf"
            )
            convertedURLs.append(convertedURL)
            try convert(placement.fileURL, to: convertedURL, format: renderFormat)
            let file = try AVAudioFile(forReading: convertedURL)
            guard file.length > 0 else {
                throw NativeMediaProcessorError.invalidAudio(placement.fileURL)
            }
            totalFrames = max(totalFrames, startFrame + file.length)
            converted.append((file: file, startFrame: startFrame))
        }
        guard totalFrames > 0 else { throw MediaFinalizerError.noSegments }
        let mixStorageFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: renderFormat.sampleRate,
            channels: renderFormat.channelCount,
            interleaved: true
        )!
        var mixFile: AVAudioFile? = try AVAudioFile(
            forWriting: mixURL,
            settings: mixStorageFormat.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        var renderedFrames: AVAudioFramePosition = 0
        while renderedFrames < totalFrames {
            try Task.checkCancellation()
            let frameCount = AVAudioFrameCount(min(4_096, totalFrames - renderedFrames))
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: renderFormat,
                frameCapacity: frameCount
            ) else { throw NativeMediaProcessorError.writerFailed("mix buffer allocation failed") }
            buffer.frameLength = frameCount
            guard let destinationChannels = buffer.floatChannelData else {
                throw NativeMediaProcessorError.writerFailed("mix buffer has no channel data")
            }
            for channel in 0..<Int(renderFormat.channelCount) {
                for frame in 0..<Int(frameCount) {
                    destinationChannels[channel][frame] = 0
                }
            }
            for source in converted {
                let overlapStart = max(renderedFrames, source.startFrame)
                let overlapEnd = min(
                    renderedFrames + AVAudioFramePosition(frameCount),
                    source.startFrame + source.file.length
                )
                guard overlapEnd > overlapStart else { continue }
                let sourceFrame = overlapStart - source.startFrame
                let destinationOffset = Int(overlapStart - renderedFrames)
                let overlapFrames = AVAudioFrameCount(overlapEnd - overlapStart)
                source.file.framePosition = sourceFrame
                guard let sourceBuffer = AVAudioPCMBuffer(
                    pcmFormat: renderFormat,
                    frameCapacity: overlapFrames
                ) else {
                    throw NativeMediaProcessorError.readerFailed("source buffer allocation failed")
                }
                try source.file.read(into: sourceBuffer, frameCount: overlapFrames)
                guard let sourceChannels = sourceBuffer.floatChannelData else {
                    throw NativeMediaProcessorError.readerFailed("source buffer has no channel data")
                }
                for channel in 0..<Int(renderFormat.channelCount) {
                    for frame in 0..<Int(sourceBuffer.frameLength) {
                        destinationChannels[channel][destinationOffset + frame] += sourceChannels[channel][frame]
                    }
                }
            }
            for channel in 0..<Int(renderFormat.channelCount) {
                for frame in 0..<Int(frameCount) {
                    destinationChannels[channel][frame] = max(
                        -1,
                        min(1, destinationChannels[channel][frame])
                    )
                }
            }
            try mixFile?.write(from: buffer)
            renderedFrames += AVAudioFramePosition(frameCount)
        }
        // AVAudioFile finalizes the container when released. Export only after the CAF header has
        // been closed and its final frame count is on disk.
        mixFile = nil
        do {
            try await encodeM4A(source: mixURL, destination: partialURL)
            try await verify(
                partialURL,
                expectedTracks: 1,
                expectedFormatID: kAudioFormatMPEG4AAC
            )
            try FileManager.default.moveItem(at: partialURL, to: preferredURL)
            return preferredURL
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Some headless and restricted macOS hosts expose AVFoundation decoding but no AAC
            // encoder. The already-rendered PCM mix is still a complete native recording. Keep it
            // under an honest .wav name rather than failing the call or disguising WAV bytes as
            // M4A. AAC remains preferred everywhere the system encoder is available.
            try await verify(
                mixURL,
                expectedTracks: 1,
                expectedFormat: (sampleRate: 48_000, channels: 2, bits: 16)
            )
            try FileManager.default.moveItem(at: mixURL, to: fallbackURL)
            return fallbackURL
        }
    }

    private func encodeM4A(source: URL, destination: URL) async throws {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw NativeMediaProcessorError.invalidAudio(source)
        }
        let descriptions = try await track.load(.formatDescriptions)
        guard let sourceFormat = descriptions.first else {
            throw NativeMediaProcessorError.invalidAudio(source)
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        guard reader.canAdd(output) else {
            throw NativeMediaProcessorError.readerFailed("PCM track output is unsupported")
        }
        reader.add(output)
        let writer = try AVAssetWriter(outputURL: destination, fileType: .m4a)
        let input = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000.0,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000,
            ],
            sourceFormatHint: sourceFormat
        )
        guard writer.canAdd(input) else {
            throw NativeMediaProcessorError.writerFailed("AAC audio input is unsupported")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw NativeMediaProcessorError.writerFailed(
                writer.error?.localizedDescription ?? "start failed"
            )
        }
        guard reader.startReading() else {
            writer.cancelWriting()
            throw NativeMediaProcessorError.readerFailed(
                reader.error?.localizedDescription ?? "start failed"
            )
        }
        writer.startSession(atSourceTime: .zero)
        while reader.status == .reading {
            try Task.checkCancellation()
            if input.isReadyForMoreMediaData {
                guard let sample = output.copyNextSampleBuffer() else { break }
                guard input.append(sample) else {
                    reader.cancelReading()
                    throw NativeMediaProcessorError.writerFailed(
                        writer.error?.localizedDescription ?? "sample append failed"
                    )
                }
            } else {
                try await Task.sleep(for: .milliseconds(1))
            }
        }
        input.markAsFinished()
        if reader.status == .failed {
            writer.cancelWriting()
            throw NativeMediaProcessorError.readerFailed(
                reader.error?.localizedDescription ?? "read failed"
            )
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw NativeMediaProcessorError.writerFailed(
                writer.error?.localizedDescription ?? "finish failed"
            )
        }
    }

    private func convert(_ source: URL, to destination: URL, format: AVAudioFormat) throws {
        let inputFile = try AVAudioFile(forReading: source)
        let inputFormat = inputFile.processingFormat
        guard let converter = AVAudioConverter(from: inputFormat, to: format) else {
            throw NativeMediaProcessorError.readerFailed("audio conversion is unsupported")
        }
        let outputFile = try AVAudioFile(
            forWriting: destination,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        var inputEnded = false
        var inputReadError: (any Error)?
        while !inputEnded {
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096) else {
                throw NativeMediaProcessorError.writerFailed("conversion buffer allocation failed")
            }
            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError) {
                requestedFrames, inputStatus in
                guard inputFile.framePosition < inputFile.length else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                let frameCount = AVAudioFrameCount(
                    min(
                        AVAudioFramePosition(requestedFrames),
                        inputFile.length - inputFile.framePosition
                    )
                )
                guard let inputBuffer = AVAudioPCMBuffer(
                    pcmFormat: inputFormat,
                    frameCapacity: frameCount
                ) else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try inputFile.read(into: inputBuffer, frameCount: frameCount)
                } catch {
                    inputReadError = error
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = inputBuffer.frameLength > 0 ? .haveData : .endOfStream
                return inputBuffer
            }
            if let inputReadError { throw inputReadError }
            if let conversionError {
                throw NativeMediaProcessorError.readerFailed(conversionError.localizedDescription)
            }
            if outputBuffer.frameLength > 0 { try outputFile.write(from: outputBuffer) }
            switch status {
            case .endOfStream:
                inputEnded = true
            case .error:
                throw NativeMediaProcessorError.readerFailed("audio conversion failed")
            case .haveData, .inputRanDry:
                if outputBuffer.frameLength == 0, inputFile.framePosition >= inputFile.length {
                    inputEnded = true
                }
            @unknown default:
                throw NativeMediaProcessorError.readerFailed("unknown audio conversion status")
            }
        }
    }

    private func writeWhisperWAV(
        source: URL,
        startSeconds: Double,
        durationSeconds: Double,
        destination: URL,
        cancellation: ProcessCancellation?
    ) throws {
        let inputFile = try AVAudioFile(forReading: source)
        let inputFormat = inputFile.processingFormat
        guard
            let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: 16_000,
                channels: 1,
                interleaved: true
            ),
            let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else { throw NativeMediaProcessorError.readerFailed("audio conversion is unsupported") }
        let firstInputFrame = AVAudioFramePosition(
            (startSeconds * inputFormat.sampleRate).rounded()
        )
        let requestedInputFrames = AVAudioFramePosition(
            (durationSeconds * inputFormat.sampleRate).rounded()
        )
        inputFile.framePosition = min(firstInputFrame, inputFile.length)
        var remainingInputFrames = min(
            requestedInputFrames,
            max(0, inputFile.length - inputFile.framePosition)
        )
        let requestedOutputFrames = AVAudioFramePosition(
            (durationSeconds * outputFormat.sampleRate).rounded()
        )
        var remainingOutputFrames = requestedOutputFrames
        let outputFile = try AVAudioFile(
            forWriting: destination,
            settings: outputFormat.settings,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )
        var inputReadError: (any Error)?
        while remainingOutputFrames > 0 {
            try cancellation?.checkCancelled()
            try Task.checkCancellation()
            let capacity = AVAudioFrameCount(min(4_096, remainingOutputFrames))
            guard let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: capacity
            ) else { throw NativeMediaProcessorError.writerFailed("output buffer allocation failed") }
            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError) {
                requestedFrames, inputStatus in
                guard remainingInputFrames > 0 else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                let frameCount = AVAudioFrameCount(
                    min(AVAudioFramePosition(requestedFrames), remainingInputFrames)
                )
                guard let inputBuffer = AVAudioPCMBuffer(
                    pcmFormat: inputFormat,
                    frameCapacity: frameCount
                ) else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try inputFile.read(into: inputBuffer, frameCount: frameCount)
                } catch {
                    inputReadError = error
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                remainingInputFrames -= AVAudioFramePosition(inputBuffer.frameLength)
                inputStatus.pointee = inputBuffer.frameLength > 0 ? .haveData : .endOfStream
                return inputBuffer
            }
            if let inputReadError { throw inputReadError }
            if let conversionError {
                throw NativeMediaProcessorError.readerFailed(conversionError.localizedDescription)
            }
            if outputBuffer.frameLength > 0 {
                try outputFile.write(from: outputBuffer)
                remainingOutputFrames -= AVAudioFramePosition(outputBuffer.frameLength)
            }
            switch status {
            case .error:
                throw NativeMediaProcessorError.readerFailed("audio conversion failed")
            case .endOfStream:
                remainingOutputFrames = 0
            case .haveData, .inputRanDry:
                if outputBuffer.frameLength == 0, remainingInputFrames == 0 {
                    remainingOutputFrames = 0
                }
            @unknown default:
                throw NativeMediaProcessorError.readerFailed("unknown audio conversion status")
            }
        }
    }

    private func verify(
        _ url: URL,
        expectedTracks: Int,
        expectedFormatID: AudioFormatID? = nil,
        expectedFormat: (sampleRate: Double, channels: UInt32, bits: UInt32)? = nil
    ) async throws {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let duration = CMTimeGetSeconds(try await asset.load(.duration))
        guard tracks.count == expectedTracks, duration.isFinite, duration > 0 else {
            throw MediaFinalizerError.unreadableOutput(url)
        }
        if let expectedFormatID {
            let descriptions = try await tracks[0].load(.formatDescriptions)
            guard
                let description = descriptions.first,
                CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee.mFormatID
                    == expectedFormatID
            else { throw MediaFinalizerError.unreadableOutput(url) }
        }
        if let expectedFormat {
            let descriptions = try await tracks[0].load(.formatDescriptions)
            guard let description = descriptions.first else {
                throw MediaFinalizerError.unreadableOutput(url)
            }
            let stream = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee
            guard
                let stream,
                stream.mFormatID == kAudioFormatLinearPCM,
                stream.mSampleRate == expectedFormat.sampleRate,
                stream.mChannelsPerFrame == expectedFormat.channels,
                stream.mBitsPerChannel == expectedFormat.bits,
                stream.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0
            else { throw MediaFinalizerError.unreadableOutput(url) }
        }
    }

}
