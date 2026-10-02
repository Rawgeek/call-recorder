import CallRecorderCore
import Testing
@testable import CallRecorderApp

/// What the Discard control does in each state the recorder can be in.
///
/// The control is drawn beside Stop, while the recording is still running, and its confirm asks
/// "Discard this recording?" there. On 2026-10-02 the answer to that question did nothing: the
/// request only ever took the path for a stopped recording, and a stopped recording was the one
/// state it was not in. What each state means is a mapping the model follows, so the case that
/// did nothing is a case in a test.
@Suite("Recording discard")
struct RecordingDiscardTests {
    @Test("a running recording is stopped and then given up")
    func aRunningRecordingIsStoppedThenGivenUp() {
        // The live case: the capture has to stop before anything can be given up, and what it
        // was holding is discarded rather than finalized.
        #expect(RecordingDiscard.intent(for: .recording) == .stopThenDiscard)
        #expect(RecordingDiscard.intent(for: .paused) == .stopThenDiscard)
    }

    @Test("a stopped recording and a failed call are given up where they are")
    func aStoppedRecordingIsGivenUpWhereItIs() {
        #expect(RecordingDiscard.intent(for: .awaitingParticipants) == .discardHeld)
        #expect(RecordingDiscard.intent(for: .failed) == .discardHeld)
    }

    @Test("the states with no recording to give up do nothing")
    func theStatesWithNothingToGiveUpDoNothing() {
        // A stage that is running owns the call: the work is stopped by the row that names the
        // stage, not by the trash control, and a discard here would leave the stage's own
        // process writing into a call that no longer exists.
        for phase in [RecordingPhase.idle, .finalizing, .transcribing, .indexing] {
            #expect(RecordingDiscard.intent(for: phase) == .nothing)
        }
    }
}
