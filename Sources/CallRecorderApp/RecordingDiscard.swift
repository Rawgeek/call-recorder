import CallRecorderCore

/// What the Discard control means in the state the recorder is in.
///
/// Discard is offered in two places and they are not the same request. Beside Stop it is offered
/// while the recording is still running; after a stop it is offered on the screen that asks who
/// was on the call. A live capture cannot be discarded: the state machine refuses the event, and
/// it is right to, because the audio is still being written. So the live case has to stop the
/// capture first and give up what it holds afterwards.
enum RecordingDiscard {
    /// A recording is running: stop the capture the way Stop stops it, then give up what it holds.
    case stopThenDiscard
    /// A stopped recording is waiting for people, or a call failed: give up what is held.
    case discardHeld
    /// There is nothing here to give up.
    case nothing

    static func intent(for phase: RecordingPhase) -> RecordingDiscard {
        switch phase {
        case .recording, .paused:
            return .stopThenDiscard
        case .idle, .finalizing, .transcribing, .indexing:
            return .nothing
        case .awaitingParticipants, .failed:
            return .discardHeld
        }
    }
}
