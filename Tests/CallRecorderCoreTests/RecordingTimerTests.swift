import Foundation
import Testing
@testable import CallRecorderApp

/// The popover clock counts recorded time, not sitting time.
///
/// The timer counted from the moment recording began and never stopped, so a call paused for ten
/// minutes read ten minutes longer than the audio it produced. Nothing is captured while paused, so
/// the number was the length of the sitting rather than of the recording, and the one number a
/// person checks to know whether the call is being captured was the one that lied about it.
@Suite("Recording timer")
struct RecordingTimerTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("a running recording counts from the start of its run")
    func runningCounts() {
        let elapsed = AppModel.recordedSeconds(
            banked: 0,
            currentRunStartedAt: start,
            paused: false,
            at: start.addingTimeInterval(90)
        )
        #expect(elapsed == 90)
    }

    @Test("a paused recording does not grow")
    func pausedDoesNotGrow() {
        // The whole fix: ten minutes of pause adds nothing. A number that kept climbing while no
        // audio was captured would say the recording was longer than the file it produced.
        for pause in [1.0, 600.0, 3_600.0] {
            let elapsed = AppModel.recordedSeconds(
                banked: 120,
                currentRunStartedAt: nil,
                paused: true,
                at: start.addingTimeInterval(pause)
            )
            #expect(elapsed == 120)
        }
    }

    @Test("a resumed recording adds to what it banked")
    func resumedAdds() {
        let elapsed = AppModel.recordedSeconds(
            banked: 120,
            currentRunStartedAt: start,
            paused: false,
            at: start.addingTimeInterval(30)
        )
        #expect(elapsed == 150)
    }

    @Test("several pauses add up to the recorded total")
    func severalPauses() {
        // Recorded 60, paused, recorded 30, paused, recording 10 more: 100 seconds of audio.
        let afterFirstRun = AppModel.recordedSeconds(
            banked: 0, currentRunStartedAt: start, paused: false,
            at: start.addingTimeInterval(60)
        )
        let afterSecondRun = AppModel.recordedSeconds(
            banked: afterFirstRun, currentRunStartedAt: start, paused: false,
            at: start.addingTimeInterval(30)
        )
        #expect(afterFirstRun == 60)
        #expect(afterSecondRun == 90)
        #expect(AppModel.recordedSeconds(
            banked: afterSecondRun, currentRunStartedAt: start, paused: false,
            at: start.addingTimeInterval(10)
        ) == 100)
    }

    @Test("a clock that disagrees with the recording cannot go backwards")
    func neverNegative() {
        // A clock change or a resumed run whose date is ahead of the reading would otherwise draw
        // a negative length, which a person would read as a fault in the app.
        #expect(AppModel.recordedSeconds(
            banked: -30, currentRunStartedAt: nil, paused: true, at: start
        ) == 0)
        #expect(AppModel.recordedSeconds(
            banked: 0, currentRunStartedAt: start, paused: false,
            at: start.addingTimeInterval(-5)
        ) == 0)
    }

    @Test("an idle model has nothing recorded")
    func idleIsZero() {
        #expect(AppModel.recordedSeconds(
            banked: 0, currentRunStartedAt: nil, paused: false, at: start
        ) == 0)
    }
}

