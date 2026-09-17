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
        // The reminder is due on a settings blob that has never carried the flag, which is the
        // state a first run is in.
        #expect(decoded.automaticDetectionNoticeDismissed == false)
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
        settings.selectedMicrophoneID = "Built-in"
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(decoded == settings)
        #expect(decoded.automaticModelUpdatesEnabled == false)
    }

    @Test("a settings blob that is not JSON is rejected so defaults apply")
    func damagedSettingsThrow() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(AppSettings.self, from: Data("not json".utf8))
        }
    }
}
