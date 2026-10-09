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

    @Test("a stop while the microphone prompt is open never leaves a stream running")
    func stoppingDuringThePermissionWaitLeavesNoStream() async {
        let system = ScriptedMicrophoneSystem()
        system.status = .notDetermined
        system.holdPermission = true
        let check = MicrophoneCheck(session: AudioCaptureSession(), system: system)

        let starting = Task { await check.start(deviceID: nil) }
        await system.permissionAwait.enteredAwait()
        let stopping = Task { await check.stop() }
        await system.permissionAwait.cancellationAwait()
        system.permissionAwait.release()
        await stopping.value
        await starting.value

        // The press that opened the prompt was stopped. Nothing it was waiting for may publish a
        // running check or hold the microphone after the stop returned.
        #expect(!check.isRunning)
        #expect(!system.isMonitoring)
    }

    @Test("a stop while the capture is starting never leaves it running")
    func stoppingDuringTheCaptureStartLeavesNoStream() async {
        let system = ScriptedMicrophoneSystem()
        system.status = .authorized
        system.holdCapture = true
        let check = MicrophoneCheck(session: AudioCaptureSession(), system: system)

        let starting = Task { await check.start(deviceID: nil) }
        await system.captureAwait.enteredAwait()
        let stopping = Task { await check.stop() }
        await system.captureAwait.cancellationAwait()
        system.captureAwait.release()
        await stopping.value
        await starting.value

        #expect(!check.isRunning)
        #expect(!system.isMonitoring)
    }

    @Test("two Check presses in a row start one stream")
    func twoCheckPressesStartOneStream() async {
        let system = ScriptedMicrophoneSystem()
        system.status = .authorized
        system.holdCapture = true
        let check = MicrophoneCheck(session: AudioCaptureSession(), system: system)

        let first = Task { await check.start(deviceID: nil) }
        await system.captureAwait.enteredAwait()
        // The second press is proved to have entered before the first start is released.
        let secondEntry = HeldAwait()
        let second = Task {
            secondEntry.release()
            await check.start(deviceID: nil)
        }
        await secondEntry.wait()
        system.captureAwait.release()
        await first.value
        await second.value

        #expect(system.startMonitoringCalls == 1)
        #expect(system.isMonitoring)
        #expect(check.isRunning)
        await check.stop()
    }

    @Test("a stop clears a refusal that no longer applies")
    func stoppingClearsTheRefusal() async {
        let system = ScriptedMicrophoneSystem()
        system.status = .denied
        let check = MicrophoneCheck(session: AudioCaptureSession(), system: system)

        await check.start(deviceID: nil)
        #expect(check.refusal == .permissionDenied)

        await check.stop()
        #expect(check.refusal == nil)
    }

    @Test("two stops share one cleanup and both wait for it")
    func concurrentStopsShareOneCleanup() async {
        let system = ScriptedMicrophoneSystem()
        let check = MicrophoneCheck(session: AudioCaptureSession(), system: system)
        await check.start(deviceID: nil)
        #expect(system.isMonitoring)

        system.holdFinish = true
        let first = Task { await check.stop() }
        await system.finishAwait.enteredAwait()
        // The second stop is proved to have entered, and joined the cleanup, before the held
        // cleanup is released.
        let secondEntry = HeldAwait()
        let second = Task {
            secondEntry.release()
            await check.stop()
        }
        await secondEntry.wait()
        system.finishAwait.release()
        await first.value
        await second.value

        // The second stop joined the first cleanup instead of starting another one.
        #expect(system.finishMonitoringCalls == 1)
        #expect(!check.isRunning)
        #expect(!system.isMonitoring)
    }

    @Test("a start during a delayed cleanup is refused until the stream is down")
    func startDuringCleanupIsRefused() async {
        let system = ScriptedMicrophoneSystem()
        let check = MicrophoneCheck(session: AudioCaptureSession(), system: system)
        await check.start(deviceID: nil)

        system.holdFinish = true
        let stopping = Task { await check.stop() }
        await system.finishAwait.enteredAwait()

        // A press now must not open a second stream while the first is still being put down.
        await check.start(deviceID: nil)
        #expect(system.startMonitoringCalls == 1)
        #expect(!check.isRunning)

        system.finishAwait.release()
        await stopping.value
        #expect(!system.isMonitoring)

        // Once the cleanup has ended, a new check is allowed again.
        await check.start(deviceID: nil)
        #expect(system.startMonitoringCalls == 2)
        await check.stop()
    }

    @Test("a delayed monitor cleanup is finished before the stop returns")
    func stopWaitsForDelayedCleanup() async {
        let system = ScriptedMicrophoneSystem()
        let check = MicrophoneCheck(session: AudioCaptureSession(), system: system)
        await check.start(deviceID: nil)

        system.holdFinish = true
        let stopping = Task { await check.stop() }
        await system.finishAwait.enteredAwait()
        // The stream is still up because the cleanup has not been allowed to answer.
        #expect(system.isMonitoring)
        #expect(system.finishMonitoringCalls == 0)

        system.finishAwait.release()
        await stopping.value
        #expect(system.finishMonitoringCalls == 1)
        #expect(!system.isMonitoring)
        #expect(!check.isRunning)
    }

    @Test("a framework start that succeeds after a stop is closed and never published")
    func lateFrameworkSuccessIsClosed() async {
        let system = ScriptedMicrophoneSystem()
        let check = MicrophoneCheck(session: AudioCaptureSession(), system: system)
        system.holdCapture = true

        let starting = Task { await check.start(deviceID: nil) }
        await system.captureAwait.enteredAwait()
        let stopping = Task { await check.stop() }
        // The handshake proves the stop has cancelled the start before the framework is released.
        await system.captureAwait.cancellationAwait()
        system.captureAwait.release()
        await stopping.value
        await starting.value

        #expect(!check.isRunning)
        #expect(!system.isMonitoring)
        #expect(system.startMonitoringCalls == 1)
        #expect(system.finishMonitoringCalls >= 1)
    }

    @Test("a stop before a refused grant publishes no refusal")
    func stoppedRefusalIsNotPublished() async {
        let system = ScriptedMicrophoneSystem()
        system.status = .notDetermined
        system.grantsAccess = false
        system.holdPermission = true
        let check = MicrophoneCheck(session: AudioCaptureSession(), system: system)

        let starting = Task { await check.start(deviceID: nil) }
        await system.permissionAwait.enteredAwait()
        let stopping = Task { await check.stop() }
        await system.permissionAwait.cancellationAwait()
        system.permissionAwait.release()
        await stopping.value
        await starting.value

        #expect(check.refusal == nil)
        #expect(!check.isRunning)
        #expect(system.startMonitoringCalls == 0)
    }

    @Test("a stop before a granted permission never opens the capture")
    func stoppedPermissionGrantNeverStartsMonitoring() async {
        let system = ScriptedMicrophoneSystem()
        system.status = .notDetermined
        system.grantsAccess = true
        system.holdPermission = true
        let check = MicrophoneCheck(session: AudioCaptureSession(), system: system)

        let starting = Task { await check.start(deviceID: nil) }
        await system.permissionAwait.enteredAwait()
        let stopping = Task { await check.stop() }
        await system.permissionAwait.cancellationAwait()
        system.permissionAwait.release()
        await stopping.value
        await starting.value

        #expect(system.startMonitoringCalls == 0)
        #expect(!check.isRunning)
        #expect(check.refusal == nil)
    }
}

/// A held await: a call the injected system makes, kept open so a stop can arrive inside it.
///
/// A check waits for the grant and for the capture, and the races this suite is about live in those
/// two windows. Each wait is held here until the test releases it.
@MainActor
final class HeldAwait {
    private var entered: [CheckedContinuation<Void, Never>] = []
    private var released: [CheckedContinuation<Void, Never>] = []
    private var cancelled: [CheckedContinuation<Void, Never>] = []
    private var hasEntered = false
    private var isReleased = false
    private var isCancelled = false

    /// Suspends the held call until the test releases it, then answers at once once released.
    ///
    /// Cancellation is observed but does not end the wait, which is how a framework start that
    /// answers after its task was cancelled is modelled.
    func wait() async {
        hasEntered = true
        let waiting = entered
        entered = []
        for continuation in waiting { continuation.resume() }
        await withTaskCancellationHandler {
            guard !isReleased else { return }
            await withCheckedContinuation { released.append($0) }
        } onCancel: {
            Task { @MainActor in self.noteCancellation() }
        }
    }

    private func noteCancellation() {
        guard !isCancelled else { return }
        isCancelled = true
        let waiting = cancelled
        cancelled = []
        for continuation in waiting { continuation.resume() }
    }

    /// Waits until the held call has entered.
    func enteredAwait() async {
        guard !hasEntered else { return }
        await withCheckedContinuation { entered.append($0) }
    }

    /// Waits until the held call has been cancelled, which proves a stop has entered it.
    func cancellationAwait() async {
        guard !isCancelled else { return }
        await withCheckedContinuation { cancelled.append($0) }
    }

    /// Lets the held call answer.
    func release() {
        isReleased = true
        let waiting = released
        released = []
        for continuation in waiting { continuation.resume() }
    }
}

/// The grant, the capture, and the cleanup a test drives, with any of the three holdable.
@MainActor
final class ScriptedMicrophoneSystem: MicrophoneCheckSystem {
    var status: AVAuthorizationStatus = .authorized
    var grantsAccess = true
    var holdPermission = false
    var holdCapture = false
    var holdFinish = false
    let permissionAwait = HeldAwait()
    let captureAwait = HeldAwait()
    let finishAwait = HeldAwait()

    private(set) var startMonitoringCalls = 0
    private(set) var finishMonitoringCalls = 0
    private(set) var isMonitoring = false

    func authorizationStatus() -> AVAuthorizationStatus { status }

    func requestAccess() async -> Bool {
        if holdPermission { await permissionAwait.wait() }
        return grantsAccess
    }

    func startMonitoring(microphoneDeviceID: String?) async throws {
        if holdCapture { await captureAwait.wait() }
        startMonitoringCalls += 1
        isMonitoring = true
    }

    func finishMonitoring() async {
        if holdFinish { await finishAwait.wait() }
        finishMonitoringCalls += 1
        isMonitoring = false
    }
}
