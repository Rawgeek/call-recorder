import AVFoundation
import ScreenCaptureKit
import Testing
@testable import CallRecorderApp

@Suite("Audio capture session")
struct AudioCaptureSessionTests {
    @Test("an already-stopped ScreenCaptureKit stream is an idempotent stop")
    func recognizesAlreadyStoppedStream() {
        let error = NSError(domain: SCStreamErrorDomain, code: -3_808)

        #expect(AudioCaptureSession.isAlreadyStoppedError(error))
        #expect(!AudioCaptureSession.isAlreadyStoppedError(AudioCaptureError.notCapturing))
    }

    @Test("only the ScreenCaptureKit user-declined error is a permission denial")
    func recognizesScreenRecordingPermissionDenial() {
        let denied = NSError(domain: SCStreamErrorDomain, code: -3_801)
        let sibling = NSError(domain: SCStreamErrorDomain, code: -3_802)
        let unrelated = NSError(domain: NSCocoaErrorDomain, code: -3_801)

        #expect(AudioCaptureSession.isScreenRecordingPermissionDeniedError(denied))
        #expect(!AudioCaptureSession.isScreenRecordingPermissionDeniedError(sibling))
        #expect(!AudioCaptureSession.isScreenRecordingPermissionDeniedError(unrelated))
    }

    @Test("an available selected microphone wins")
    func selectsRequestedMicrophone() {
        // Given / When
        let microphoneID = AudioCaptureSession.resolvedMicrophoneID(
            availableIDs: ["BuiltInMicrophoneDevice", "AirPodsMicrophone"],
            selectedID: "AirPodsMicrophone"
        )

        // Then
        #expect(microphoneID == "AirPodsMicrophone")
    }

    @Test("a missing selected microphone falls back to the MacBook microphone")
    func fallsBackToBuiltInMicrophone() {
        // Given / When
        let microphoneID = AudioCaptureSession.resolvedMicrophoneID(
            availableIDs: ["AirPodsMicrophone", "BuiltInMicrophoneDevice"],
            selectedID: "DisconnectedMicrophone"
        )

        // Then
        #expect(microphoneID == "BuiltInMicrophoneDevice")
    }

    @Test("an unset microphone follows the system AirPods instead of discovery order")
    func unsetMicrophoneFollowsSystemDefault() {
        let available = ["ContinuityMicrophone", "AirPodsMicrophone"]

        let resolved = AudioCaptureSession.resolvedMicrophoneID(
            availableIDs: available,
            selectedID: nil,
            systemDefaultID: "AirPodsMicrophone"
        )
        let plan = AudioCaptureSession.microphoneCapturePlan(
            availableIDs: available,
            selectedID: nil,
            systemDefaultID: "AirPodsMicrophone"
        )

        #expect(resolved == "AirPodsMicrophone")
        #expect(plan == MicrophoneCapturePlan(capturesMicrophone: true, deviceID: nil))
    }

    @Test("the system and stale choices let ScreenCaptureKit follow the system default")
    func systemAndStaleChoicesUseSystemRoute() {
        let available = ["ContinuityMicrophone", "AirPodsMicrophone"]

        let system = AudioCaptureSession.microphoneCapturePlan(
            availableIDs: available,
            selectedID: AudioCaptureSession.systemMicrophoneID,
            systemDefaultID: "AirPodsMicrophone"
        )
        let stale = AudioCaptureSession.microphoneCapturePlan(
            availableIDs: available,
            selectedID: "DisconnectedMicrophone",
            systemDefaultID: "AirPodsMicrophone"
        )

        #expect(system == MicrophoneCapturePlan(capturesMicrophone: true, deviceID: nil))
        #expect(stale == system)
    }

    @Test("an explicit AirPods choice is handed to ScreenCaptureKit unchanged")
    func explicitAirPodsChoiceIsPreserved() {
        let plan = AudioCaptureSession.microphoneCapturePlan(
            availableIDs: ["ContinuityMicrophone", "AirPodsMicrophone"],
            selectedID: "AirPodsMicrophone",
            systemDefaultID: "ContinuityMicrophone"
        )

        #expect(plan == MicrophoneCapturePlan(
            capturesMicrophone: true,
            deviceID: "AirPodsMicrophone"
        ))
    }

    @Test("a Mac without a built-in microphone falls back to its first input")
    func fallsBackToFirstAvailableMicrophone() {
        // Given / When
        let microphoneID = AudioCaptureSession.resolvedMicrophoneID(
            availableIDs: ["ExternalMicrophone"],
            selectedID: nil
        )

        // Then
        #expect(microphoneID == "ExternalMicrophone")
    }

    @Test("a Mac mini with no audio input records without a microphone")
    func acceptsNoMicrophone() {
        let microphoneID = AudioCaptureSession.resolvedMicrophoneID(
            availableIDs: [],
            selectedID: AudioCaptureSession.systemMicrophoneID,
            systemDefaultID: nil
        )

        #expect(microphoneID == nil)
        #expect(AudioCaptureSession.microphoneCapturePlan(
            availableIDs: [],
            selectedID: AudioCaptureSession.systemMicrophoneID,
            systemDefaultID: nil
        ) == MicrophoneCapturePlan(capturesMicrophone: false, deviceID: nil))
    }

    @Test("microphone readiness succeeds only after a writable sample signal")
    func waitsForWritableMicrophoneSample() async {
        let ready = MicrophoneSampleGate()
        ready.signal()
        #expect(await ready.wait(timeout: .seconds(1)))

        let silent = MicrophoneSampleGate()
        #expect(await !silent.wait(timeout: .milliseconds(10)))
    }

    @Test("cancelling microphone readiness does not wait for the timeout")
    func cancelsMicrophoneReadinessImmediately() async {
        let gate = MicrophoneSampleGate()
        let started = ContinuousClock.now
        let wait = Task {
            await gate.wait(timeout: .seconds(5))
        }

        wait.cancel()

        #expect(await !wait.value)
        #expect(ContinuousClock.now - started < .seconds(1))
    }

    @Test("a missing microphone error tells the user how to recover")
    func missingMicrophoneErrorIsActionable() {
        let message = AudioCaptureError.noMicrophone.localizedDescription

        #expect(message.contains("microphone"))
        #expect(message.contains("Reconnect"))
        #expect(message.contains("Settings"))
    }

    @Test("capture paths keep microphone and system sources distinct")
    func buildsDistinctSourcePaths() {
        // Given
        let directory = URL(filePath: "/tmp/call", directoryHint: .isDirectory)

        // When
        let paths = CaptureSegment.paths(in: directory, index: 2)

        // Then
        #expect(paths.system.lastPathComponent == "system-002.m4a")
        #expect(paths.microphone.lastPathComponent == "microphone-002.m4a")
        #expect(paths.system != paths.microphone)
    }

    @Test("one readable capture source keeps a segment recoverable")
    func acceptsOneAvailableSource() throws {
        // Given
        let system = CapturedAudioSource(
            fileURL: URL(filePath: "/tmp/system-001.m4a"),
            firstPresentationSeconds: 10,
            durationSeconds: 2
        )

        // When
        let segment = try CaptureSegment(index: 1, system: system, microphone: nil)

        // Then
        #expect(segment.hasRecoverableAudio)
        #expect(segment.system == system)
        #expect(segment.microphone == nil)
    }

    @Test("a capture manifest restores both synchronized sources")
    func manifestRoundTripsCapturedSources() throws {
        // Given
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "capture-manifest-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let segment = try CaptureSegment(
            index: 3,
            system: CapturedAudioSource(
                fileURL: directory.appending(path: "system-003.m4a"),
                firstPresentationSeconds: 100,
                durationSeconds: 8
            ),
            microphone: CapturedAudioSource(
                fileURL: directory.appending(path: "microphone-003.m4a"),
                firstPresentationSeconds: 100.02,
                durationSeconds: 7.9
            )
        )

        // When
        let manifestURL = try CaptureSegmentManifest.write(segment, in: directory)
        let restored = try CaptureSegmentManifest.read(from: manifestURL)

        // Then
        #expect(restored == segment)
        #expect(manifestURL.lastPathComponent == "segment-003.json")
    }
}
