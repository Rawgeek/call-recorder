import Testing
@testable import CallRecorderCore

struct AudioActivityDecisionTests {
    @Test func ignoresTheRecorderProcess() {
        // Given
        let activeInputs = [
            AudioActivityDecision.Input(processID: 42, bundleID: "local.callrecorder.app")
        ]

        // When / Then
        #expect(
            !AudioActivityDecision.hasExternalInput(
                inputs: activeInputs,
                ownProcessID: 42,
                ignoringNonCallApps: true
            )
        )
    }

    @Test func detectsAnyOtherProcessWithActiveInput() {
        // Given
        let activeInputs = [
            AudioActivityDecision.Input(processID: 42, bundleID: "local.callrecorder.app"),
            AudioActivityDecision.Input(processID: 81, bundleID: "us.zoom.xos"),
        ]

        // When / Then
        #expect(
            AudioActivityDecision.hasExternalInput(
                inputs: activeInputs,
                ownProcessID: 42,
                ignoringNonCallApps: true
            )
        )
    }

    @Test func noInputProcessesRemainIdle() {
        // Given / When / Then
        #expect(
            !AudioActivityDecision.hasExternalInput(
                inputs: [],
                ownProcessID: 42,
                ignoringNonCallApps: true
            )
        )
    }
}
