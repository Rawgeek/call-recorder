import CallRecorderCore
import Foundation
import Testing
@testable import CallRecorderApp

@Suite("Speaker review call choices")
struct SpeakerReviewCallChoiceTests {
    @Test("all fifty named calls have a date before their timeline is opened")
    func olderNamedCallsKeepTheirDates() {
        let calls = (0..<50).map { index in
            RecentCallSummary(
                id: CallID(rawValue: UUID()),
                startedAt: Date(timeIntervalSince1970: 1_800_000_000 - Double(index * 3_600)),
                endedAt: nil,
                status: .ready,
                participantNames: [],
                hasTranscript: true,
                unresolvedSpeakerCount: 0
            )
        }

        let dates = AppModel.speakerReviewDates(for: calls)

        #expect(dates.count == 50)
        for call in calls {
            #expect(dates[call.id] == call.startedAt)
        }
    }

    @Test("an empty chooser has no stale dates")
    func emptyCallListClearsDates() {
        #expect(AppModel.speakerReviewDates(for: []).isEmpty)
    }
}
