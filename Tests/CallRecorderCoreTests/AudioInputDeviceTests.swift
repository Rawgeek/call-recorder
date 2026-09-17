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
}

