import CoreMedia
import Foundation
import ScreenCaptureKit

final class MicrophoneSampleGate: @unchecked Sendable {
    private let lock = NSLock()
    private var receivedSample = false
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

    func signal() {
        lock.lock()
        receivedSample = true
        let continuations = Array(waiters.values)
        waiters.removeAll()
        lock.unlock()
        continuations.forEach { $0.resume(returning: true) }
    }

    func wait(timeout: Duration) async -> Bool {
        let token = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                if receivedSample {
                    lock.unlock()
                    continuation.resume(returning: true)
                    return
                }
                waiters[token] = continuation
                let alreadyCancelled = Task.isCancelled
                lock.unlock()
                if alreadyCancelled {
                    resolve(token: token, value: false)
                    return
                }
                Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    self?.resolve(token: token, value: false)
                }
            }
        } onCancel: {
            resolve(token: token, value: false)
        }
    }

    private func resolve(token: UUID, value: Bool) {
        lock.lock()
        let continuation = waiters.removeValue(forKey: token)
        lock.unlock()
        continuation?.resume(returning: value)
    }
}

final class AudioCaptureRouter: NSObject, SCStreamOutput, @unchecked Sendable {
    private enum WriterOutcome: Sendable {
        case success(CapturedAudioSource?)
        case failure(String)
    }

    let systemQueue = DispatchQueue(label: "local.callrecorder.capture.system")
    let microphoneQueue = DispatchQueue(label: "local.callrecorder.capture.microphone")
    private let systemWriter: AudioSampleWriter
    private let microphoneWriter: AudioSampleWriter
    private let microphoneSampleGate = MicrophoneSampleGate()
    /// The level of everything the capture delivers, which is what the silence rail reads.
    private let levels: AudioLevelMeter

    init(paths: CaptureSourcePaths, levels: AudioLevelMeter) {
        systemWriter = AudioSampleWriter(destination: paths.system)
        microphoneWriter = AudioSampleWriter(destination: paths.microphone)
        self.levels = levels
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
                let appended = try microphoneWriter.append(sampleBuffer)
                // Readiness means more than receiving a callback: the AirPods format must also be
                // accepted by the writer before the app tells the user recording has begun.
                if appended { microphoneSampleGate.signal() }
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

    func waitForMicrophoneSample(timeout: Duration) async -> Bool {
        await microphoneSampleGate.wait(timeout: timeout)
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
