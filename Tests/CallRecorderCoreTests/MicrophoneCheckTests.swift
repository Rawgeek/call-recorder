import AVFoundation
import Foundation
import Testing
@testable import CallRecorderApp

/// What the level row says when the microphone cannot be listened to.
///
/// The check runs the recorder's own capture, so what stops it is what stops a recording: a
/// permission, a missing device, or the framework refusing the stream. The classification decides
/// whether the row offers the switch that fixes it, so the sentences are held here rather than
/// only looked at in a render.
@Suite("Microphone check")
@MainActor
struct MicrophoneCheckTests {
    @Test("a Mac with no input is answered as a missing microphone")
    func noMicrophoneIsNamed() {
        let refusal = MicrophoneCheck.refusal(for: AudioCaptureError.noMicrophone)

        #expect(refusal == .noMicrophone)
        #expect(refusal.message.contains("No microphone"))
        // The menu follows the audio system, so the sentence says where another one would come
        // from rather than sending the person to a setting that does not exist.
        #expect(refusal.message.contains("joins the menu"))
        #expect(refusal.opensMicrophoneSettings)
    }

    @Test("a refused Screen Recording grant is answered with the pane that carries it")
    func screenRecordingRefusalIsNamed() {
        // The check captures through ScreenCaptureKit, so a Mac that has not granted Screen
        // Recording cannot be checked either, and "the microphone could not be opened" would send
        // the person to the wrong pane.
        let denied = NSError(
            domain: "com.apple.ScreenCaptureKit.SCStreamErrorDomain",
            code: -3_801
        )

        let refusal = MicrophoneCheck.refusal(for: denied)

        #expect(refusal == .screenRecordingRefused)
        #expect(refusal.message.contains("Screen Recording"))
        #expect(!refusal.opensMicrophoneSettings)
    }

    @Test("anything else keeps what the framework said")
    func otherFailuresKeepTheirDetail() {
        let failure = NSError(
            domain: "com.apple.AVFoundation",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "The device is in use."]
        )

        let refusal = MicrophoneCheck.refusal(for: failure)

        #expect(refusal == .captureUnavailable("The device is in use."))
        #expect(refusal.message.contains("The device is in use."))
        #expect(!refusal.opensMicrophoneSettings)
    }

    @Test("a refused microphone grant names the pane that carries the switch")
    func permissionRefusalNamesTheSwitch() {
        let refusal = MicrophoneCheck.Refusal.permissionDenied

        #expect(refusal.message.contains("Microphone"))
        #expect(refusal.opensMicrophoneSettings)
        #expect(MicrophoneCheck.settingsURL.contains("Privacy_Microphone"))
    }

    @Test("an idle check listens to nothing and counts nothing")
    func anIdleCheckAnswersNothing() async {
        let session = AudioCaptureSession()
        let check = MicrophoneCheck(session: session)

        #expect(!check.isRunning)
        #expect(check.refusal == nil)
        #expect(check.currentDecibels() == nil)
        #expect(check.secondsRemaining() == nil)
        // Stopping something that is not running is an answer rather than a fault: the row calls
        // this when it leaves the screen whether a check was running or not.
        await check.stop()
        #expect(!check.isRunning)
    }

    @Test("one listen is bounded, so a check nobody watches puts the microphone down")
    func theListenIsBounded() {
        #expect(MicrophoneCheck.duration > 5)
        #expect(MicrophoneCheck.duration <= 60)
    }
}

