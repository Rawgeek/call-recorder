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
