import Foundation
import Testing
@testable import CallRecorderCore

/// The three backstops behind automatic recording.
///
/// Automatic recording is the feature and these are what keep it from producing something nobody
/// wanted: a recording of a voice memo, a recording of a microphone that was left open, and a
/// recording of nothing at all. The tests that matter are the ones that say when a rule stays out
/// of the way, because a rail that fires on a real call loses a meeting.
@Suite("Automatic recording rails")
struct AutomaticRecordingRailsTests {
    // MARK: - The floor

    @Test("a recording below the floor is thrown away")
    func shortRecordingIsDiscarded() {
        #expect(AutomaticRecordingRails.isTooShort(recordedSeconds: 4, minimumSeconds: 30))
        #expect(AutomaticRecordingRails.isTooShort(recordedSeconds: 29.9, minimumSeconds: 30))
    }

    @Test("a recording at or above the floor is kept")
    func longEnoughRecordingIsKept() {
        #expect(!AutomaticRecordingRails.isTooShort(recordedSeconds: 30, minimumSeconds: 30))
        #expect(!AutomaticRecordingRails.isTooShort(recordedSeconds: 3_600, minimumSeconds: 30))
    }

    @Test("a floor of zero keeps everything")
    func zeroFloorKeepsEverything() {
        // What a settings blob written before the option existed means.
        #expect(!AutomaticRecordingRails.isTooShort(recordedSeconds: 0, minimumSeconds: 0))
        #expect(!AutomaticRecordingRails.isTooShort(recordedSeconds: 2, minimumSeconds: 0))
    }

    // MARK: - The ceiling

    @Test("a recording past the ceiling is stopped")
    func longRecordingIsStopped() {
        #expect(AutomaticRecordingRails.hasReachedCeiling(recordedSeconds: 10_800, maximumMinutes: 180))
        #expect(AutomaticRecordingRails.hasReachedCeiling(recordedSeconds: 65_000, maximumMinutes: 180))
    }

    @Test("a recording inside the ceiling keeps running")
    func recordingInsideTheCeilingRuns() {
        #expect(!AutomaticRecordingRails.hasReachedCeiling(recordedSeconds: 10_799, maximumMinutes: 180))
        #expect(!AutomaticRecordingRails.hasReachedCeiling(recordedSeconds: 0, maximumMinutes: 180))
    }

    @Test("a ceiling of zero is no ceiling")
    func zeroCeilingStopsNothing() {
        #expect(!AutomaticRecordingRails.hasReachedCeiling(recordedSeconds: 86_400, maximumMinutes: 0))
    }

    @Test("the measured times of the two rules are the ones the settings ship with")
    func defaultsAreTheOnesTheSettingsCarry() {
        // The floor and the ceiling are read from the settings, which fall back to these.
        #expect(AppSettings.default.minimumAutomaticRecordingSeconds == 30)
        #expect(AppSettings.default.maximumAutomaticRecordingMinutes == 180)
        #expect(AppSettings.default.ignoresNonCallApps)
    }

    @Test("each switch writes one setting, so a switch and its number cannot disagree")
    func switchesWriteTheOneSetting() {
        // Off is zero, which is what the rules already read as "this rail is not in force", and on
        // is the standard the app ships with.
        #expect(AutomaticRecordingRails.floorForSwitch(true) == 30)
        #expect(AutomaticRecordingRails.floorForSwitch(false) == 0)
        #expect(AutomaticRecordingRails.ceilingForSwitch(true) == 180)
        #expect(AutomaticRecordingRails.ceilingForSwitch(false) == 0)
        // And what the switch writes is what the rules act on.
        #expect(!AutomaticRecordingRails.isTooShort(recordedSeconds: 1, minimumSeconds: AutomaticRecordingRails.floorForSwitch(false)))
        #expect(AutomaticRecordingRails.isTooShort(recordedSeconds: 1, minimumSeconds: AutomaticRecordingRails.floorForSwitch(true)))
        #expect(!AutomaticRecordingRails.hasReachedCeiling(recordedSeconds: 60 * 60 * 24, maximumMinutes: AutomaticRecordingRails.ceilingForSwitch(false)))
        #expect(AutomaticRecordingRails.hasReachedCeiling(recordedSeconds: 60 * 60 * 24, maximumMinutes: AutomaticRecordingRails.ceilingForSwitch(true)))
    }

    // MARK: - Apps that are not meetings

    @Test("the voice recorder, dictation and the assistant never start a recording")
    func nonCallAppsAreIgnored() {
        #expect(NonCallMicrophoneApps.isIgnored(bundleID: "com.apple.VoiceMemos"))
        #expect(NonCallMicrophoneApps.isIgnored(bundleID: "com.apple.assistantd"))
        #expect(NonCallMicrophoneApps.isIgnored(bundleID: "com.apple.SpeechRecognitionCore.speechrecognitiond"))
        #expect(NonCallMicrophoneApps.isIgnored(bundleID: "com.apple.siri.launcher"))
    }

    @Test("an app is matched by prefix, because a helper process holds the device")
    func helperProcessesAreMatchedByPrefix() {
        #expect(NonCallMicrophoneApps.isIgnored(bundleID: "com.apple.VoiceMemos.helper"))
        // The identifier is compared without case, because an app's is not always written the way
        // this list writes it.
        #expect(NonCallMicrophoneApps.isIgnored(bundleID: "COM.APPLE.VOICEMEMOS"))
    }

    @Test("a call app is not on the list")
    func callAppsAreNotIgnored() {
        // The apps a meeting actually happens in, including the browser a Meet or a Zoom runs in.
        for bundleID in [
            "us.zoom.xos", "com.microsoft.teams2", "com.google.Chrome",
            "com.apple.FaceTime", "com.hnc.Discord", "com.tinyspeck.slackmacgap",
        ] {
            #expect(!NonCallMicrophoneApps.isIgnored(bundleID: bundleID))
        }
    }

    @Test("a process with no readable identifier keeps its vote")
    func unknownProcessIsNotIgnored() {
        // Nothing is known about it, and a missed meeting costs more than a recording that has to
        // be discarded.
        #expect(!NonCallMicrophoneApps.isIgnored(bundleID: nil))
        #expect(!NonCallMicrophoneApps.isIgnored(bundleID: ""))
    }

    // MARK: - The decision over the processes that hold the microphone

    @Test("the recorder's own capture is not a meeting")
    func ownCaptureIsNotAMeeting() {
        let inputs = [
            AudioActivityDecision.Input(processID: 42, bundleID: "local.callrecorder.app")
        ]
        #expect(
            !AudioActivityDecision.hasExternalInput(
                inputs: inputs,
                ownProcessID: 42,
                ignoringNonCallApps: true
            )
        )
    }

    @Test("a voice memo does not start a recording while the list applies")
    func voiceMemoDoesNotStartARecording() {
        let inputs = [
            AudioActivityDecision.Input(processID: 42, bundleID: "local.callrecorder.app"),
            AudioActivityDecision.Input(processID: 77, bundleID: "com.apple.VoiceMemos"),
        ]
        #expect(
            !AudioActivityDecision.hasExternalInput(
                inputs: inputs,
                ownProcessID: 42,
                ignoringNonCallApps: true
            )
        )
        // Turning the list off is how the app behaved before it existed, and it is what a person
        // who records their own dictation asks for.
        #expect(
            AudioActivityDecision.hasExternalInput(
                inputs: inputs,
                ownProcessID: 42,
                ignoringNonCallApps: false
            )
        )
    }

    @Test("a call app still starts a recording, and so does an app nobody has heard of")
    func otherAppsStillStartARecording() {
        for bundleID in ["us.zoom.xos", "com.apple.FaceTime", nil] {
            let inputs = [
                AudioActivityDecision.Input(processID: 42, bundleID: "local.callrecorder.app"),
                AudioActivityDecision.Input(processID: 91, bundleID: bundleID),
            ]
            #expect(
                AudioActivityDecision.hasExternalInput(
                    inputs: inputs,
                    ownProcessID: 42,
                    ignoringNonCallApps: true
                )
            )
        }
    }

    // MARK: - Stored settings

    @Test("settings saved before the rails existed load with the rails in place")
    func legacySettingsLoadWithTheRails() throws {
        // Given: a blob written by a build that had no such keys.
        let legacy = """
        {
          "automaticDetectionEnabled": true,
          "automaticStopGraceSeconds": 2,
          "selectedWhisperModelID": "small",
          "outputDirectory": "/tmp/recordings"
        }
        """

        // When
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(legacy.utf8))

        // Then: the choices survive and the rails take their defaults.
        #expect(decoded.selectedWhisperModelID == "small")
        #expect(decoded.outputDirectory == "/tmp/recordings")
        #expect(decoded.minimumAutomaticRecordingSeconds == 30)
        #expect(decoded.maximumAutomaticRecordingMinutes == 180)
        #expect(decoded.ignoresNonCallApps)
    }

    @Test("a turned-off rail survives a save")
    func turnedOffRailsSurviveASave() throws {
        // Given
        var settings = AppSettings.default
        settings.minimumAutomaticRecordingSeconds = 0
        settings.maximumAutomaticRecordingMinutes = 0
        settings.ignoresNonCallApps = false

        // When
        let decoded = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONEncoder().encode(settings)
        )

        // Then: off is a choice, and it must not come back on at the next launch.
        #expect(decoded.minimumAutomaticRecordingSeconds == 0)
        #expect(decoded.maximumAutomaticRecordingMinutes == 0)
        #expect(!decoded.ignoresNonCallApps)
    }
}
