import Foundation
import Testing
@testable import CallRecorderCore

/// The card the popover draws when macOS has not granted Screen Recording.
///
/// Without the grant the capture throws, and the error that used to reach the surface named no
/// permission and no way to grant one. The sentence matters as much as the state, so it is checked
/// here rather than only looked at in a render.
@Suite("Screen Recording permission notice")
struct ScreenRecordingPermissionTests {
    @Test("a granted permission adds no card")
    func grantedAddsNothing() {
        #expect(ScreenRecordingPermission.notice(granted: true) == nil)
    }

    @Test("a missing permission is stated, not implied")
    func missingIsStated() {
        let notice = ScreenRecordingPermission.notice(granted: false)

        #expect(notice?.title == "Screen Recording permission is needed")
    }

    @Test("the card says what a recording without the permission holds")
    func saysWhatIsLost() {
        // The failure is not a missing feature, it is a half recording, and that is the part a
        // person cannot guess: the file plays and sounds fine.
        let message = ScreenRecordingPermission.notice(granted: false)?.message ?? ""

        #expect(message.contains("only your microphone"))
    }

    @Test("the card says where the switch is and that a restart is needed")
    func saysWhereAndWhen() {
        let message = ScreenRecordingPermission.notice(granted: false)?.message ?? ""

        #expect(message.contains("System Settings"))
        #expect(message.contains("Screen Recording"))
        // The grant is read at process start, so a card that omitted this would send the user
        // back to a working app that still fails.
        #expect(message.contains("restart" ) || message.contains("again"))
    }

    @Test("the settings link opens the Screen Recording pane")
    func linkNamesThePane() {
        let url = ScreenRecordingPermission.settingsURL

        #expect(url.hasPrefix("x-apple.systempreferences:"))
        #expect(url.contains("Privacy_ScreenCapture"))
    }

    @Test("the card names the state where the switch is on but belongs to a copy that is gone")
    func saysWhyAnOnSwitchStillAsks() {
        // macOS keeps the grant for the exact copy of the app that asked, and this app replaces
        // itself when it updates. The person then sees a switch that is on and an app that still
        // asks, and the card's old instructions led nowhere. The repair has to be on the card.
        let message = ScreenRecordingPermission.notice(granted: false)?.message ?? ""

        #expect(message.contains("Reset Permission"))
        #expect(message.contains("copy"))
    }

    @Test("the reset forgets this app's record and nothing else")
    func resetNamesTheAppAndTheService() {
        let arguments = ScreenRecordingPermission.resetArguments(
            bundleIdentifier: "local.callrecorder.app"
        )

        #expect(arguments == ["reset", "ScreenCapture", "local.callrecorder.app"])
        #expect(ScreenRecordingPermission.resetExecutable.path == "/usr/bin/tccutil")
    }

    @Test("after the record is cleared the card asks for a switch and a restart")
    func askedAgainSaysWhatIsLeft() {
        let notice = ScreenRecordingPermission.notice(granted: false, askedAgain: true)

        #expect(notice?.title == "Screen Recording permission is needed")
        let message = notice?.message ?? ""
        #expect(message.contains("cleared"))
        #expect(message.contains("restart"))
        // The state does not outlive the problem: a grant that arrives still takes the card away.
        #expect(ScreenRecordingPermission.notice(granted: true, askedAgain: true) == nil)
    }
}
