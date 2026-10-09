import AVFoundation
import CallRecorderCore
import Foundation
import Observation

/// A short listen to one microphone, so Settings can show what the recorder hears.
///
/// While a recording runs the level row draws the capture's own microphone track. With nothing
/// being recorded there is nothing to draw, and the question "does it hear me" is asked before the
/// call rather than during it. This runs the recorder's own capture for a bounded time with
/// nothing written: the same stream, the same device choice, and the same meter, so what a check
/// shows is what a recording will show.
///
/// It used to open the microphone through AVAudioEngine, and that is why this one exists. Naming a
/// device on the engine's input unit stopped it delivering buffers altogether, measured on
/// 2026-10-08: fifteen buffers in two seconds with no device named, and none at all with the
/// microphone a recording would use. The check showed a dead bar while the recording itself
/// worked, which is worse than having no check at all.
@MainActor
@Observable
final class MicrophoneCheck {
    /// How long one listen runs.
    ///
    /// Long enough to say a sentence and watch the bar answer, short enough that a check nobody is
    /// watching puts the microphone down by itself.
    static let duration: TimeInterval = 20

    /// The pane that holds the microphone switch, so the refusal can open it.
    static let settingsURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"

    /// What a check that could not listen says, and whether System Settings is the way out.
    enum Refusal: Equatable {
        /// macOS has not granted the microphone to this copy of the app.
        case permissionDenied
        /// No audio input is connected at all.
        case noMicrophone
        /// The other permission this app cannot capture without is not granted.
        case screenRecordingRefused
        /// The capture could not start, carrying what the framework said about it.
        case captureUnavailable(String)

        var message: String {
            switch self {
            case .permissionDenied:
                "macOS has not granted the microphone to Call Recorder, so nothing can listen. "
                    + "Turn it on in System Settings, Privacy and Security, Microphone, then "
                    + "start the app again."
            case .noMicrophone:
                "No microphone is connected, so there is nothing to listen to. Plug one in and "
                    + "it joins the menu on its own."
            case .screenRecordingRefused:
                "The check uses the same capture a recording uses, and Screen Recording is not "
                    + "granted. Turn Call Recorder on in System Settings, Privacy and Security, "
                    + "Screen Recording, then start the app again."
            case .captureUnavailable(let detail):
                "The microphone could not be opened. " + detail
            }
        }

        var opensMicrophoneSettings: Bool {
            switch self {
            case .permissionDenied, .noMicrophone: return true
            default: return false
            }
        }
    }

    private(set) var isRunning = false
    private(set) var refusal: Refusal?
    private var endsAt: Date?

    @ObservationIgnored private let session: AudioCaptureSession
    /// The grant and the capture, handed in so a start that is held open can be stopped in a test.
    @ObservationIgnored private let system: any MicrophoneCheckSystem
    /// The start that is still asking, and the one cleanup a stop leaves behind.
    ///
    /// A start waits twice before it can listen, so a press during either wait must not open a
    /// second stream, and a press during a cleanup must not open one at all. Both are read by the
    /// surfaces that hold a permission change, so neither is hidden from observation.
    private var pendingStart: Task<Void, Never>?
    private var stopping: Task<Void, Never>?
    @ObservationIgnored private var stopTask: Task<Void, Never>?

    init(session: AudioCaptureSession, system: (any MicrophoneCheckSystem)? = nil) {
        self.session = session
        self.system = system ?? LiveMicrophoneCheckSystem(session: session)
    }

    /// Whether a listen is running, still being started, or still being put down.
    var isBusy: Bool { isRunning || pendingStart != nil || stopping != nil }

    /// What the microphone is delivering right now, or nil when nothing is being listened to.
    func currentDecibels() -> Double? {
        guard isRunning else { return nil }
        return session.microphoneLevels.currentDecibels()
    }

    /// The whole seconds left of a running check, for the row's countdown.
    func secondsRemaining(now: Date = Date()) -> Int? {
        guard let endsAt else { return nil }
        return max(0, Int(endsAt.timeIntervalSince(now).rounded(.up)))
    }

    /// Starts a listen, or reports why it cannot.
    ///
    /// A device identifier names one device; nothing means "follow whatever macOS is set to use",
    /// which is the same instruction the recorder takes when the menu says System.
    func start(deviceID: String?) async {
        // One start at a time: a press while a start is still asking, or while a stop is still
        // putting the last one down, does not open a second stream.
        guard stopping == nil, pendingStart == nil, !isRunning else { return }
        refusal = nil
        let start = Task { [weak self] in _ = await self?.run(deviceID: deviceID) }
        pendingStart = start
        await start.value
    }

    /// The start work, in its own task so a stop can cancel it and wait for it to finish.
    ///
    /// Cancellation is checked after each wait. A stop that arrives inside a wait makes the start
    /// give up rather than publish a running check, and a stream that was already opened before the
    /// stop is put down here rather than left for anyone else to find.
    private func run(deviceID: String?) async {
        defer { pendingStart = nil }
        switch system.authorizationStatus() {
        case .authorized:
            break
        case .notDetermined:
            // The prompt belongs to the press: a settings row that opens the microphone without
            // asking is a row that has no business opening it.
            guard await system.requestAccess() else {
                guard !Task.isCancelled else { return }
                refusal = .permissionDenied
                return
            }
        default:
            refusal = .permissionDenied
            return
        }
        guard !Task.isCancelled else { return }
        do {
            try await system.startMonitoring(microphoneDeviceID: deviceID)
        } catch {
            guard !Task.isCancelled else { return }
            refusal = Self.refusal(for: error)
            return
        }
        guard !Task.isCancelled else {
            await system.finishMonitoring()
            return
        }
        isRunning = true
        endsAt = Date().addingTimeInterval(Self.duration)
        stopTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.duration))
            guard !Task.isCancelled else { return }
            await self?.stop()
        }
    }

    /// Puts the microphone down, whatever state the check is in.
    ///
    /// Every stop joins the one cleanup already running, so two stops wait for the same work and a
    /// start pressed meanwhile is refused until the stream is down.
    func stop() async {
        stopTask?.cancel()
        stopTask = nil
        if let stopping {
            await stopping.value
            return
        }
        let start = pendingStart
        start?.cancel()
        let cleanup = Task { [weak self] in
            // The cancelled start is waited for first: a framework start may still succeed after
            // the cancellation, and the stream it opened must be closed before this cleanup ends.
            _ = await start?.value
            guard let self else { return }
            self.isRunning = false
            self.endsAt = nil
            self.refusal = nil
            await self.system.finishMonitoring()
            // Cleared last, so a start pressed during teardown is refused until the stream is down.
            self.pendingStart = nil
            self.stopping = nil
        }
        stopping = cleanup
        await cleanup.value
    }

    /// What stopped a check, said as the one thing a person can act on.
    ///
    /// The sentences live here rather than in the row so the classification can be checked: a
    /// missing microphone and a refused permission both read as "nothing to listen to", and
    /// telling them apart is what decides whether the row opens System Settings.
    static func refusal(for error: any Error) -> Refusal {
        if let captureError = error as? AudioCaptureError, case .noMicrophone = captureError {
            return .noMicrophone
        }
        if AudioCaptureSession.isScreenRecordingPermissionDeniedError(error) {
            return .screenRecordingRefused
        }
        return .captureUnavailable(error.localizedDescription)
    }

    /// Whether a failure still describes this moment, given what is connected.
    ///
    /// A check that found nothing to listen to is an answer about the device list it was measured
    /// against. A headset connected afterwards is not described by it, and the row went on saying
    /// no microphone was connected while the menu above it offered one (2026-10-09). Everything
    /// else is a state of the permissions or the capture, which a device joining the menu does not
    /// settle.
    static func describesCurrentState(_ refusal: Refusal, hasMicrophone: Bool) -> Bool {
        switch refusal {
        case .noMicrophone: return !hasMicrophone
        default: return true
        }
    }
}

/// What a check asks of the system: the microphone grant, and the capture it listens through.
///
/// A check waits twice, once for the grant and once for the capture to answer, and a stop can
/// arrive while either is outstanding. Those two waits are the only things handed in here; the
/// start and stop above them, where the races live, stay the production ones.
@MainActor
protocol MicrophoneCheckSystem: AnyObject {
    /// Whether macOS has granted this copy of the app the microphone.
    func authorizationStatus() -> AVAuthorizationStatus
    /// Asks for the microphone, and answers whether it was granted.
    func requestAccess() async -> Bool
    /// Opens the recorder's own capture, measuring the microphone and writing nothing.
    func startMonitoring(microphoneDeviceID: String?) async throws
    /// Puts the capture down.
    func finishMonitoring() async
}

/// The system behind a real check: the microphone grant, and the recorder's own capture.
@MainActor
final class LiveMicrophoneCheckSystem: MicrophoneCheckSystem {
    private let session: AudioCaptureSession

    init(session: AudioCaptureSession) {
        self.session = session
    }

    func authorizationStatus() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    func startMonitoring(microphoneDeviceID: String?) async throws {
        try await session.startMonitoring(microphoneDeviceID: microphoneDeviceID)
    }

    func finishMonitoring() async {
        await session.finishMonitoring()
    }
}
