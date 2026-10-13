import CallRecorderCore
import Testing
@testable import CallRecorderApp

/// The menu bar icon's blink while a recording runs.
///
/// The icon is the one surface visible while the app is closed, so the rule that decides when it
/// moves is checked here rather than only looked at in a render: a blink that outlived its
/// recording, or one that ignored Reduce Motion, would both be found by the person it disturbs.
@Suite("Menu bar blink")
struct MenuBarBlinkTests {
    @Test("the icon blinks while a recording runs and stands still in every other state")
    func blinksOnlyWhileRecording() {
        #expect(MenuBarView.statusItemBlinks(phase: .recording, reduceMotion: false))
        #expect(!MenuBarView.statusItemBlinks(phase: .idle, reduceMotion: false))
        #expect(!MenuBarView.statusItemBlinks(phase: .paused, reduceMotion: false))
        #expect(!MenuBarView.statusItemBlinks(phase: .finalizing, reduceMotion: false))
        #expect(!MenuBarView.statusItemBlinks(phase: .awaitingParticipants, reduceMotion: false))
        #expect(!MenuBarView.statusItemBlinks(phase: .transcribing, reduceMotion: false))
        #expect(!MenuBarView.statusItemBlinks(phase: .indexing, reduceMotion: false))
        #expect(!MenuBarView.statusItemBlinks(phase: .failed, reduceMotion: false))
    }

    @Test("Reduce Motion keeps the icon still")
    func reduceMotionStopsTheBlink() {
        // The setting exists because movement costs some people something, and the state is still
        // said by the glyph: a filled record circle while a recording runs.
        #expect(!MenuBarView.statusItemBlinks(phase: .recording, reduceMotion: true))
        #expect(!MenuBarView.statusItemBlinks(phase: .idle, reduceMotion: true))
    }

    @Test("the blink is paced like a heartbeat, not a flicker")
    func thePaceIsAReadableOne() {
        #expect(MenuBarView.blinkIntervalMilliseconds >= 400)
        #expect(MenuBarView.blinkIntervalMilliseconds <= 1_000)
    }
}

