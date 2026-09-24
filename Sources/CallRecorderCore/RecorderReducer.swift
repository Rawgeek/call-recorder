public enum RecorderReducer {
    public static func reduce(state: RecordingState, event: RecorderEvent) -> RecordingState {
        switch event {
        case let .restorePendingSession(sessionID):
            guard state.phase == .idle else { return state }
            return RecordingState(
                phase: .awaitingParticipants,
                sessionID: sessionID,
                externalMicrophoneActive: state.externalMicrophoneActive,
                automaticStartSuppressed: true,
                failure: nil
            )

        case let .manualStart(sessionID):
            guard state.phase == .idle else { return state }
            return RecordingState(
                phase: .recording,
                sessionID: sessionID,
                externalMicrophoneActive: state.externalMicrophoneActive,
                automaticStartSuppressed: true,
                failure: nil
            )

        case .manualPause:
            guard state.phase == .recording else { return state }
            return state.replacing(phase: .paused, automaticStartSuppressed: true)

        case .manualResume:
            guard state.phase == .paused else { return state }
            return state.replacing(phase: .recording)

        case .manualStop:
            guard state.phase == .recording || state.phase == .paused else { return state }
            return state.replacing(phase: .finalizing, automaticStartSuppressed: true)

        case let .externalMicrophoneChanged(isActive, newSessionID):
            let updated = state.replacing(
                externalMicrophoneActive: isActive,
                automaticStartSuppressed: isActive ? state.automaticStartSuppressed : false
            )
            guard
                isActive,
                updated.phase == .idle,
                !updated.automaticStartSuppressed,
                let newSessionID
            else {
                return updated
            }
            return .recording(sessionID: newSessionID, externalMicrophoneActive: true)

        case .automaticStopGraceElapsed:
            guard state.phase == .recording, !state.externalMicrophoneActive else { return state }
            return state.replacing(phase: .finalizing)

        case .audioFinalizedAndQueued:
            guard state.phase == .finalizing else { return state }
            return RecordingState(
                phase: .idle,
                sessionID: nil,
                externalMicrophoneActive: state.externalMicrophoneActive,
                automaticStartSuppressed: state.externalMicrophoneActive,
                failure: nil
            )

        case .processingQueued:
            guard state.phase == .awaitingParticipants else { return state }
            return RecordingState(
                phase: .idle,
                sessionID: nil,
                externalMicrophoneActive: state.externalMicrophoneActive,
                automaticStartSuppressed: state.externalMicrophoneActive,
                failure: nil
            )

        case .participantsSaved:
            guard state.phase == .awaitingParticipants else { return state }
            return state.replacing(phase: .transcribing)

        case .transcriptionFinished:
            guard state.phase == .transcribing else { return state }
            return state.replacing(phase: .indexing)

        case .discard:
            guard state.phase == .awaitingParticipants || state.phase == .failed else { return state }
            return RecordingState(
                phase: .idle,
                sessionID: nil,
                externalMicrophoneActive: state.externalMicrophoneActive,
                automaticStartSuppressed: state.automaticStartSuppressed,
                failure: nil
            )

        case .indexingFinished:
            guard state.phase == .indexing else { return state }
            return RecordingState(
                phase: .idle,
                sessionID: nil,
                externalMicrophoneActive: state.externalMicrophoneActive,
                automaticStartSuppressed: state.externalMicrophoneActive,
                failure: nil
            )

        case let .fail(failure):
            return RecordingState(
                phase: .failed,
                sessionID: state.sessionID,
                externalMicrophoneActive: state.externalMicrophoneActive,
                automaticStartSuppressed: state.automaticStartSuppressed,
                failure: failure
            )

        case .recover:
            guard state.phase == .failed, state.sessionID == nil else { return state }
            return .idle
        }
    }
}

extension RecordingPhase {
    /// Whether this phase is capturing the audio of a call.
    ///
    /// These are the phases the live path lives in, because it reads the same audio the recording
    /// writes: a call being recorded, and one held at a pause that will be resumed. A start reaches
    /// `recording` only after the events that carry the microphone state, so `idle` is not one of
    /// them even while a start is under way, and `finalizing` is not one of them because the
    /// capture has already closed by then.
    public var holdsLiveTranscript: Bool {
        switch self {
        case .recording, .paused: true
        case .idle, .finalizing, .awaitingParticipants, .transcribing, .indexing, .failed: false
        }
    }

    /// Whether a move between two phases ends the live path of the call that owns it.
    ///
    /// The answer is a change of phase rather than the phase a reducer hands back, and the
    /// 2026-09-22 13:18 call is why: a manual start publishes the microphone state before it
    /// publishes the start, and both events leave the phase `idle`. Read as "the recorder is idle,
    /// so the call has ended", the first of them released the live path seventeen seconds before
    /// the tap wrote its first chunk. The window said "Recording finished" over a call that was
    /// recording, and no words ever reached it.
    public static func endsLiveTranscript(
        from before: RecordingPhase,
        to after: RecordingPhase
    ) -> Bool {
        before.holdsLiveTranscript && !after.holdsLiveTranscript
    }
}
