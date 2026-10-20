import Foundation
import CallRecorderCore
import Testing
@testable import CallRecorderApp

@Suite("Automatic stop grace")
struct AutomaticStopGateTests {
    @Test("a queued stop still valid at execution runs once")
    @MainActor
    func unchangedGraceStops() async {
        let world = GraceWorld()
        let request = AutomaticStopRequest(
            sessionID: world.state.sessionID!,
            generation: world.generation
        )

        let recorded = await runQueuedStop(world: world, request: request) { _ in }

        #expect(recorded == ["stop"])
    }

    @Test("recovered two-way activity discards a queued stop")
    @MainActor
    func recoveredActivityDiscards() async {
        let world = GraceWorld()
        let request = AutomaticStopRequest(
            sessionID: world.state.sessionID!,
            generation: world.generation
        )

        let recorded = await runQueuedStop(world: world, request: request) {
            $0.microphoneActive = true
            $0.twoWayActive = true
        }

        #expect(recorded.isEmpty)
    }

    @Test("a replaced session discards a queued stop")
    @MainActor
    func replacedSessionDiscards() async {
        let world = GraceWorld()
        let request = AutomaticStopRequest(
            sessionID: world.state.sessionID!,
            generation: world.generation
        )

        let recorded = await runQueuedStop(world: world, request: request) {
            let next = SessionID(rawValue: UUID())
            $0.state = RecordingState(
                phase: .recording,
                sessionID: next,
                externalMicrophoneActive: true,
                automaticStartSuppressed: false,
                failure: nil
            )
        }

        #expect(recorded.isEmpty)
    }

    @Test("a replaced grace generation discards a queued stop")
    @MainActor
    func replacedGenerationDiscards() async {
        let world = GraceWorld()
        let request = AutomaticStopRequest(
            sessionID: world.state.sessionID!,
            generation: world.generation
        )

        let recorded = await runQueuedStop(world: world, request: request) {
            $0.generation += 1
        }

        #expect(recorded.isEmpty)
    }

    @Test("a manual or finished recording discards a queued stop")
    @MainActor
    func ineligibleRecordingDiscards() async {
        let world = GraceWorld()
        let request = AutomaticStopRequest(
            sessionID: world.state.sessionID!,
            generation: world.generation
        )

        let recorded = await runQueuedStop(world: world, request: request) {
            $0.state = RecordingState(
                phase: .recording,
                sessionID: $0.state.sessionID,
                externalMicrophoneActive: true,
                automaticStartSuppressed: true,
                failure: nil
            )
        }

        #expect(recorded.isEmpty)
    }

    @MainActor
    private func runQueuedStop(
        world: GraceWorld,
        request: AutomaticStopRequest,
        beforeRelease: (GraceWorld) -> Void
    ) async -> [String] {
        var queue = CaptureCommandQueue()
        let held = AsyncGate()
        let probe = LockedStringProbe()
        let first = queue.enqueue { await held.wait() }
        let command = queue.enqueue {
            guard AppModel.automaticStopIsCurrent(
                request,
                generation: world.generation,
                state: world.state,
                externalMicrophoneActive: world.microphoneActive,
                twoWayCallActive: world.twoWayActive
            ) else { return }
            probe.record("stop")
        }

        beforeRelease(world)
        held.open()
        await first.value
        await command.value
        return probe.values()
    }
}

private final class GraceWorld: @unchecked Sendable {
    var generation = 1
    var state: RecordingState
    var microphoneActive = false
    var twoWayActive = true

    init() {
        state = RecordingState(
            phase: .recording,
            sessionID: SessionID(rawValue: UUID()),
            externalMicrophoneActive: false,
            automaticStartSuppressed: false,
            failure: nil
        )
    }
}
