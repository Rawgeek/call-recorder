import AVFoundation
import CallRecorderCore
import Foundation
import Testing
@testable import CallRecorderApp

/// The capture behind the Settings level check, measured for real.
///
/// The check used to open the microphone through AVAudioEngine, and that path delivered nothing at
/// all once a device was named on its input unit (2026-10-08: fifteen buffers in two seconds with
/// no device named, none at all with the chosen one). The row showed a dead bar while recordings
/// worked. It now runs the capture a recording runs, and this is that path, measured.
@Suite("Microphone monitoring")
@MainActor
struct MicrophoneMonitoringTests {
    @Test(
        "a check captures the microphone through the recorder's own path",
        .enabled(if: TestEnvironment.canCaptureMicrophone)
    )
    func monitorsTheMicrophone() async throws {
        let session = AudioCaptureSession()
        do {
            try await session.startMonitoring(microphoneDeviceID: nil)
        } catch {
            // A machine that has not granted Screen Recording to this copy cannot measure the
            // capture at all, which is a state of the machine rather than a fault in the code.
            if AudioCaptureSession.isScreenRecordingPermissionDeniedError(error) { return }
            throw error
        }
        // The first buffers take a moment to arrive while the input wakes up, which is exactly what
        // the row's empty first second is.
        var heard: Double?
        for _ in 0..<60 {
            try await Task.sleep(for: .milliseconds(100))
            if let level = session.microphoneLevels.currentDecibels() {
                heard = level
                break
            }
        }
        #expect(session.isMonitoring)
        await session.finishMonitoring()
        #expect(!session.isMonitoring)
        #expect(heard != nil, "the check never heard a buffer from the microphone")
    }

    @Test(
        "a second capture is refused while a check is listening",
        .enabled(if: TestEnvironment.canCaptureMicrophone)
    )
    func refusesASecondCapture() async throws {
        let session = AudioCaptureSession()
        do {
            try await session.startMonitoring(microphoneDeviceID: nil)
        } catch {
            if AudioCaptureSession.isScreenRecordingPermissionDeniedError(error) { return }
            throw error
        }
        // The recorder waits for the check to end before it starts, and this is what it would meet
        // if it did not: two captures cannot hold the same microphone.
        await #expect(throws: AudioCaptureError.alreadyCapturing) {
            try await session.startMonitoring(microphoneDeviceID: nil)
        }
        await session.finishMonitoring()
    }
}

