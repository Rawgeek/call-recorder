import Foundation
import Testing
@testable import CallRecorderApp
@testable import CallRecorderCore

/// Whether the recent list actually draws the label it computes for a call with no speech.
///
/// The first version of this fix computed the words and left the chip hidden, because the chip is
/// drawn only when a row has something to say and a finished call was taken to have nothing. The
/// row then showed a time over a recording of an empty room, with the state sitting unused in the
/// code. These tests hold the two halves together: the words, and the decision to draw them.
@Suite("A recent row with no speech")
struct NoSpeechRowTests {
    private func call(
        hasTranscript: Bool = true,
        hasSpeech: Bool = true,
        status: CallStatus = .ready
    ) -> RecentCallSummary {
        RecentCallSummary(
            id: CallID(rawValue: UUID()),
            startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            endedAt: Date(timeIntervalSince1970: 1_800_000_600),
            status: status,
            participantNames: ["Sam"],
            hasTranscript: hasTranscript,
            hasSpeech: hasSpeech
        )
    }

    @Test("a finished call with no speech still gets a chip")
    func silentCallDrawsAChip() {
        // The row hides its chip for finished calls. A call with no speech is finished and still
        // has news, so the rule that hides the chip has to have this exception in it.
        #expect(
            RecentCallRow.rowNeedsStatusChip(
                for: call(hasSpeech: false),
                copied: false,
                hasSpeakerIssue: false
            )
        )
    }

    @Test("an ordinary finished call keeps drawing nothing")
    func spokenCallDrawsNothing() {
        #expect(
            RecentCallRow.rowNeedsStatusChip(
                for: call(),
                copied: false,
                hasSpeakerIssue: false
            ) == false
        )
    }

    @Test("a call still running gets a chip")
    func unfinishedCallDrawsAChip() {
        #expect(
            RecentCallRow.rowNeedsStatusChip(
                for: call(hasTranscript: false, hasSpeech: false, status: .recording),
                copied: false,
                hasSpeakerIssue: false
            )
        )
    }

    @Test("a call without a transcript at all gets a chip")
    func callWithoutTranscriptDrawsAChip() {
        #expect(
            RecentCallRow.rowNeedsStatusChip(
                for: call(hasTranscript: false, hasSpeech: false),
                copied: false,
                hasSpeakerIssue: false
            )
        )
    }

    @Test("a copy confirmation and a speaker problem keep their chips")
    func otherNewsKeepsItsChip() {
        #expect(
            RecentCallRow.rowNeedsStatusChip(for: call(), copied: true, hasSpeakerIssue: false)
        )
        #expect(
            RecentCallRow.rowNeedsStatusChip(for: call(), copied: false, hasSpeakerIssue: true)
        )
    }

    @Test("a silent call that is not finished yet is not labelled as having no speech")
    func onlyFinishedSilentCallsSayNoSpeech() {
        // While a call is being processed the row is about the work, not about the audio, and a
        // label saying the recording is empty would be wrong until the transcriber has answered.
        #expect(
            RecentCallRow.speaksAsNoSpeech(
                call(hasSpeech: false, status: .transcribing)
            ) == false
        )
        // The flag is what the label and the tone both read, so a call still being processed
        // cannot reach the muted No speech chip through either. It says its stage instead, and a
        // stage before the transcript exists is a call without one, which the rule covers.
        #expect(
            RecentCallRow.speaksAsNoSpeech(call(hasSpeech: false, status: .recording)) == false
        )
        #expect(
            RecentCallRow.speaksAsNoSpeech(call(hasSpeech: false, status: .failed)) == false
        )
    }
}
