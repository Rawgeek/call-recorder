import AppKit
import CallRecorderCore
import CoreAudio
import Foundation
import Observation

enum AudioActivityMonitorError: Error {
    case coreAudio(OSStatus)
}

@MainActor
@Observable
final class AudioActivityMonitor {
    private(set) var externalMicrophoneActive = false
    /// Whether the process holding the microphone is also playing audio, which is a call.
    private(set) var twoWayCallActive = false
    /// What that process is called, for the log line that explains a start or a refusal.
    private(set) var microphoneHolderBundleID: String?
    private var task: Task<Void, Never>?

    /// Starts watching who holds the microphone.
    ///
    /// - Parameters:
    ///   - ignoringNonCallApps: Read on every poll rather than taken once, so turning the list off
    ///     in the settings takes effect at the next poll instead of at the next launch.
    ///   - onChange: Called when the answer changes, and only then.
    func start(
        ignoringNonCallApps: @escaping @MainActor () -> Bool,
        onChange: @escaping @MainActor (Bool) -> Void
    ) {
        guard task == nil else { return }
        // ponytail: 500 ms polling is sufficient for call starts; add HAL listeners if latency is measured.
        task = Task { [weak self] in
            while !Task.isCancelled {
                if let activity = try? Self.readActivity(ignoringNonCallApps: ignoringNonCallApps()) {
                    guard let self else { return }
                    self.twoWayCallActive = activity.twoWayCall
                    self.microphoneHolderBundleID = activity.holderBundleID
                    if activity.microphoneHeld != self.externalMicrophoneActive {
                        self.externalMicrophoneActive = activity.microphoneHeld
                        onChange(activity.microphoneHeld)
                    }
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// What the audio system says about this moment: who holds the microphone, and who is playing.
    private struct Activity {
        let microphoneHeld: Bool
        let twoWayCall: Bool
        let holderBundleID: String?
    }

    private static func readActivity(ignoringNonCallApps: Bool) throws -> Activity {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var byteCount: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &byteCount
        )
        guard status == noErr else { throw AudioActivityMonitorError.coreAudio(status) }

        var processObjects = [AudioObjectID](
            repeating: kAudioObjectUnknown,
            count: Int(byteCount) / MemoryLayout<AudioObjectID>.size
        )
        guard !processObjects.isEmpty else {
            return Activity(microphoneHeld: false, twoWayCall: false, holderBundleID: nil)
        }
        status = processObjects.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return OSStatus(-50) }
            return AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &byteCount,
                baseAddress
            )
        }
        guard status == noErr else { throw AudioActivityMonitorError.coreAudio(status) }

        let activeProcessIDs = try processObjects.compactMap { processObject -> Int32? in
            guard try readRunningInput(processObject) else { return nil }
            return try readProcessID(processObject)
        }
        // Which of them are also playing audio: a caller plays the other side, dictation and a
        // voice message do not.
        let playingProcessIDs = try processObjects.compactMap { processObject -> Int32? in
            guard try readRunningOutput(processObject) else { return nil }
            return try readProcessID(processObject)
        }
        // The process identifier is what the audio system reports; the bundle identifier is what
        // says whether the process is a meeting. An app that cannot be resolved keeps its vote,
        // because nothing is known about it.
        let inputs = activeProcessIDs.map { processID in
            AudioActivityDecision.Input(
                processID: processID,
                bundleID: NSRunningApplication(processIdentifier: pid_t(processID))?.bundleIdentifier
            )
        }
        let ownProcessID = ProcessInfo.processInfo.processIdentifier
        return Activity(
            microphoneHeld: AudioActivityDecision.hasExternalInput(
                inputs: inputs,
                ownProcessID: ownProcessID,
                ignoringNonCallApps: ignoringNonCallApps
            ),
            twoWayCall: AudioActivityDecision.hasTwoWayCall(
                inputs: inputs,
                playingOutput: Set(playingProcessIDs),
                ownProcessID: ownProcessID,
                ignoringNonCallApps: ignoringNonCallApps
            ),
            holderBundleID: AudioActivityDecision.holder(
                inputs: inputs,
                ownProcessID: ownProcessID,
                ignoringNonCallApps: ignoringNonCallApps
            )?.bundleID
        )
    }

    private static func readProcessID(_ object: AudioObjectID) throws -> Int32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: pid_t = 0
        var size = UInt32(MemoryLayout.size(ofValue: value))
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        guard status == noErr else { throw AudioActivityMonitorError.coreAudio(status) }
        return value
    }

    private static func readRunningInput(_ object: AudioObjectID) throws -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout.size(ofValue: value))
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        guard status == noErr else { throw AudioActivityMonitorError.coreAudio(status) }
        return value != 0
    }

    private static func readRunningOutput(_ object: AudioObjectID) throws -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningOutput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout.size(ofValue: value))
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        guard status == noErr else { throw AudioActivityMonitorError.coreAudio(status) }
        return value != 0
    }
}
