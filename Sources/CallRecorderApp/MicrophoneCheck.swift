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
    @ObservationIgnored private var stopTask: Task<Void, Never>?

    init(session: AudioCaptureSession) {
        self.session = session
    }

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
        guard !isRunning else { return }
        refusal = nil
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            // The prompt belongs to the press: a settings row that opens the microphone without
            // asking is a row that has no business opening it.
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                refusal = .permissionDenied
                return
            }
        default:
            refusal = .permissionDenied
            return
        }
        do {
            try await session.startMonitoring(microphoneDeviceID: deviceID)
        } catch {
            refusal = Self.refusal(for: error)
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
    func stop() async {
        stopTask?.cancel()
        stopTask = nil
        isRunning = false
        endsAt = nil
        await session.finishMonitoring()
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
