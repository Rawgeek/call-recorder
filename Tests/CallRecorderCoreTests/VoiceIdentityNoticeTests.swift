import Foundation
import Testing
@testable import CallRecorderApp
@testable import CallRecorderCore

/// The card the popover draws when voice matching cannot run.
///
/// The state it reads was live for a day with nothing on the top surface saying so, and the two
/// waits it tells apart are the reason the copy is checked here rather than only in a render.
@Suite("Voice identity notice")
struct VoiceIdentityNoticeTests {
    @Test("a working read adds no card to the popover")
    func availableAddsNoCard() {
        #expect(MenuBarView.voiceIdentityNotice(.available) == nil)
    }

    @Test("a read that has just started adds no card, because it finishes on its own")
    func checkingAddsNoCard() {
        #expect(MenuBarView.voiceIdentityNotice(.checking) == nil)
    }

    @Test("a read parked on the permission dialog says so and names the dialog")
    func waitingExplainsTheDialog() {
        let notice = MenuBarView.voiceIdentityNotice(.waitingForPermission)

        #expect(notice?.title == "Voice matching is paused")
        // The dialog opens behind another window, so the card has to say what to look for.
        #expect(notice?.message.contains("keychain") == true)
        #expect(notice?.message.contains("behind") == true)
        // A prompt that rendered on a second display sat unanswered for hours, so the card
        // names that place as well as the window behind.
        #expect(notice?.message.contains("another display") == true)
        // Allow is the button that brings the question back, and it is the one people press.
        #expect(notice?.message.contains("Always Allow") == true)
    }

    @Test("a failed read says matching is off and points at the error")
    func unavailableSaysOff() {
        let notice = MenuBarView.voiceIdentityNotice(.unavailable)

        #expect(notice?.title == "Voice matching is off")
        #expect(notice?.message.contains("Recovery") == true)
    }

    @Test("the two blocked states do not read as the same card")
    func theTwoBlockedStatesDiffer() {
        let waiting = MenuBarView.voiceIdentityNotice(.waitingForPermission)
        let failed = MenuBarView.voiceIdentityNotice(.unavailable)

        #expect(waiting?.title != failed?.title)
        #expect(waiting?.message != failed?.message)
    }
}
