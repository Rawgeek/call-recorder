import AVFoundation
import AudioToolbox
import CallRecorderCore
import Foundation
import Observation

/// A short listen to one microphone, so Settings can show what it hears before a call starts.
///
/// While a recording runs the level row draws what the capture is delivering. With nothing being
/// recorded there is nothing to draw, and the question "does it hear me" is asked before the call,
/// not during it. This opens the chosen device for a bounded time and measures it: nothing is
/// recorded, nothing is written anywhere, and the number dies with the check.
///
/// The device is opened through the microphone permission a recording already uses, so a Mac that
/// can record can check. When macOS has not granted it, the check says so rather than drawing an
/// empty bar, which would read as a microphone that hears nothing.
@MainActor
@Observable
final class MicrophoneCheck {
    /// How long one listen runs.
    ///
    /// Long enough to say a sentence and watch the bar answer, short enough that a check nobody is
    /// watching puts the microphone down by itself.
    static let duration: TimeInterval = 20

    /// The pane that holds the microphone switch, so the row can open it.
    static let settingsURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"

    /// What a check that could not listen says, and whether System Settings is the way out.
    enum Refusal: Equatable {
        /// macOS has not granted the microphone to this copy of the app.
        case permissionDenied
        /// The device could not be opened, carrying what the audio system said about it.
        case deviceUnavailable(String)

        var message: String {
            switch self {
            case .permissionDenied:
                "macOS has not granted the microphone to Call Recorder, so nothing can listen. "
                    + "Turn it on in System Settings, Privacy and Security, Microphone, then "
                    + "start the app again."
            case .deviceUnavailable(let detail):
                "The microphone could not be opened. " + detail
            }
        }

        var opensMicrophoneSettings: Bool {
            if case .permissionDenied = self { return true }
            return false
        }
    }

    private(set) var isRunning = false
    private(set) var refusal: Refusal?

    @ObservationIgnored private let meter = AudioLevelMeter()
    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var stopTask: Task<Void, Never>?
    @ObservationIgnored private var endsAt: Date?

    /// What the microphone is delivering right now, or nil when nothing is being listened to.
    func currentDecibels() -> Double? {
        guard isRunning else { return nil }
        return meter.currentDecibels()
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
    func start(deviceID: String?) {
        guard !isRunning else { return }
        refusal = nil
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            begin(deviceID: deviceID)
        case .notDetermined:
            // The prompt belongs to the press: a settings row that opens the microphone without
            // asking is a row that has no business opening it.
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if granted {
                        self.begin(deviceID: deviceID)
                    } else {
                        self.refusal = .permissionDenied
                    }
                }
            }
        default:
            refusal = .permissionDenied
        }
    }

    /// Puts the microphone down, whatever state the check is in.
    func stop() {
        stopTask?.cancel()
        stopTask = nil
        if let engine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        engine = nil
        isRunning = false
        endsAt = nil
    }

    private func begin(deviceID: String?) {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        // A choice that names a device is handed to Core Audio by name. A choice that has since
        // been unplugged falls through to the system's own device, which is where the recorder
        // would also land.
        if let deviceID, let device = AudioCaptureSession.audioDeviceID(forUID: deviceID),
           let unit = input.audioUnit {
            var address = device
            let status = AudioUnitSetProperty(
                unit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &address,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            guard status == noErr else {
                refusal = .deviceUnavailable(
                    "The audio system answered (status) when it was selected."
                )
                return
            }
        }
        let format = input.outputFormat(forBus: 0)
        // A device that is there but delivering no format is the shape a missing grant takes, and
        // it is the shape an input with nothing behind it takes too. Both are said rather than
        // drawn as a bar that never moves.
        guard format.channelCount > 0, format.sampleRate > 0 else {
            refusal = .deviceUnavailable(
                "macOS is delivering no input from it. Check the device in System Settings, "
                    + "Sound, Input."
            )
            return
        }
        let meter = self.meter
        input.installTap(onBus: 0, bufferSize: 4_096, format: format) { @Sendable buffer, _ in
            guard let peak = Self.peak(of: buffer) else { return }
            meter.observe(peak: peak)
        }
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            refusal = .deviceUnavailable(error.localizedDescription)
            return
        }
        self.engine = engine
        meter.reset()
        isRunning = true
        endsAt = Date().addingTimeInterval(Self.duration)
        stopTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.duration))
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }

    /// The loudest sample in one buffer of input audio, or nil when it is not float PCM.
    ///
    /// Every fourth sample, as the capture's meter does: a peak is not improved by reading all of
    /// them, and this runs on the audio thread.
    nonisolated private static func peak(of buffer: AVAudioPCMBuffer) -> Float? {
        guard let channels = buffer.floatChannelData else { return nil }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return nil }
        var peak: Float = 0
        for channel in 0..<Int(buffer.format.channelCount) {
            let samples = channels[channel]
            var index = 0
            while index < frames {
                let value = abs(samples[index])
                if value > peak { peak = value }
                index += 4
            }
        }
        return peak
    }
}
