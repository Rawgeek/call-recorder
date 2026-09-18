import Foundation
import Testing
@testable import CallRecorderCore

@Suite("Stored settings stay readable")
struct AppSettingsDecodingTests {
    /// Exactly what an earlier build wrote: no automaticModelUpdatesEnabled key.
    private let legacyJSON = """
    {
      "automaticDetectionEnabled": true,
      "automaticStopGraceSeconds": 4,
      "selectedMicrophoneID": "Yeti",
      "selectedWhisperModelID": "medium",
      "outputDirectory": "/tmp/recordings"
    }
    """

    @Test("settings saved before the update option existed still load")
    func legacySettingsLoad() throws {
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(legacyJSON.utf8))
        // The choices the user made must survive; only the new field falls back.
        #expect(decoded.selectedMicrophoneID == "Yeti")
        #expect(decoded.selectedWhisperModelID == "medium")
        #expect(decoded.outputDirectory == "/tmp/recordings")
        #expect(decoded.automaticStopGraceSeconds == 4)
        #expect(decoded.automaticModelUpdatesEnabled == true)
        // Same rule for the app's own updates: a blob written before the option existed keeps the
        // behaviour the app shipped with, which is to install a newer release on its own.
        #expect(decoded.automaticAppUpdatesEnabled == true)
        // Giving the audio back is what the app did before the option existed, so a blob written
        // without the flag keeps the behaviour it had.
        #expect(decoded.removeAudioAfterTranscription == true)
        // The reminder is due on a settings blob that has never carried the flag, which is the
        // state a first run is in.
        #expect(decoded.automaticDetectionNoticeDismissed == false)
        // And the check runs on the step the app shipped with, which is what a blob written before
        // the step could be chosen has to mean.
        #expect(decoded.appUpdateCheckInterval == .everySixHours)
        // A Mac that has never been asked about a missing microphone records the other side of the
        // call, which is the behaviour this release introduced.
        #expect(decoded.recordsWithoutMicrophone)
        // And a library whose lists have never been trusted with the voice count has the count
        // asked for, which is what this release does by default.
        #expect(decoded.diarizationUsesParticipantCount)
    }

    @Test("leaving the voice count to the detector survives a save")
    func leavingTheVoiceCountAloneSurvivesASave() throws {
        var settings = AppSettings.default
        settings.diarizationUsesParticipantCount = false

        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))

        #expect(decoded.diarizationUsesParticipantCount == false)
        #expect(decoded == settings)
    }

    @Test("refusing to record without a microphone survives a save")
    func recordingWithoutAMicrophoneSurvivesASave() throws {
        var settings = AppSettings.default
        settings.recordsWithoutMicrophone = false

        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))

        #expect(decoded.recordsWithoutMicrophone == false)
        #expect(decoded == settings)
    }

    @Test("the chosen check step is remembered, and one this build cannot read costs only itself")
    func checkIntervalSurvivesASave() throws {
        // Given a settings blob with a step that is not the default.
        var settings = AppSettings.default
        settings.appUpdateCheckInterval = .everyThirtyMinutes

        // Then the choice comes back, rather than the default overwriting it.
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded == settings)
        #expect(decoded.appUpdateCheckInterval == .everyThirtyMinutes)

        // And a step this build has never heard of — written by a later build, or by a file that
        // was damaged — falls back on its own. The microphone, the model, and the folder beside it
        // are the reason: one unreadable value may not cost a person their whole setup.
        let unknown = """
        {
          "selectedMicrophoneID": "Yeti",
          "selectedWhisperModelID": "medium",
          "outputDirectory": "/tmp/recordings",
          "appUpdateCheckInterval": "3m"
        }
        """
        let damaged = try JSONDecoder().decode(AppSettings.self, from: Data(unknown.utf8))
        #expect(damaged.appUpdateCheckInterval == AppUpdateInterval.default)
        #expect(damaged.selectedMicrophoneID == "Yeti")
        #expect(damaged.selectedWhisperModelID == "medium")
        #expect(damaged.outputDirectory == "/tmp/recordings")
    }

    @Test("a dismissed reminder survives a save")
    func dismissedReminderIsRemembered() throws {
        var settings = AppSettings.default
        settings.automaticDetectionEnabled = false
        settings.automaticDetectionNoticeDismissed = true
        let decoded = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONEncoder().encode(settings)
        )
        // Without this the card would come back at every launch and the dismissal would be a
        // gesture that did nothing.
        #expect(decoded.automaticDetectionNoticeDismissed)
        #expect(decoded.automaticDetectionEnabled == false)
    }

    @Test("a saved settings blob round trips through the new decoder")
    func settingsRoundTrip() throws {
        var settings = AppSettings.default
        settings.automaticModelUpdatesEnabled = false
        settings.automaticAppUpdatesEnabled = false
        settings.selectedMicrophoneID = "Built-in"
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(decoded == settings)
        #expect(decoded.automaticModelUpdatesEnabled == false)
        #expect(decoded.automaticAppUpdatesEnabled == false)
    }

    @Test("a settings blob that is not JSON is rejected so defaults apply")
    func damagedSettingsThrow() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(AppSettings.self, from: Data("not json".utf8))
        }
    }
}
