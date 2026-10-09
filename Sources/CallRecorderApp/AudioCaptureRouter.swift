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
    /// The microphone track on its own, which is what the Settings level row draws.
    ///
    /// A second meter rather than the one above, because the two questions are different: the rail
    /// asks whether the call went quiet, and the row asks whether the microphone is hearing the
    /// person in front of it. One meter cannot answer both: the other side of a call is loud enough
    /// to hold a shared meter up while the room is silent.
    private let microphoneLevels: AudioLevelMeter
    init(paths: CaptureSourcePaths, levels: AudioLevelMeter, microphoneLevels: AudioLevelMeter) {
        systemWriter = AudioSampleWriter(destination: paths.system)
        microphoneWriter = AudioSampleWriter(destination: paths.microphone)
        self.levels = levels
        self.microphoneLevels = microphoneLevels
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
                try systemWriter.append(sampleBuffer)
            case .microphone:
                levels.observe(sampleBuffer)
                microphoneLevels.observe(sampleBuffer)
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
