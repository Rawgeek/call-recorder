import AVFoundation
import ScreenCaptureKit
import Testing
@testable import CallRecorderApp

/// A count the display-wait tests read after the loop has run.
private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    @discardableResult
    func countOne() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }
}

@Suite("Audio capture session")
struct AudioCaptureSessionTests {
    @Test("a start that finds no display asks the screen back and looks again")
    func looksAgainUntilADisplayIsThere() async throws {
        // ScreenCaptureKit answers with no display while the screen is asleep, and the 2026-09-28
        // 17:04 automatic recording was refused on the first such answer. The start asks for the
        // screen and looks again instead of giving the call up.
        let looks = CallCounter()
        let wakes = CallCounter()

        let content = try await AudioCaptureSession.waitingForADisplay(
            attempts: 4,
            pause: .milliseconds(1),
            look: { () -> [String] in looks.countOne() < 3 ? [] : ["display"] },
            hasDisplay: { !$0.isEmpty },
            wake: { wakes.countOne(); return 1 },
            release: { _ in },
            sleep: { _ in }
        )

        #expect(content == ["display"])
        #expect(looks.value == 3)
        #expect(wakes.value == 2)
    }

    @Test("a display that is already there is answered without a look for another")
    func doesNotLookTwiceWhenThereIsADisplay() async throws {
        let looks = CallCounter()
        let wakes = CallCounter()

        let content = try await AudioCaptureSession.waitingForADisplay(
            attempts: 4,
            pause: .milliseconds(1),
            look: { () -> [String] in looks.countOne(); return ["display"] },
            hasDisplay: { !$0.isEmpty },
            wake: { wakes.countOne(); return 1 },
            release: { _ in },
            sleep: { _ in }
        )

        #expect(content == ["display"])
        #expect(looks.value == 1)
        #expect(wakes.value == 0)
    }

    @Test("a Mac that never answers a display stops looking and says what it saw")
    func givesUpAfterTheLastLook() async throws {
        // A Mac with no display at all answers nothing however long the app waits, so the start has
        // to end and report the refusal rather than look forever.
        let looks = CallCounter()
        let wakes = CallCounter()

        let content = try await AudioCaptureSession.waitingForADisplay(
            attempts: 5,
            pause: .milliseconds(1),
            look: { () -> [String] in looks.countOne(); return [] },
            hasDisplay: { !$0.isEmpty },
            wake: { wakes.countOne(); return 1 },
            release: { _ in },
            sleep: { _ in }
        )

        #expect(content.isEmpty)
        #expect(looks.value == 5)
        #expect(wakes.value == 4)
    }

    @Test("the refusal a screen that never comes back produces names the screen")
    func theRefusalNamesTheScreen() {
        let said = AudioCaptureError.noDisplay.errorDescription ?? ""
        #expect(said.contains("asleep"))
        #expect(said.contains("wake it"))
    }

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
    func recordsWithoutAMicrophone() throws {
        // Given a machine whose device list is empty, and the setting that allows it.
        // Then the segment goes ahead with no microphone source rather than refusing to record.
        let microphoneID = try AudioCaptureSession.chosenMicrophoneID(
            availableIDs: [],
            selectedID: AudioCaptureSession.systemMicrophoneID,
            systemDefaultID: nil,
            allowsMissingMicrophone: true
        )

        #expect(microphoneID == nil)
    }

    @Test("the refusal is kept for the setting that asks for it")
    func refusesWithoutAMicrophone() {
        // Given the same machine, and the setting that wants both sides of a call.
        // Then the start is refused, and the refusal is the one the settings row explains.
        #expect(throws: AudioCaptureError.noMicrophone) {
            try AudioCaptureSession.chosenMicrophoneID(
                availableIDs: [],
                selectedID: AudioCaptureSession.systemMicrophoneID,
                systemDefaultID: nil,
                allowsMissingMicrophone: false
            )
        }
    }

    @Test("a microphone on the machine is used whether or not one is required")
    func chosenMicrophoneSurvivesTheSetting() throws {
        // The setting is about a machine with no input at all, so it may not change which device a
        // machine that has one records from.
        for allowsMissing in [true, false] {
            let microphoneID = try AudioCaptureSession.chosenMicrophoneID(
                availableIDs: ["BuiltInMicrophoneDevice", "ExternalMicrophone"],
                selectedID: "ExternalMicrophone",
                systemDefaultID: nil,
                allowsMissingMicrophone: allowsMissing
            )

            #expect(microphoneID == "ExternalMicrophone")
        }
    }

    @Test("a refusal without a microphone says what to do about it")
    func refusalIsReadable() {
        let message = AudioCaptureError.noMicrophone.localizedDescription

        #expect(message.contains("No microphone is connected"))
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
