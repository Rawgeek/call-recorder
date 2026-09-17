import Foundation
import Testing
@testable import CallRecorderApp

@Suite("Microphone labelling")
struct AudioInputDeviceTests {
    @Test("the built-in microphone is labelled so it can be picked with confidence")
    func labelsBuiltInMicrophone() {
        let builtIn = AudioInputDevice(id: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone")
        let external = AudioInputDevice(id: "SomeUSBID", name: "Shure MV7")

        #expect(
            AudioCaptureSession.displayName(for: builtIn) == "MacBook Pro Microphone (Built-in)"
        )
        #expect(AudioCaptureSession.displayName(for: external) == "Shure MV7")
    }

    @Test("Bluetooth headsets are recognised so the settings screen can warn about them")
    func recognisesBluetoothHeadsets() {
        let airpods = AudioInputDevice(id: "1", name: "Sam AirPods 3 Pro")
        let buds = AudioInputDevice(id: "2", name: "Galaxy Buds2")
        let builtIn = AudioInputDevice(id: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone")
        let usb = AudioInputDevice(id: "3", name: "Blue Yeti")

        #expect(AudioCaptureSession.isBluetooth(airpods))
        #expect(AudioCaptureSession.isBluetooth(buds))
        #expect(!AudioCaptureSession.isBluetooth(builtIn))
        #expect(!AudioCaptureSession.isBluetooth(usb))
    }

    @Test("the system choice follows the microphone macOS is set to use")
    func systemChoiceFollowsTheSystem() {
        let devices = ["BuiltInMicrophoneDevice", "34-0E-22-81-A2-53:input"]

        #expect(
            AudioCaptureSession.resolvedMicrophoneID(
                availableIDs: devices,
                selectedID: AudioCaptureSession.systemMicrophoneID,
                systemDefaultID: "34-0E-22-81-A2-53:input"
            ) == "34-0E-22-81-A2-53:input"
        )
        // A system set to a device that has been unplugged falls back to the built-in microphone
        // rather than leaving the recorder with nothing to record from.
        #expect(
            AudioCaptureSession.resolvedMicrophoneID(
                availableIDs: devices,
                selectedID: AudioCaptureSession.systemMicrophoneID,
                systemDefaultID: "unplugged"
            ) == "BuiltInMicrophoneDevice"
        )
        #expect(
            AudioCaptureSession.resolvedMicrophoneID(
                availableIDs: devices,
                selectedID: AudioCaptureSession.systemMicrophoneID
            ) == "BuiltInMicrophoneDevice"
        )
    }

    @Test("a named device is used whatever the system points at")
    func aNamedDeviceWins() {
        #expect(
            AudioCaptureSession.resolvedMicrophoneID(
                availableIDs: ["BuiltInMicrophoneDevice", "yeti"],
                selectedID: "yeti",
                systemDefaultID: "BuiltInMicrophoneDevice"
            ) == "yeti"
        )
    }

    @Test("the system choice names the device it points at today")
    func systemChoiceIsNamed() {
        let devices = [
            AudioInputDevice(id: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone"),
            AudioInputDevice(id: "34-0E-22-81-A2-53:input", name: "A Headset"),
        ]

        #expect(
            AudioCaptureSession.systemChoiceName(
                systemDefaultID: "34-0E-22-81-A2-53:input",
                devices: devices
            ) == "System (A Headset)"
        )
        #expect(
            AudioCaptureSession.systemChoiceName(systemDefaultID: nil, devices: devices)
                == "System default"
        )
    }
}
