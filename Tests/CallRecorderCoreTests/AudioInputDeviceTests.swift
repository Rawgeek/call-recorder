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

    @Test("the menu offers the system choice first and every device after it")
    func menuOffersTheSystemChoiceFirst() {
        let devices = [
            AudioInputDevice(id: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone"),
            AudioInputDevice(id: "08-FF-44-4C-9B-A6:input", name: "AirPods Max"),
        ]

        let choices = AudioCaptureSession.microphoneChoices(
            systemDefaultID: "08-FF-44-4C-9B-A6:input",
            devices: devices
        )

        // The first row is the instruction to follow the system, named for what that means today;
        // every row after it is one device, pinned by name.
        #expect(choices.map(\.id) == [AudioCaptureSession.systemMicrophoneID] + devices.map(\.id))
        #expect(choices.first?.name == "System (AirPods Max)")
        #expect(choices.dropFirst().map(\.name) == ["MacBook Pro Microphone", "AirPods Max"])
    }

    @Test("a Mac with no default input still has the system choice to offer")
    func menuWithoutADefaultDevice() {
        let choices = AudioCaptureSession.microphoneChoices(systemDefaultID: nil, devices: [])

        #expect(choices.map(\.name) == ["System default"])
    }

    @Test("a device that is gone is not found in the audio system either")
    func anUnpluggedDeviceIsNotFound() {
        #expect(AudioCaptureSession.audioDeviceID(forUID: "no-such-device-anywhere") == nil)
    }

    @Test("the identifier macOS reports for its own choice is one the audio system answers to")
    func theSystemsOwnChoiceResolves() {
        // The level check hands the chosen device to Core Audio by this identifier, so the two
        // lists have to answer to the same name. A Mac with no input has nothing to check.
        guard let uid = AudioCaptureSession.systemDefaultMicrophoneID() else { return }

        #expect(AudioCaptureSession.audioDeviceID(forUID: uid) != nil)
    }
}
