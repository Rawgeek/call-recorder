import Testing
@testable import CallRecorderCore

struct AudioActivityDecisionTests {
    @Test func ignoresTheRecorderProcess() {
        // Given
        let activeInputs: [Int32] = [42]

        // When / Then
        #expect(!AudioActivityDecision.hasExternalInput(activeProcessIDs: activeInputs, ownProcessID: 42))
    }

    @Test func detectsAnyOtherProcessWithActiveInput() {
        // Given
        let activeInputs: [Int32] = [42, 81]

        // When / Then
        #expect(AudioActivityDecision.hasExternalInput(activeProcessIDs: activeInputs, ownProcessID: 42))
    }

    @Test func noInputProcessesRemainIdle() {
        // Given / When / Then
        #expect(!AudioActivityDecision.hasExternalInput(activeProcessIDs: [], ownProcessID: 42))
    }
}
