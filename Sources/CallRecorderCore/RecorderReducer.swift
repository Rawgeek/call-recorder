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

        case .limitStop:
            // A rail's stop: the ceiling, or ten minutes of silence. Both ask while the call's app
            // may still hold the microphone -- that is the state they exist for -- so this cannot
            // take the answer .automaticStopGraceElapsed takes. That event is refused whenever the
            // external microphone is still active, and on 2026-10-06 the refusal left the 17:29
            // automatic recording in .recording: no segment was finished, the call row stayed at
            // "recording", the save answered "no audio segments", and the audio files were left
            // open. The rail's own event stops the recording whatever the microphone is doing.
            guard state.phase == .recording || state.phase == .paused else { return state }
            return state.replacing(phase: .finalizing, automaticStartSuppressed: true)

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
}
