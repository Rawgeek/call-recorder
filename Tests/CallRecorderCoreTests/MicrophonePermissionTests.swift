import Foundation
import Testing
@testable import CallRecorderCore

/// The card that says a recording will hold the other side alone.
///
/// Without the microphone grant a recording does not fail: it starts, the other side arrives, and
/// every recording in the library on 2026-10-08 was missing the person's own voice with nothing on
/// any surface saying so. The sentence is what tells them, so it is checked here rather than only
/// looked at in a render.
@Suite("Microphone permission notice")
struct MicrophonePermissionTests {
    @Test("the card names what a recording will hold")
    func saysWhatIsLost() {
        let notice = MicrophonePermission.notice()

        #expect(notice.title == "Your side is not being recorded")
        // The part nobody can guess: the call is saved, it plays, and only the other side is on it.
        #expect(notice.message.contains("only the other side"))
        #expect(notice.message.contains("missing from the audio"))
    }

    @Test("the card says where the switch is and how a new copy is granted again")
    func saysWhereAndHow() {
        let message = MicrophonePermission.notice().message

        #expect(message.contains("System Settings"))
        #expect(message.contains("Microphone"))
        #expect(message.contains("Reset Permission"))
        // The grant belongs to the copy that asked, which is why a rebuild can leave it behind.
        #expect(message.contains("copy"))
    }

    @Test("the settings link opens the Microphone pane")
    func linkNamesThePane() {
        let url = MicrophonePermission.settingsURL

        #expect(url.hasPrefix("x-apple.systempreferences:"))
        #expect(url.contains("Privacy_Microphone"))
    }

    @Test("the reset forgets this app's microphone record and nothing else")
    func resetNamesTheAppAndTheService() {
        let arguments = MicrophonePermission.resetArguments(
            bundleIdentifier: "local.callrecorder.app"
        )

        #expect(arguments == ["reset", "Microphone", "local.callrecorder.app"])
        #expect(MicrophonePermission.resetExecutable.path == "/usr/bin/tccutil")
    }
}

