import Foundation
import Testing
@testable import CallRecorderCore

@Suite("Recorder reducer")
struct RecorderReducerTests {
    @Test("automatic recording starts when an external microphone becomes active")
    func automaticStartWhenExternalMicActivates() {
        let sessionID = SessionID(rawValue: UUID())
        let state = RecorderReducer.reduce(
            state: .idle,
            event: .externalMicrophoneChanged(isActive: true, newSessionID: sessionID)
        )
        #expect(state.phase == .recording)
        #expect(state.sessionID == sessionID)
        #expect(state.externalMicrophoneActive)
    }

    @Test("manual recording starts without external microphone activity")
    func manualStartWhenIdle() {
        let sessionID = SessionID(rawValue: UUID())
        let state = RecorderReducer.reduce(state: .idle, event: .manualStart(sessionID: sessionID))
        #expect(state.phase == .recording)
        #expect(state.sessionID == sessionID)
        #expect(state.automaticStartSuppressed)
    }

    // The 2026-09-22 13:18 call: a manual start walks two events and both leave the phase idle, so a
    // live path that ended whenever the reducer handed back `idle` was released at the start of the
    // call. The window said "Recording finished" and no words ever reached it.
    @Test("the events of a start do not end the live path")
    func startLeavesLivePathAlone() {
        let sessionID = SessionID(rawValue: UUID())
        let carryingMicrophone = RecorderReducer.reduce(
            state: .idle,
            event: .externalMicrophoneChanged(isActive: true, newSessionID: nil)
        )
        let recording = RecorderReducer.reduce(
            state: carryingMicrophone,
            event: .manualStart(sessionID: sessionID)
        )
        #expect(carryingMicrophone.phase == .idle)
        #expect(!RecordingPhase.endsLiveTranscript(from: .idle, to: carryingMicrophone.phase))
        #expect(!RecordingPhase.endsLiveTranscript(from: carryingMicrophone.phase, to: recording.phase))
    }

    @Test("the live path outlives a pause and a resume")
    func pauseAndResumeKeepLivePath() {
        #expect(!RecordingPhase.endsLiveTranscript(from: .recording, to: .paused))
        #expect(!RecordingPhase.endsLiveTranscript(from: .paused, to: .recording))
    }

    @Test("the live path ends when the call stops being captured")
    func livePathEndsWithTheCapture() {
        // `finalizing` is a capture that has closed: the live path reads the same audio the
        // recording writes, so it has nothing left to read from there on.
        #expect(RecordingPhase.endsLiveTranscript(from: .recording, to: .finalizing))
        #expect(RecordingPhase.endsLiveTranscript(from: .recording, to: .idle))
        #expect(RecordingPhase.endsLiveTranscript(from: .paused, to: .failed))
        #expect(!RecordingPhase.endsLiveTranscript(from: .finalizing, to: .idle))
    }

    @Test("a pending call resumes participant selection after relaunch")
    func restorePendingCallWhenIdle() {
        let sessionID = SessionID(rawValue: UUID())
        let state = RecorderReducer.reduce(
            state: .idle,
            event: .restorePendingSession(sessionID: sessionID)
        )
        #expect(state.phase == .awaitingParticipants)
        #expect(state.sessionID == sessionID)
    }

    @Test("recording pauses and resumes only through manual controls")
    func pauseAndResumeWhenRecording() {
        let recording = RecordingState.recording(sessionID: SessionID(rawValue: UUID()))
        let paused = RecorderReducer.reduce(state: recording, event: .manualPause)
        let autoSignal = RecorderReducer.reduce(
            state: paused,
            event: .externalMicrophoneChanged(isActive: true, newSessionID: nil)
        )
        let resumed = RecorderReducer.reduce(state: autoSignal, event: .manualResume)
        #expect(paused.phase == .paused)
        #expect(autoSignal.phase == .paused)
        #expect(resumed.phase == .recording)
    }

    @Test("manual stop suppresses automatic restart until external microphone stops")
    func manualStopSuppressesAutomaticRestart() {
        let sessionID = SessionID(rawValue: UUID())
        let recording = RecordingState.recording(sessionID: sessionID, externalMicrophoneActive: true)
        let finalizing = RecorderReducer.reduce(state: recording, event: .manualStop)
        let idle = RecorderReducer.reduce(state: finalizing, event: .audioFinalizedAndQueued)
        let retriggered = RecorderReducer.reduce(
            state: idle,
            event: .externalMicrophoneChanged(isActive: true, newSessionID: SessionID(rawValue: UUID()))
        )
        #expect(finalizing.phase == .finalizing)
        #expect(finalizing.automaticStartSuppressed)
        #expect(retriggered.phase == .idle)
        #expect(retriggered.sessionID == nil)
        #expect(retriggered.automaticStartSuppressed)
    }

    @Test("external microphone stopping clears automatic suppression after session completion")
    func inactiveExternalMicClearsSuppressionAfterCompletion() {
        let indexing = RecordingState(
            phase: .indexing,
            sessionID: SessionID(rawValue: UUID()),
            externalMicrophoneActive: true,
            automaticStartSuppressed: true,
            failure: nil
        )
        let inactive = RecorderReducer.reduce(
            state: indexing,
            event: .externalMicrophoneChanged(isActive: false, newSessionID: nil)
        )
        let idle = RecorderReducer.reduce(state: inactive, event: .indexingFinished)
        #expect(idle == .idle)
    }

    @Test("automatic stop waits for grace completion and inactive external microphone")
    func autoStopAfterGraceWhenExternalMicInactive() {
        let recording = RecordingState.recording(
            sessionID: SessionID(rawValue: UUID()),
            externalMicrophoneActive: false
        )
        let state = RecorderReducer.reduce(state: recording, event: .automaticStopGraceElapsed)
        #expect(state.phase == .finalizing)
        #expect(!state.automaticStartSuppressed)
    }

    @Test("a second start cannot replace an active session")
    func overlappingStartIsIgnored() {
        let original = SessionID(rawValue: UUID())
        let recording = RecordingState.recording(sessionID: original)
        let state = RecorderReducer.reduce(
            state: recording,
            event: .manualStart(sessionID: SessionID(rawValue: UUID()))
        )
        #expect(state.sessionID == original)
        #expect(state.phase == .recording)
    }

    @Test("discard in awaiting-participants returns to idle")
    func discardInAwaitingParticipantsReturnsToIdle() {
        let state = RecordingState(
            phase: .awaitingParticipants,
            sessionID: SessionID(rawValue: UUID()),
            externalMicrophoneActive: true,
            automaticStartSuppressed: true,
            failure: nil
        )
        let result = RecorderReducer.reduce(state: state, event: .discard)
        #expect(result.phase == .idle)
        #expect(result.sessionID == nil)
    }

    @Test("queued processing releases capture for the next meeting")
    func queuedProcessingReturnsToIdle() {
        let state = RecordingState(
            phase: .awaitingParticipants,
            sessionID: SessionID(rawValue: UUID()),
            externalMicrophoneActive: false,
            automaticStartSuppressed: true,
            failure: nil
        )

        let result = RecorderReducer.reduce(state: state, event: .processingQueued)

        #expect(result.phase == .idle)
        #expect(result.sessionID == nil)
    }

    @Test("durably queued audio returns directly to ready without participant selection")
    func finalizedAndQueuedAudioReturnsToIdle() {
        // Given
        let sessionID = SessionID(rawValue: UUID())
        let recording = RecordingState.recording(
            sessionID: sessionID,
            externalMicrophoneActive: true
        )
        let finalizing = RecorderReducer.reduce(state: recording, event: .manualStop)

        // When
        let result = RecorderReducer.reduce(
            state: finalizing,
            event: .audioFinalizedAndQueued
        )

        // Then
        #expect(result.phase == .idle)
        #expect(result.sessionID == nil)
        #expect(result.externalMicrophoneActive)
        #expect(result.automaticStartSuppressed)
    }

    @Test("discard in failed returns to idle")
    func discardInFailedReturnsToIdle() {
        let state = RecordingState(
            phase: .failed,
            sessionID: SessionID(rawValue: UUID()),
            externalMicrophoneActive: false,
            automaticStartSuppressed: true,
            failure: .transcriptionFailed
        )
        let result = RecorderReducer.reduce(state: state, event: .discard)
        #expect(result.phase == .idle)
        #expect(result.sessionID == nil)
    }

    @Test("discard is ignored during active recording")
    func discardIgnoredDuringRecording() {
        let state = RecordingState.recording(
            sessionID: SessionID(rawValue: UUID()),
            externalMicrophoneActive: true
        )
        let result = RecorderReducer.reduce(state: state, event: .discard)
        #expect(result.phase == .recording)
    }

    @Test("recovering from failure returns to safe idle state")
    func recoverFromFailure() {
        let failed = RecordingState.failed(.captureUnavailable)
        let state = RecorderReducer.reduce(state: failed, event: .recover)
        #expect(state == .idle)
    }

    @Test("recovering from failure ignores a pending background call")
    func recoverFromFailureIgnoresPendingBackgroundCall() {
        // Given
        let failed = RecordingState.failed(.storageUnavailable)
        let pendingCall = PendingBackgroundCall(
            callID: CallID(rawValue: UUID()),
            segments: [],
            destination: URL(filePath: "/tmp/unrelated"),
            endedAt: Date(timeIntervalSince1970: 100)
        )

        // When
        let state = RecorderReducer.reduce(state: failed, event: .recover)

        // Then
        #expect(state.phase == .idle)
        #expect(pendingCall.callID != nil)
    }

    @Test("a new recording can start while unrelated background saves are still pending")
    func recorderStartsWhileBackgroundWorkIsPending() {
        // Given an idle recorder with a prior call's save still finalizing in the background.
        let priorSave = PendingBackgroundCall(
            callID: CallID(rawValue: UUID()),
            segments: [],
            destination: URL(filePath: "/tmp/prior-save"),
            endedAt: Date(timeIntervalSince1970: 100)
        )
        let idle = RecorderReducer.reduce(
            state: RecordingState(
                phase: .finalizing,
                sessionID: SessionID(rawValue: UUID()),
                externalMicrophoneActive: false,
                automaticStartSuppressed: false,
                failure: nil
            ),
            event: .audioFinalizedAndQueued
        )
        #expect(idle.phase == .idle)

        // When a newer recording starts while that background work is still pending.
        let sessionID = SessionID(rawValue: UUID())
        let recording = RecorderReducer.reduce(
            state: idle,
            event: .manualStart(sessionID: sessionID)
        )

        // Then the newer capture is active and untouched by the prior background call.
        #expect(recording.phase == .recording)
        #expect(recording.sessionID == sessionID)
        #expect(priorSave.callID != recording.sessionID.map { CallID(rawValue: $0.rawValue) })
    }
}
