import AVFoundation
import CoreAudio
import CoreMedia
import Foundation
import OSLog
import ScreenCaptureKit

struct CapturedAudioSource: Codable, Equatable, Sendable {
    let fileURL: URL
    let firstPresentationSeconds: Double
    let durationSeconds: Double
    /// Samples the encoder could not take in time, when there were any.
    ///
    /// Optional so a manifest written before this was counted still reads. A drop is a few
    /// milliseconds of audio and the recording carries on: the number is here to say whether a
    /// call lost anything, which is otherwise invisible.
    var droppedSamples: Int? = nil
}

struct CaptureSourcePaths: Equatable, Sendable {
    let system: URL
    let microphone: URL
}

struct CaptureSegment: Codable, Equatable, Sendable {
    let index: Int
    let system: CapturedAudioSource?
    let microphone: CapturedAudioSource?

    init(index: Int, fileURL: URL) {
        self.index = index
        system = CapturedAudioSource(
            fileURL: fileURL,
            firstPresentationSeconds: 0,
            durationSeconds: 0
        )
        microphone = nil
    }

    init(
        index: Int,
        system: CapturedAudioSource?,
        microphone: CapturedAudioSource?
    ) throws {
        guard system != nil || microphone != nil else { throw AudioCaptureError.noAudio }
        self.index = index
        self.system = system
        self.microphone = microphone
    }

    static func paths(in directory: URL, index: Int) -> CaptureSourcePaths {
        let suffix = String(format: "%03d", index)
        return CaptureSourcePaths(
            system: directory.appending(path: "system-\(suffix).m4a"),
            microphone: directory.appending(path: "microphone-\(suffix).m4a")
        )
    }

    var hasRecoverableAudio: Bool { system != nil || microphone != nil }

    var fileURL: URL {
        if let system { return system.fileURL }
        if let microphone { return microphone.fileURL }
        preconditionFailure("CaptureSegment requires at least one audio source")
    }
}

struct AudioInputDevice: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
}

enum AudioCaptureError: Error {
    case alreadyCapturing
    case notCapturing
    case noDisplay
    case noMicrophone
    case noAudio
}

/// What each refusal says where a person reads it.
///
/// A Swift error with no description reaches the popover as "The operation couldn't be completed",
/// which names neither the cause nor what to do about it. Each case here is one sentence a person
/// can act on.
extension AudioCaptureError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .alreadyCapturing:
            "A recording is already running."
        case .notCapturing:
            "No recording is running."
        case .noDisplay:
            "No display was found to capture the call's audio through."
        case .noMicrophone:
            "No microphone is connected. Turn on Settings, General, Record when there is no "
                + "microphone to record the other side without one."
        case .noAudio:
            "The capture produced no audio."
        }
    }
}

@MainActor
final class AudioCaptureSession {
    nonisolated private static let builtInMicrophoneID = "BuiltInMicrophoneDevice"

    /// The choice that follows the microphone macOS is set to use.
    ///
    /// A saved choice is a device identifier. That is right for "always record on the built-in
    /// microphone" and wrong for "record on whatever I have selected in the system", because that
    /// decision belongs to whoever picks up the headset before the call. This identifier is not a
    /// device: it is the instruction to ask the system when a recording starts, and it is spelled
    /// like the built-in microphone's so the two can sit in one menu.
    nonisolated static let systemMicrophoneID = "SystemDefaultMicrophoneDevice"

    private struct ActiveCapture {
        let stream: SCStream
        let router: AudioCaptureRouter
        let index: Int
    }

    private var activeCapture: ActiveCapture?

    /// What the capture hears, read by the model while a recording runs.
    ///
    /// One meter for the session rather than one per segment: the segments are one recording, and a
    /// rail that reads it does not care which file the audio is being written to.
    let levels = AudioLevelMeter()

    static func availableMicrophones() -> [AudioInputDevice] {
        captureDevices().map {
            AudioInputDevice(id: $0.uniqueID, name: $0.localizedName)
        }
    }

    nonisolated static func resolvedMicrophoneID(
        availableIDs: [String],
        selectedID: String?,
        systemDefaultID: String? = nil
    ) -> String? {
        // The system can be set to a device that has since been unplugged, and it can be set to
        // one this app cannot open. Either way the choice has been made, so it falls through to
        // the built-in microphone below rather than leaving the recorder with nothing.
        if selectedID == systemMicrophoneID,
            let systemDefaultID,
            availableIDs.contains(systemDefaultID) {
            return systemDefaultID
        }
        if let selectedID, availableIDs.contains(selectedID) { return selectedID }
        if availableIDs.contains(builtInMicrophoneID) { return builtInMicrophoneID }
        return availableIDs.first
    }

    /// The identifier of the microphone macOS is set to use, in the form the device list uses.
    ///
    /// The system's choice is a Core Audio device, and the device list this app records from is
    /// built from AVCaptureDevice. The Core Audio device's UID is the identifier both of them
    /// answer to, which was measured on this machine: the default input device reports
    /// 34-0E-22-81-A2-53:input, and the capture device with that identifier is the same headset.
    nonisolated static func systemDefaultMicrophoneID() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(0)
        var deviceSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &deviceSize,
                &device
            ) == noErr,
            device != kAudioObjectUnknown
        else { return nil }

        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: CFString?
        var uidSize = UInt32(MemoryLayout<CFString?>.size)
        let read = withUnsafeMutablePointer(to: &uid) { pointer in
            AudioObjectGetPropertyData(
                device,
                &uidAddress,
                0,
                nil,
                &uidSize,
                UnsafeMutableRawPointer(pointer)
            )
        }
        guard read == noErr, let uid else { return nil }
        return uid as String
    }

    /// What the system choice is called in the menu, naming the device it points at today.
    ///
    /// Without the name the choice says nothing a person can check: the point of following the
    /// system is lost if the row does not say which microphone that currently is.
    nonisolated static func systemChoiceName(
        systemDefaultID: String?,
        devices: [AudioInputDevice]
    ) -> String {
        guard let systemDefaultID, let device = devices.first(where: { $0.id == systemDefaultID })
        else { return "System default" }
        return "System (" + device.name + ")"
    }


    /// The built-in microphone is a fixed device identifier, so it can be named plainly.
    nonisolated static func displayName(for device: AudioInputDevice) -> String {
        device.id == builtInMicrophoneID ? "\(device.name) (Built-in)" : device.name
    }

    /// Bluetooth headsets switch to a low-quality call mode, so the settings screen warns
    /// when one is selected instead of letting the recording quality drop quietly.
    nonisolated static func isBluetooth(_ device: AudioInputDevice) -> Bool {
        let name = device.name.lowercased()
        let markers = ["airpods", "bluetooth", "beats", "buds", "headset", "wh-", "wf-"]
        return markers.contains { name.contains($0) }
    }

    nonisolated static func isAlreadyStoppedError(_ error: any Error) -> Bool {
        let cocoaError = error as NSError
        return cocoaError.domain == SCStreamErrorDomain && cocoaError.code == -3_808
    }

    nonisolated static func isScreenRecordingPermissionDeniedError(_ error: any Error) -> Bool {
        let cocoaError = error as NSError
        return cocoaError.domain == SCStreamErrorDomain && cocoaError.code == -3_801
    }

    /// The microphone a segment records from, or nothing when the Mac has no audio input.
    ///
    /// A Mac mini can legitimately have no input at all. ScreenCaptureKit records the call's system
    /// audio on its own, so a missing microphone is one source fewer rather than a broken
    /// recording. `allowsMissingMicrophone` is the setting that asks for the older refusal, and it
    /// is the only thing that turns an absent device into an error.
    nonisolated static func chosenMicrophoneID(
        availableIDs: [String],
        selectedID: String?,
        systemDefaultID: String? = nil,
        allowsMissingMicrophone: Bool
    ) throws -> String? {
        let resolvedID = resolvedMicrophoneID(
            availableIDs: availableIDs,
            selectedID: selectedID,
            systemDefaultID: systemDefaultID
        )
        guard resolvedID == nil else { return resolvedID }
        guard allowsMissingMicrophone else { throw AudioCaptureError.noMicrophone }
        return nil
    }

    private static func microphone(
        deviceID: String?,
        allowsMissingMicrophone: Bool
    ) throws -> AVCaptureDevice? {
        let devices = captureDevices()
        let resolvedID = try chosenMicrophoneID(
            availableIDs: devices.map(\.uniqueID),
            selectedID: deviceID,
            systemDefaultID: systemDefaultMicrophoneID(),
            allowsMissingMicrophone: allowsMissingMicrophone
        )
        return devices.first(where: { $0.uniqueID == resolvedID })
    }

    private static func captureDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        ).devices
    }

    func startSegment(
        directory: URL,
        index: Int,
        microphoneDeviceID: String?,
        allowsMissingMicrophone: Bool,
        liveTap: LiveAudioTap? = nil
    ) async throws -> CaptureSourcePaths {
        guard activeCapture == nil else { throw AudioCaptureError.alreadyCapturing }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let paths = CaptureSegment.paths(in: directory, index: index)
        // Silence is measured from the moment this segment delivers audio, so a pause does not
        // count as quiet.
        levels.reset()

        let content = try await SCShareableContent.currentProcess
        guard let display = content.displays.first else { throw AudioCaptureError.noDisplay }
        let ownApplication = content.applications.filter {
            $0.processID == ProcessInfo.processInfo.processIdentifier
        }
        let filter = SCContentFilter(
            display: display,
            excludingApplications: ownApplication,
            exceptingWindows: []
        )
        let configuration = SCStreamConfiguration()
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(seconds: 1, preferredTimescale: 1)
        configuration.queueDepth = 3
        configuration.showsCursor = false
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        // The microphone is optional when the setting allows it: ScreenCaptureKit records the
        // call's system audio on its own. If an input appears later, the next segment resolves it
        // again and includes it automatically, so a headset plugged in mid-call is picked up.
        let microphone = try Self.microphone(
            deviceID: microphoneDeviceID,
            allowsMissingMicrophone: allowsMissingMicrophone
        )
        configuration.captureMicrophone = microphone != nil
        configuration.microphoneCaptureDeviceID = microphone?.uniqueID

        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        let router = AudioCaptureRouter(paths: paths, levels: levels, liveTap: liveTap)
        try stream.addStreamOutput(
            router,
            type: .audio,
            sampleHandlerQueue: router.systemQueue
        )
        if microphone != nil {
            try stream.addStreamOutput(
                router,
                type: .microphone,
                sampleHandlerQueue: router.microphoneQueue
            )
        }
        do {
            try await stream.startCapture()
            activeCapture = ActiveCapture(
                stream: stream,
                router: router,
                index: index
            )
            return paths
        } catch {
            router.cancel()
            throw error
        }
    }

    func finishSegment() async throws -> CaptureSegment {
        guard let activeCapture else { throw AudioCaptureError.notCapturing }
        defer { self.activeCapture = nil }
        try await Self.stop(activeCapture.stream, within: Self.stopTimeoutSeconds)
        return try await activeCapture.router.finish(index: activeCapture.index)
    }

    /// How long the stop of a capture stream may take before the segment is closed without it.
    ///
    /// A normal stop answers in well under a second. A stop that never answers holds the two audio
    /// writers open, and a writer that is never finished leaves an m4a with no index at all: the
    /// audio is on disk and nothing can read it. The 2026-09-21 14:02 recording is an hour and
    /// twelve minutes in exactly that state, and the phase it left the app in reads "Writing the
    /// audio file" while nothing writes anything. Closing the segment is always the better answer:
    /// it costs the last seconds of the call, and the alternative is all of it.
    static let stopTimeoutSeconds: Double = 15

    /// Stops a stream, or gives up waiting for the answer.
    ///
    /// The stop is raced against a timer. When the timer wins, the stream is left to the system —
    /// nothing is reading from it any more — and the segment is finished anyway, which is what
    /// writes the index of everything already recorded. An error the stop reports itself still
    /// comes back, except the "already stopped" answer a second stop returns.
    private static func stop(_ stream: SCStream, within seconds: Double) async throws {
        // The stop runs in its own task and the timer in another, and both are waited for on this
        // one: SCStream is not Sendable, which is why the reference is handed over unchecked here
        // and nowhere else.
        nonisolated(unsafe) let stream = stream
        let stop = Task { try await stream.stopCapture() }
        let answered = await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask {
                _ = try? await stop.value
                return true
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return false
            }
            let first = await group.next() ?? true
            group.cancelAll()
            return first
        }
        guard answered else {
            stop.cancel()
            Logger(subsystem: "local.callrecorder.app", category: "capture")
                .notice(
                    "the capture stream did not confirm its stop within \(Int(seconds), privacy: .public) s; the segment was closed anyway"
                )
            return
        }
        do {
            try await stop.value
        } catch {
            guard Self.isAlreadyStoppedError(error) else { throw error }
        }
    }
}
