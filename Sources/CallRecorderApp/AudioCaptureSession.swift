import AVFoundation
import CoreAudio
import CoreMedia
import Foundation
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

struct MicrophoneCapturePlan: Equatable, Sendable {
    let capturesMicrophone: Bool
    /// `nil` deliberately asks ScreenCaptureKit to follow the system-default microphone.
    let deviceID: String?
}

enum AudioCaptureError: LocalizedError {
    case alreadyCapturing
    case notCapturing
    case noDisplay
    case noMicrophone
    case noAudio

    var errorDescription: String? {
        switch self {
        case .alreadyCapturing:
            "Audio capture is already running."
        case .notCapturing:
            "Audio capture is not running."
        case .noDisplay:
            "No display is available for system-audio capture."
        case .noMicrophone:
            "No audio arrived from the selected microphone. Reconnect your headset or choose a microphone in Settings, then try again."
        case .noAudio:
            "No audio arrived from the microphone or the system."
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
        // An explicit available choice wins. An unset, system-default, or stale choice follows
        // Core Audio first; only when that answer is unavailable does the display helper fall back
        // to the built-in/first device. Capture itself uses `microphoneCapturePlan`, because
        // ScreenCaptureKit can follow the system route directly without pinning a discovery result.
        if let selectedID,
           selectedID != systemMicrophoneID,
           availableIDs.contains(selectedID) { return selectedID }
        if let systemDefaultID, availableIDs.contains(systemDefaultID) { return systemDefaultID }
        if availableIDs.contains(builtInMicrophoneID) { return builtInMicrophoneID }
        return availableIDs.first
    }

    /// How ScreenCaptureKit should route microphone audio for this recording.
    ///
    /// Its API follows the system default when `microphoneCaptureDeviceID` is nil. That matters on
    /// a Mac mini: an unset preference used to pick the first discovery result, which can be an
    /// inactive Continuity or Bluetooth input rather than the AirPods selected in macOS.
    nonisolated static func microphoneCapturePlan(
        availableIDs: [String],
        selectedID: String?,
        systemDefaultID: String?
    ) -> MicrophoneCapturePlan {
        let hasInput = !availableIDs.isEmpty || systemDefaultID != nil
        guard hasInput else {
            return MicrophoneCapturePlan(capturesMicrophone: false, deviceID: nil)
        }
        if let selectedID,
           selectedID != systemMicrophoneID,
           availableIDs.contains(selectedID) {
            return MicrophoneCapturePlan(capturesMicrophone: true, deviceID: selectedID)
        }
        return MicrophoneCapturePlan(capturesMicrophone: true, deviceID: nil)
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
        microphoneDeviceID: String?
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
        // A Mac mini can legitimately have no audio input at all. ScreenCaptureKit can still
        // record the call's system audio, so the absent microphone is an optional source rather
        // than a reason to reject the whole recording. If an input appears later, the next segment
        // resolves it again and includes it automatically.
        let microphonePlan = Self.microphoneCapturePlan(
            availableIDs: Self.captureDevices().map(\.uniqueID),
            selectedID: microphoneDeviceID,
            systemDefaultID: Self.systemDefaultMicrophoneID()
        )
        configuration.captureMicrophone = microphonePlan.capturesMicrophone
        configuration.microphoneCaptureDeviceID = microphonePlan.deviceID

        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        let router = AudioCaptureRouter(paths: paths, levels: levels)
        try stream.addStreamOutput(
            router,
            type: .audio,
            sampleHandlerQueue: router.systemQueue
        )
        if microphonePlan.capturesMicrophone {
            try stream.addStreamOutput(
                router,
                type: .microphone,
                sampleHandlerQueue: router.microphoneQueue
            )
        }
        var streamStarted = false
        do {
            try await stream.startCapture()
            streamStarted = true
            if microphonePlan.capturesMicrophone {
                guard await router.waitForMicrophoneSample(timeout: .seconds(5)) else {
                    throw AudioCaptureError.noMicrophone
                }
            }
            activeCapture = ActiveCapture(
                stream: stream,
                router: router,
                index: index
            )
            return paths
        } catch {
            if streamStarted { try? await stream.stopCapture() }
            router.cancel()
            throw error
        }
    }

    func finishSegment() async throws -> CaptureSegment {
        guard let activeCapture else { throw AudioCaptureError.notCapturing }
        defer { self.activeCapture = nil }
        do {
            try await activeCapture.stream.stopCapture()
        } catch {
            guard Self.isAlreadyStoppedError(error) else { throw error }
        }
        return try await activeCapture.router.finish(index: activeCapture.index)
    }
}
