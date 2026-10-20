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

    @Test("microphone readiness succeeds only after a writable sample signal")
    func waitsForWritableMicrophoneSample() async {
        let ready = MicrophoneSampleGate()
        ready.signal()
        #expect(await ready.wait(timeout: .seconds(1)))

        let silent = MicrophoneSampleGate()
        #expect(await !silent.wait(timeout: .milliseconds(10)))
    }

    @Test("cancelling microphone readiness resumes the waiter")
    func cancellingMicrophoneReadinessResumesTheWaiter() async {
        let gate = MicrophoneSampleGate()
        let wait = Task {
            // The timeout is far longer than the cancellation, so a waiter that was not resumed
            // would hold this test until the suite's own time limit rather than passing quickly.
            await gate.wait(timeout: .seconds(30))
        }

        wait.cancel()

        #expect(await !wait.value)
    }

    @Test("a silent microphone error tells the user how to recover")
    func silentMicrophoneErrorIsActionable() {
        let message = AudioCaptureError.microphoneSilent.localizedDescription

        #expect(message.contains("microphone"))
        #expect(message.contains("reconnect"))
        #expect(message.contains("Settings"))
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
        #expect(AudioCaptureSession.microphoneCapturePlan(
            availableIDs: [],
            selectedID: AudioCaptureSession.systemMicrophoneID,
            systemDefaultID: nil
        ) == MicrophoneCapturePlan(capturesMicrophone: false, deviceID: nil))
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

    @Test("a cancelled router drops a sample that arrives after cleanup")
    func cancelledRouterIsTerminal() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "capture-cancelled-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let paths = CaptureSegment.paths(in: directory, index: 1)
        let router = AudioCaptureRouter(
            paths: paths,
            levels: AudioLevelMeter(),
            microphoneLevels: AudioLevelMeter()
        )
        router.cancel()

        var sample: CMSampleBuffer?
        let status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            formatDescription: nil,
            sampleCount: 0,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sample
        )
        let lateSample = try #require(sample)

        #expect(status == noErr)
        router.receive(lateSample, of: .audio)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test("failed-start cleanup returns on the deadline and releases the next command")
    @MainActor
    func failedStartCleanupDoesNotJoinTheStop() async {
        let requested = AsyncGate()
        let deadline = AsyncGate()
        let fake = HeldCaptureStop(requested: requested)
        let probe = LockedStringProbe()
        var queue = CaptureCommandQueue()

        let cleanup = Task {
            await AudioCaptureSession.stopFailedStart(
                { completion in fake.stop(completion) },
                cancel: { probe.record("cancelled") },
                within: 15,
                sleep: { _ in await deadline.wait() }
            )
        }
        await requested.wait()

        deadline.open()
        await cleanup.value
        let next = queue.enqueue { probe.record("next") }
        await next.value

        #expect(probe.values() == ["cancelled", "next"])
        #expect(fake.isHoldingCompletion)
        fake.complete(nil)
    }

    @Test("a stop completion wins and a late deadline does nothing")
    func completionFirstResolvesOnce() async throws {
        let requested = AsyncGate()
        let deadline = AsyncGate()
        let fake = HeldCaptureStop(requested: requested)

        let stop = Task {
            try await AudioCaptureSession.stop(
                { completion in fake.stop(completion) },
                within: 15,
                sleep: { _ in await deadline.wait() }
            )
        }
        await requested.wait()
        fake.complete(nil)
        try await stop.value

        deadline.open()
    }

    @Test("a stop failure is thrown and already stopped is normalized")
    func stopErrorsKeepTheirMeaning() async throws {
        let failureRequested = AsyncGate()
        let failureDeadline = AsyncGate()
        let failure = HeldCaptureStop(requested: failureRequested)
        let stoppedRequested = AsyncGate()
        let stoppedDeadline = AsyncGate()
        let stopped = HeldCaptureStop(requested: stoppedRequested)

        let failing = Task {
            try await AudioCaptureSession.stop(
                { completion in failure.stop(completion) },
                within: 15,
                sleep: { _ in await failureDeadline.wait() }
            )
        }
        await failureRequested.wait()
        failure.complete(TestStopFailure())
        await #expect(throws: TestStopFailure.self) {
            try await failing.value
        }
        failureDeadline.open()

        let alreadyStopped = Task {
            try await AudioCaptureSession.stop(
                { completion in stopped.stop(completion) },
                within: 15,
                sleep: { _ in await stoppedDeadline.wait() }
            )
        }
        await stoppedRequested.wait()
        stopped.complete(NSError(domain: SCStreamErrorDomain, code: -3_808))
        try await alreadyStopped.value
        stoppedDeadline.open()
    }

    @Test("failed-start cleanup keeps the start error and still cancels")
    func failedStartCleanupSwallowsStopError() async {
        let requested = AsyncGate()
        let deadline = AsyncGate()
        let fake = HeldCaptureStop(requested: requested)
        let probe = LockedStringProbe()

        let cleanup = Task {
            await AudioCaptureSession.stopFailedStart(
                { completion in fake.stop(completion) },
                cancel: { probe.record("cancelled") },
                within: 15,
                sleep: { _ in await deadline.wait() }
            )
        }
        await requested.wait()
        fake.complete(TestStopFailure())
        await cleanup.value

        #expect(probe.values() == ["cancelled"])
        deadline.open()
    }

    @Test("cancelling the wait resolves it without the stop completion")
    func cancellationResolvesOnce() async throws {
        let requested = AsyncGate()
        let deadline = AsyncGate()
        let fake = HeldCaptureStop(requested: requested)

        let stop = Task {
            try await AudioCaptureSession.stop(
                { completion in fake.stop(completion) },
                within: 15,
                sleep: { _ in await deadline.wait() }
            )
        }
        await requested.wait()
        stop.cancel()
        try await stop.value

        deadline.open()
        fake.complete(nil)
    }
}

private struct TestStopFailure: Error {}

/// A stop boundary whose completion is held until the test releases it.
private final class HeldCaptureStop: @unchecked Sendable {
    private let lock = NSLock()
    private let requested: AsyncGate
    private var completions: [@Sendable (any Error?) -> Void] = []

    init(requested: AsyncGate) {
        self.requested = requested
    }

    var isHoldingCompletion: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !completions.isEmpty
    }

    func stop(_ completion: @escaping @Sendable (any Error?) -> Void) {
        lock.lock()
        completions.append(completion)
        lock.unlock()
        requested.open()
    }

    func complete(_ error: (any Error)?) {
        lock.lock()
        let completion = completions.isEmpty ? nil : completions.removeFirst()
        lock.unlock()
        completion?(error)
    }
}
