import CoreAudio
import Foundation
import Observation

/// The microphones macOS offers, kept current while the app runs.
///
/// A device list read once is a list of the moment a window opened. A headset put back in its case
/// stayed in the menu, and one that had just been connected was not offered until the app was
/// started again, which reads as the choice being stuck on whatever was there first. Core Audio
/// says when a device appears or goes away and when the system's own input changes, so the list is
/// read again on each of those.
///
/// The two values are stored rather than computed, because a stored property is what makes a view
/// reading them be redrawn when the audio system changes its answer.
@MainActor
@Observable
final class AudioDeviceWatcher {
    /// The input devices macOS offers right now.
    private(set) var microphones: [AudioInputDevice]
    /// The device macOS is set to use, in the identifier form the menu names it with.
    private(set) var systemDefaultID: String?

    // The readers are isolated to the actor this list belongs to. Handing over a device list is
    // the one thing the initialiser does with them, and both answers come from the audio system
    // on the main thread.
    @ObservationIgnored private let readMicrophones: @MainActor () -> [AudioInputDevice]
    @ObservationIgnored private let readSystemDefaultID: @MainActor () -> String?
    @ObservationIgnored private var listeners: [Listener] = []

    /// The two properties the microphone menu is built from.
    ///
    /// The device list is the menu itself, and the default input is the device the first choice
    /// follows today: either one can change while the other stays as it was.
    private static let watchedSelectors: [AudioObjectPropertySelector] = [
        kAudioHardwarePropertyDevices,
        kAudioHardwarePropertyDefaultInputDevice,
    ]

    private struct Listener {
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }

    /// Reads the audio system, then listens for it to change.
    ///
    /// Creating one is what starts the watching: the app keeps a single watcher for as long as it
    /// runs, and a second one would only read the same system twice.
    init(
        readMicrophones: @escaping @MainActor () -> [AudioInputDevice] = AudioCaptureSession
            .availableMicrophones,
        readSystemDefaultID: @escaping @MainActor () -> String? = AudioCaptureSession
            .systemDefaultMicrophoneID
    ) {
        self.readMicrophones = readMicrophones
        self.readSystemDefaultID = readSystemDefaultID
        microphones = readMicrophones()
        systemDefaultID = readSystemDefaultID()
        startListening()
    }

    /// Reads the audio system again, which is what a listener and a manual refresh both do.
    func refresh() {
        microphones = readMicrophones()
        systemDefaultID = readSystemDefaultID()
    }

    private func startListening() {
        for selector in Self.watchedSelectors {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                // The block is registered on the main queue, so the main actor is what runs it.
                // Saying so is what lets it touch the watcher without a hop.
                MainActor.assumeIsolated { self?.refresh() }
            }
            let added = AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                DispatchQueue.main,
                block
            )
            // A listener that could not be registered leaves the menu as it is today, showing what
            // the devices were when the app started. Nothing here is worth failing a launch over.
            if added == noErr {
                listeners.append(Listener(address: address, block: block))
            }
        }
    }
}
