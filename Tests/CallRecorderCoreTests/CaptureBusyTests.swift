import CallRecorderCore
import Testing
@testable import CallRecorderApp

/// The rule that holds a permission change while the audio is in use.
///
/// A reset takes the microphone or Screen Recording from a capture already under way, and a restart
/// ends the call. The two reset guards, the restart guard, and the popover's disabled buttons all
/// read this one rule, so it is held here rather than only looked at in a render.
@Suite("Capture busy rule")
struct CaptureBusyTests {
    @Test("a call being recorded or paused holds a permission change")
    func recordingOrPausedIsBusy() {
        #expect(AppModel.captureIsBusy(phase: .recording, captureInFlight: false, checkBusy: false))
        #expect(AppModel.captureIsBusy(phase: .paused, captureInFlight: false, checkBusy: false))
    }

    @Test("a capture changing hands holds it even while the recorder reads idle")
    func aCaptureTransitionIsBusy() {
        #expect(AppModel.captureIsBusy(phase: .idle, captureInFlight: true, checkBusy: false))
    }

    @Test("a check listening, starting or being put down holds it")
    func aBusyCheckIsBusy() {
        #expect(AppModel.captureIsBusy(phase: .idle, captureInFlight: false, checkBusy: true))
    }

    @Test("an idle recorder with nothing in flight does not hold it")
    func anIdleRecorderIsNotBusy() {
        #expect(!AppModel.captureIsBusy(phase: .idle, captureInFlight: false, checkBusy: false))
        #expect(!AppModel.captureIsBusy(phase: .failed, captureInFlight: false, checkBusy: false))
    }
}
