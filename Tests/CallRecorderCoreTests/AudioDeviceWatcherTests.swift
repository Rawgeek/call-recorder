import Foundation
import Testing
@testable import CallRecorderApp

/// The microphone list the Settings row reads.
///
/// The row has to hold the audio system's answer as it is now, not the answer it gave when the
/// window opened: a headset connected while the window is up was not offered until the app was
/// restarted, which reads as the microphone choice being stuck on whatever was there first.
@Suite("Audio device list")
@MainActor
struct AudioDeviceWatcherTests {
    @Test("a refresh takes the audio system's new answer")
    func refreshReadsAgain() {
        var devices = [
            AudioInputDevice(id: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone")
        ]
        var defaultID: String? = "BuiltInMicrophoneDevice"
        let watcher = AudioDeviceWatcher(
            readMicrophones: { devices },
            readSystemDefaultID: { defaultID }
        )

        #expect(watcher.microphones.map(\.id) == ["BuiltInMicrophoneDevice"])
        #expect(watcher.systemDefaultID == "BuiltInMicrophoneDevice")

        devices.append(AudioInputDevice(id: "08-FF-44-4C-9B-A6:input", name: "AirPods Max"))
        defaultID = "08-FF-44-4C-9B-A6:input"
        watcher.refresh()

        #expect(watcher.microphones.map(\.name) == ["MacBook Pro Microphone", "AirPods Max"])
        #expect(watcher.systemDefaultID == "08-FF-44-4C-9B-A6:input")
    }

    @Test("the list is read once for the first draw, before anything changes")
    func startsFromWhatTheSystemHolds() {
        let watcher = AudioDeviceWatcher(
            readMicrophones: { [AudioInputDevice(id: "yeti", name: "Blue Yeti")] },
            readSystemDefaultID: { "yeti" }
        )

        #expect(watcher.microphones.map(\.name) == ["Blue Yeti"])
        #expect(watcher.systemDefaultID == "yeti")
    }
}
