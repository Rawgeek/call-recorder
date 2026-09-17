import Foundation
import Testing
@testable import CallRecorderApp

/// The popover is 360 points wide and the Recovery pane is not, so one message is shown at two
/// lengths. These check the rule that decides which half goes where, and that a refusal cannot
/// reach the surface wearing the tick that belongs to a success.
@Suite("Recovery notice")
struct RecoveryNoticeTests {
    @Test("a message with no detail is shown whole")
    func messageWithoutDetail() {
        let notice = RecoveryNotice(
            message: "Recording moved to Recently Deleted for 24 hours.",
            outcome: .done
        )
        #expect(notice.reason == "Recording moved to Recently Deleted for 24 hours.")
    }

    @Test("a refusal keeps its reason and drops the technical detail")
    func refusalDropsTheDetail() {
        // The shape a failed repair produces: the sentence a person needs, a blank line, then the
        // redacted trace that only belongs in a report.
        let notice = RecoveryNotice(
            message: "Voice profiles could not be opened. Unlock the login keychain, then retry."
                + "\n\n" + "KeychainError: errSecInteractionNotAllowed",
            outcome: .problem
        )
        #expect(
            notice.reason == "Voice profiles could not be opened. Unlock the login keychain, then retry."
        )
        #expect(!notice.reason.contains("errSecInteractionNotAllowed"))
    }

    @Test("a multi-line message keeps only its first line")
    func onlyTheFirstLine() {
        let notice = RecoveryNotice(message: "First.\nSecond.\nThird.", outcome: .done)
        #expect(notice.reason == "First.")
    }

    @Test("an empty message reports nothing rather than a stray newline")
    func emptyMessage() {
        #expect(RecoveryNotice(message: "", outcome: .done).reason.isEmpty)
    }

    @Test("carriage returns do not survive into the reason")
    func carriageReturns() {
        let notice = RecoveryNotice(message: "Reason.\r\nDetail.", outcome: .problem)
        #expect(notice.reason == "Reason.")
    }

    @Test("the outcome is carried, not derived from the wording")
    func outcomeIsNotInferred() {
        // The same words, reported both ways. A surface that decided from the text would draw
        // these identically, and would draw a failure as a success the first time a sentence was
        // reworded to say "could not be completed" without saying "failed".
        let text = "Nothing was changed."
        #expect(RecoveryNotice(message: text, outcome: .problem).outcome == .problem)
        #expect(RecoveryNotice(message: text, outcome: .done).outcome == .done)
    }
}
