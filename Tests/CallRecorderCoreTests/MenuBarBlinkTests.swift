import CallRecorderCore
import Testing
@testable import CallRecorderApp

/// The menu bar icon's blink while a recording runs.
///
/// The icon is the one surface visible while the app is closed, so the rule that decides when it
/// moves is checked here rather than only looked at in a render: a blink that outlived its
/// recording, or one that ignored Reduce Motion, would both be found by the person it disturbs.
@Suite("Menu bar blink")
@MainActor
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

    @Test("the blink runs while a recording does, and stops and brightens with it")
    func theBlinkFollowsTheRecording() async {
        // Given a blinker whose wait never returns, so the loop is parked inside the sleep and
        // the test sees one stable half rather than a race with the next one.
        let blinker = MenuBarBlinker()
        // The ambient accessibility setting is not this test's subject: a build machine reports
        // Reduce Motion as on, and the loop then never starts (found by CI on 2026-10-13).
        blinker.reducesMotion = { false }
        blinker.sleep = { _ in try await Task.sleep(for: .seconds(3_600)) }
        // Every half is reported as well as stored: the label listens to the owner, not to this
        // object, and a blink nobody republishes is a blink nobody sees (2026-10-13).
        var reported: [Bool] = []
        blinker.onDim = { reported.append($0) }

        // When a recording starts, the first half lands without waiting for the interval.
        blinker.update(shouldBlink: true)
        var spins = 0
        while !blinker.isDimmed, spins < 100 {
            await Task.yield()
            spins += 1
        }
        #expect(blinker.isDimmed)
        #expect(blinker.isBlinking)
        #expect(reported == [true])

        // A second "yes" is the same state, not a second blink.
        blinker.update(shouldBlink: true)
        #expect(blinker.isBlinking)

        // When the recording stops, the blink stops and the glyph is left bright.
        blinker.update(shouldBlink: false)
        #expect(!blinker.isBlinking)
        #expect(!blinker.isDimmed)
        #expect(reported == [true, false])
    }

    @Test("Reduce Motion keeps the blink from starting at all")
    func reduceMotionKeepsTheBlinkerStill() {
        let blinker = MenuBarBlinker()
        blinker.reducesMotion = { true }

        blinker.update(shouldBlink: true)

        #expect(!blinker.isBlinking)
        #expect(!blinker.isDimmed)
    }
}

