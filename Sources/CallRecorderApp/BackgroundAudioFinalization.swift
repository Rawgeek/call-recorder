import CallRecorderCore
import Foundation

struct BackgroundFinalizationError: LocalizedError, Equatable {
    let message: String

    var errorDescription: String? { message }
}

struct BackgroundFinalizationUnavailableError: LocalizedError, Equatable {
    var errorDescription: String? {
        "The audio could not be saved because the finalization pipeline is unavailable."
    }
}

struct BackgroundFinalizationFailure: Equatable, Sendable {
    let job: PendingBackgroundCall
    let message: String
}

struct BackgroundFinalizationState: Equatable, Sendable {
    var pendingCalls: [PendingBackgroundCall] = []
    var failures: [BackgroundFinalizationFailure] = []
    var successes: [PendingBackgroundCall] = []
}

actor BackgroundAudioFinalization {
    private var store: CallStore?
    private var pipeline: CallPipeline?
    private var finalizationState = BackgroundFinalizationState()
    private var scheduled = false
    private var drainTask: Task<Void, Never>?
    private var onChange: (@Sendable (BackgroundFinalizationState) async -> Void)?

    init(
        store: CallStore?,
        pipeline: CallPipeline?,
        onChange: (@Sendable (BackgroundFinalizationState) async -> Void)? = nil
    ) {
        self.store = store
        self.pipeline = pipeline
        self.onChange = onChange
    }

    func attach(store: CallStore?, pipeline: CallPipeline?) {
        self.store = store
        self.pipeline = pipeline
    }

    func setOnChange(_ onChange: (@Sendable (BackgroundFinalizationState) async -> Void)?) {
        self.onChange = onChange
    }

    func enqueue(_ job: PendingBackgroundCall) async {
        guard !finalizationState.pendingCalls.contains(where: { $0.callID == job.callID }) else {
            return
        }
        finalizationState.pendingCalls.append(job)
        await notify()
        scheduleDrain()
    }

    func retryFailed(_ callID: CallID) async {
        guard
            let index = finalizationState.failures.firstIndex(where: { $0.job.callID == callID })
        else {
            return
        }
        let job = finalizationState.failures.remove(at: index).job
        finalizationState.pendingCalls.append(job)
        await notify()
        scheduleDrain()
    }

    func captureAvailable() -> Bool {
        true
    }

    func waitForDrain() async {
        await drainTask?.value
    }

    func state() -> BackgroundFinalizationState {
        finalizationState
    }

    private func scheduleDrain() {
        guard !scheduled else { return }
        scheduled = true
        drainTask = Task { await self.drain() }
    }

    private func drain() async {
        defer {
            scheduled = false
            drainTask = nil
        }
        while let job = finalizationState.pendingCalls.first {
            do {
                guard store != nil, pipeline != nil, !Task.isCancelled else {
                    throw BackgroundFinalizationUnavailableError()
                }
                _ = try await finalize(job)
                finalizationState.pendingCalls.removeFirst()
                finalizationState.successes.append(job)
            } catch {
                finalizationState.pendingCalls.removeFirst()
                finalizationState.failures.append(
                    BackgroundFinalizationFailure(
                        job: job,
                        message: DiagnosticsReporter.redacted(error: String(reflecting: error))
                    )
                )
            }
            await notify()
        }
    }

    private func finalize(_ job: PendingBackgroundCall) async throws -> URL {
        guard store != nil, let pipeline else {
            throw BackgroundFinalizationUnavailableError()
        }
        let segments = job.segments.compactMap { snapshot -> CaptureSegment? in
            guard snapshot.systemURL != nil || snapshot.microphoneURL != nil else { return nil }
            return try? CaptureSegment(
                index: snapshot.index,
                system: snapshot.systemURL.map {
                    CapturedAudioSource(
                        fileURL: $0,
                        firstPresentationSeconds: 0,
                        durationSeconds: 0
                    )
                },
                microphone: snapshot.microphoneURL.map {
                    CapturedAudioSource(
                        fileURL: $0,
                        firstPresentationSeconds: 0,
                        durationSeconds: 0
                    )
                }
            )
        }
        guard !segments.isEmpty else {
            throw BackgroundFinalizationError(message: "The recording contained no audio segments.")
        }
        return try await pipeline.finalize(
            callID: job.callID,
            segments: segments,
            destination: job.destination,
            endedAt: job.endedAt
        )
    }

    private func notify() async {
        await onChange?(finalizationState)
    }
}
