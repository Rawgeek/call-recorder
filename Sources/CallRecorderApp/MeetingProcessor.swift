import CallRecorderCore
import Foundation
import OSLog

struct ProcessorDemand {
    private var isRunning = false
    private var rerunRequested = false

    mutating func request() -> Bool {
        guard !isRunning else {
            rerunRequested = true
            return false
        }
        isRunning = true
        return true
    }

    mutating func finish() -> Bool {
        guard isRunning else { return false }
        guard rerunRequested else {
            isRunning = false
            return false
        }
        rerunRequested = false
        return true
    }

    mutating func cancel() {
        isRunning = false
        rerunRequested = false
    }
}

actor MeetingProcessor {
    typealias StageRunner = @Sendable (ProcessingJob) async throws -> ProcessingStage

    private let store: CallStore
    private let runStage: StageRunner
    private let onChange: (@Sendable () async -> Void)?
    /// Called once a stopped stage has gone back to the queue, so the surface can say so.
    private let onStageCancelled: (@Sendable (CallID) async -> Void)?
    private var task: Task<Void, Never>?
    private var demand = ProcessorDemand()
    private var resetOnNextDrain = false
    private var isStopped = false
    private let logger = Logger(subsystem: "local.callrecorder.app", category: "processing")

    init(
        store: CallStore,
        runStage: @escaping StageRunner,
        onChange: (@Sendable () async -> Void)? = nil,
        onStageCancelled: (@Sendable (CallID) async -> Void)? = nil
    ) {
        self.store = store
        self.runStage = runStage
        self.onChange = onChange
        self.onStageCancelled = onStageCancelled
    }

    func start() {
        isStopped = false
        schedule(resetInterrupted: true)
    }

    func processNext() {
        schedule(resetInterrupted: false)
    }

    func stop() {
        isStopped = true
        task?.cancel()
    }

    func waitUntilIdle() async {
        while let active = task {
            await active.value
        }
    }

    private func schedule(resetInterrupted: Bool) {
        guard !isStopped else { return }
        resetOnNextDrain = resetOnNextDrain || resetInterrupted
        guard demand.request() else { return }
        launchDrain()
    }

    private func launchDrain() {
        let resetInterrupted = resetOnNextDrain
        resetOnNextDrain = false
        task = Task { [weak self] in
            await self?.drain(resetInterrupted: resetInterrupted)
        }
    }

    private func drain(resetInterrupted: Bool) async {
        defer {
            task = nil
            if isStopped {
                demand.cancel()
                resetOnNextDrain = false
            } else if demand.finish() {
                launchDrain()
            }
        }
        do {
            if resetInterrupted {
                try await store.resetInterruptedProcessingJobs()
            }
            while !Task.isCancelled {
                guard let job = try await store.claimNextProcessingJob(executableOnly: true) else {
                    return
                }
                do {
                    let nextStage = try await runStage(job)
                    _ = try await store.advanceProcessingJob(
                        callID: job.callID,
                        from: job.stage,
                        to: nextStage
                    )
                    await onChange?()
                } catch CallStoreError.processingJobNotClaimed(let callID) {
                    // A pass that rewrote the transcript while this stage ran has queued the call's
                    // stage again, which clears the claim this loop was holding. The work is
                    // superseded rather than lost, and the call is already back in the queue, so it
                    // is reported and left there. Letting this end the loop is what left the
                    // 2026-09-18 14:01 call at "Indexing" with every call behind it waiting: the
                    // transcript rewrite had just queued it again, and the advance failed.
                    logger.notice(
                        """
                        Call \(callID.rawValue.uuidString, privacy: .public) was queued again \
                        while its stage ran; the queue keeps it
                        """
                    )
                    await onChange?()
                } catch is CancellationError {
                    // A stopped stage is not a failure: the call goes back to the queue with
                    // everything it already has, and the surface that stopped it is told. The claim
                    // can already be back in the queue by the time the stage notices, because the
                    // surface that stopped it puts it there: that is the same answer and not a
                    // second fault. On 2026-09-24 it was thrown out of here, which ended the drain
                    // and logged "Processor loop failed" over a call that was exactly where it
                    // belonged, and left the surface that stopped it waiting for an answer that
                    // never came.
                    do {
                        try await store.stopProcessingJob(
                            callID: job.callID,
                            stage: job.stage
                        )
                    } catch CallStoreError.processingJobNotClaimed(let callID) {
                        logger.notice(
                            """
                            Call \(callID.rawValue.uuidString, privacy: .public) was already back \
                            in the queue when its stopped stage ended
                            """
                        )
                    }
                    await onStageCancelled?(job.callID)
                    await onChange?()
                    return
                } catch {
                    let details = DiagnosticsReporter.redacted(error: String(reflecting: error))
                    // A stage whose claim is already gone is not this stage's failure to record: a
                    // pass that rewrote the transcript while it ran has queued the call again, and
                    // the queue holds it. Throwing out of here ended the drain over a call that was
                    // in the right state, so it is reported and the loop goes on.
                    do {
                        _ = try await store.failProcessingJob(
                            callID: job.callID,
                            stage: job.stage,
                            summary: "Background processing failed.",
                            errorType: String(describing: type(of: error)),
                            details: details
                        )
                    } catch CallStoreError.processingJobNotClaimed(let callID) {
                        logger.notice(
                            """
                            Call \(callID.rawValue.uuidString, privacy: .public) was queued again \
                            while its stage failed; the queue keeps it
                            """
                        )
                    }
                    await onChange?()
                    logger.error("Call \(job.callID.rawValue.uuidString, privacy: .public) stage \(job.stage.rawValue, privacy: .public) failed: \(details, privacy: .public)")
                }
            }
        } catch {
            let details = DiagnosticsReporter.redacted(error: String(reflecting: error))
            logger.error("Processor loop failed: \(details, privacy: .public)")
        }
    }
}
