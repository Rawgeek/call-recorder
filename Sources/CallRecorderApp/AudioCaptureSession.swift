import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

struct CapturedAudioSource: Codable, Equatable, Sendable {
    let fileURL: URL
    let firstPresentationSeconds: Double
    let durationSeconds: Double
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

@MainActor
final class AudioCaptureSession {
    nonisolated private static let builtInMicrophoneID = "BuiltInMicrophoneDevice"

    private struct ActiveCapture {
        let stream: SCStream
        let router: AudioCaptureRouter
        let index: Int
    }

    private var activeCapture: ActiveCapture?

    static func availableMicrophones() -> [AudioInputDevice] {
        captureDevices().map {
            AudioInputDevice(id: $0.uniqueID, name: $0.localizedName)
        }
    }

    nonisolated static func resolvedMicrophoneID(
        availableIDs: [String],
        selectedID: String?
    ) -> String? {
        if let selectedID, availableIDs.contains(selectedID) { return selectedID }
        if availableIDs.contains(builtInMicrophoneID) { return builtInMicrophoneID }
        return availableIDs.first
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

    private static func microphone(deviceID: String?) throws -> AVCaptureDevice {
        let devices = captureDevices()
        let resolvedID = resolvedMicrophoneID(
            availableIDs: devices.map(\.uniqueID),
            selectedID: deviceID
        )
        guard let microphone = devices.first(where: { $0.uniqueID == resolvedID }) else {
            throw AudioCaptureError.noMicrophone
        }
        return microphone
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
        configuration.captureMicrophone = true
        configuration.microphoneCaptureDeviceID = try Self.microphone(
            deviceID: microphoneDeviceID
        ).uniqueID

        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        let router = AudioCaptureRouter(paths: paths)
        try stream.addStreamOutput(
            router,
            type: .audio,
            sampleHandlerQueue: router.systemQueue
        )
        try stream.addStreamOutput(
            router,
            type: .microphone,
            sampleHandlerQueue: router.microphoneQueue
        )
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
        do {
            try await activeCapture.stream.stopCapture()
        } catch {
            guard Self.isAlreadyStoppedError(error) else { throw error }
        }
        return try await activeCapture.router.finish(index: activeCapture.index)
    }
}
