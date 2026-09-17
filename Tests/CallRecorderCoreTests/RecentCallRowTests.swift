import Foundation
import Testing
@testable import CallRecorderApp
@testable import CallRecorderCore

@Suite("Recent call rows")
struct RecentCallRowTests {
    private func call(
        _ id: String,
        at date: Date,
        people: [String]
    ) -> RecentCallSummary {
        RecentCallSummary(
            id: CallID(rawValue: UUID(uuidString: id)!),
            startedAt: date,
            endedAt: date.addingTimeInterval(600),
            status: .ready,
            participantNames: people,
            hasTranscript: true
        )
    }

    private func day(_ offset: Int, hour: Int = 10, minute: Int = 0) -> Date {
        let calendar = Calendar(identifier: .gregorian)
        let base = calendar.date(byAdding: .day, value: offset, to: Date.now)!
        return calendar.date(
            bySettingHour: hour, minute: minute, second: 0, of: base
        )!
    }

    private let first = "11111111-1111-1111-1111-111111111111"
    private let second = "22222222-2222-2222-2222-222222222222"
    private let third = "33333333-3333-3333-3333-333333333333"

    @Test("a call that lost the other side always carries its chip")
    func missingOtherSideKeepsTheChip() {
        // A finished call normally says nothing on the row. A call whose other side was never
        // captured is the exception: the chip is the only thing on the row that says so.
        let finished = call(first, at: day(-1), people: ["Sam"])
        let oneSided = RecentCallSummary(
            id: finished.id,
            startedAt: finished.startedAt,
            endedAt: finished.endedAt,
            status: .ready,
            participantNames: finished.participantNames,
            hasTranscript: true,
            systemAudio: .missing
        )

        #expect(!RecentCallRow.rowNeedsStatusChip(for: finished, copied: false, hasSpeakerIssue: false))
        #expect(RecentCallRow.rowNeedsStatusChip(for: oneSided, copied: false, hasSpeakerIssue: false))
    }

    @Test("two calls with the same people on the same day both get their time")
    func repeatedRowsGetTheTime() {
        // The library holds nine pairs like this. Both rows read "Sam" over "Sep 11" and each
        // one holds a different transcript, so the row could not be chosen by reading it.
        let calls = [
            call(first, at: day(-4, hour: 10, minute: 15), people: ["Sam"]),
            call(second, at: day(-4, hour: 9, minute: 20), people: ["Sam"]),
        ]

        #expect(MenuBarView.rowsNeedingTheTime(calls) == [calls[0].id, calls[1].id])
    }

    @Test("a row that is already unique keeps the short label")
    func uniqueRowKeepsTheDateAlone() {
        let calls = [
            call(first, at: day(-4, hour: 10), people: ["Sam"]),
            call(second, at: day(-3, hour: 10), people: ["Sam"]),
            call(third, at: day(-4, hour: 10), people: ["Maya Prasad"]),
        ]

        #expect(MenuBarView.rowsNeedingTheTime(calls).isEmpty)
    }

    @Test("the time is only added where it is the thing that separates two rows")
    func onlyTheCollidingRowsChange() {
        let calls = [
            call(first, at: day(-4, hour: 10, minute: 15), people: ["Sam"]),
            call(second, at: day(-4, hour: 9, minute: 20), people: ["Sam"]),
            call(third, at: day(-2, hour: 14), people: ["Sam"]),
        ]

        let needing = MenuBarView.rowsNeedingTheTime(calls)

        #expect(needing.contains(calls[0].id))
        #expect(needing.contains(calls[1].id))
        #expect(!needing.contains(calls[2].id))
    }

    @Test("a row says how long its call ran, in the same shape every time")
    func aRowCarriesTheLengthOfItsCall() {
        let start = day(-1, hour: 9, minute: 30)
        let length = call(first, at: start, people: ["Sam"])
        let long = RecentCallSummary(
            id: length.id,
            startedAt: start,
            endedAt: start.addingTimeInterval(6_742),
            status: .ready,
            participantNames: ["Sam"],
            hasTranscript: true
        )

        // A ten-minute call and an hour and a bit of a call both carry all three fields, so the
        // lengths down a list can be read against each other without counting columns.
        #expect(length.lengthLabel == "0:10:00")
        #expect(long.lengthLabel == "1:52:22")
        #expect(CallLength.clock(0) == "0:00:00")
        #expect(CallLength.clock(59) == "0:00:59")
        #expect(CallLength.clock(3_661) == "1:01:01")
        // A length that is not a whole number of seconds is rounded rather than cut, and a clock
        // never goes backwards.
        #expect(CallLength.clock(59.6) == "0:01:00")
        #expect(CallLength.clock(-5) == "0:00:00")
    }

    @Test("a call that has not ended says nothing about its length")
    func aCallStillRunningHasNoLength() {
        let start = day(0, hour: 9, minute: 30)
        let running = RecentCallSummary(
            id: CallID(rawValue: UUID(uuidString: first)!),
            startedAt: start,
            endedAt: nil,
            status: .recording,
            participantNames: ["Sam"],
            hasTranscript: false
        )
        // A row that claims a length for a recording that is still running would be guessing, and
        // the summary is where the guess would come from.
        #expect(running.lengthLabel == nil)
    }

    @Test("the added time is readable and tells the two rows apart")
    func theTimeSeparatesTheRows() {
        // The label is what the reader sees, so it is checked as text and not only as a set.
        let morning = call(first, at: day(-4, hour: 10, minute: 15), people: ["Sam"])
        let earlier = call(second, at: day(-4, hour: 9, minute: 20), people: ["Sam"])

        let firstLabel = MenuBarView.whenLabel(for: morning, withTime: true)
        let secondLabel = MenuBarView.whenLabel(for: earlier, withTime: true)

        #expect(firstLabel != secondLabel)
        #expect(firstLabel.contains("10:15"))
        #expect(secondLabel.contains("9:20"))
        // The long form is only used where it is needed; the ordinary rows keep the short one.
        #expect(MenuBarView.whenLabel(for: morning).count < firstLabel.count)
    }
}
