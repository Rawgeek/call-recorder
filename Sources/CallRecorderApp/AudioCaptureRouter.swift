import CoreMedia
import Foundation
import ScreenCaptureKit

final class AudioCaptureRouter: NSObject, SCStreamOutput, @unchecked Sendable {
    private enum WriterOutcome: Sendable {
        case success(CapturedAudioSource?)
        case failure(String)
    }

    let systemQueue = DispatchQueue(label: "local.callrecorder.capture.system")
    let microphoneQueue = DispatchQueue(label: "local.callrecorder.capture.microphone")
    private let systemWriter: AudioSampleWriter
    private let microphoneWriter: AudioSampleWriter
    /// The level of everything the capture delivers, which is what the silence rail reads.
    private let levels: AudioLevelMeter
    /// The live transcript's own reader of the same audio, when one is attached.
    ///
    /// It is optional and it is asked for: a recording with the live view switched off copies
    /// nothing and holds nothing, which is the rule amanu's relay keeps — a live feature must not
    /// cost a recording that is not using it.
    private let liveTap: LiveAudioTap?

    init(paths: CaptureSourcePaths, levels: AudioLevelMeter, liveTap: LiveAudioTap? = nil) {
        systemWriter = AudioSampleWriter(destination: paths.system)
        microphoneWriter = AudioSampleWriter(destination: paths.microphone)
        self.levels = levels
        self.liveTap = liveTap
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        do {
            switch outputType {
            case .audio:
                levels.observe(sampleBuffer)
                liveTap?.append(sampleBuffer, source: .system)
                try systemWriter.append(sampleBuffer)
            case .microphone:
                levels.observe(sampleBuffer)
                liveTap?.append(sampleBuffer, source: .microphone)
                try microphoneWriter.append(sampleBuffer)
            case .screen:
                return
            @unknown default:
                return
            }
        } catch {
            switch outputType {
            case .audio:
                systemWriter.cancel()
            case .microphone:
                microphoneWriter.cancel()
            case .screen:
                return
            @unknown default:
                return
            }
        }
    }

    func finish(index: Int) async throws -> CaptureSegment {
        // The live tail is closed first, while the transcriber behind it is still running: the last
        // words of a call are usually the ones somebody wants to read back.
        liveTap?.finish()
        async let system = outcome(from: systemWriter)
        async let microphone = outcome(from: microphoneWriter)
        let outcomes = await (system, microphone)
        let systemSource: CapturedAudioSource?
        let microphoneSource: CapturedAudioSource?
        var failures: [String] = []
        switch outcomes.0 {
        case let .success(source): systemSource = source
        case let .failure(message):
            systemSource = nil
            failures.append("system: \(message)")
        }
        switch outcomes.1 {
        case let .success(source): microphoneSource = source
        case let .failure(message):
            microphoneSource = nil
            failures.append("microphone: \(message)")
        }
        guard systemSource != nil || microphoneSource != nil else {
            if failures.isEmpty { throw AudioCaptureError.noAudio }
            throw AudioSampleWriterError.writerFailed(failures.joined(separator: "; "))
        }
        let segment = try CaptureSegment(
            index: index,
            system: systemSource,
            microphone: microphoneSource
        )
        _ = try CaptureSegmentManifest.write(segment, in: segment.fileURL.deletingLastPathComponent())
        return segment
    }

    func cancel() {
        systemWriter.cancel()
        microphoneWriter.cancel()
    }

    private func outcome(from writer: AudioSampleWriter) async -> WriterOutcome {
        do {
            return .success(try await writer.finish())
        } catch {
            return .failure(error.localizedDescription)
        }
    }
}
