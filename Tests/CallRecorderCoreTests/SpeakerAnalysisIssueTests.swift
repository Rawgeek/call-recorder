import CallRecorderCore
import Foundation
import Testing
@testable import CallRecorderApp

/// Which failed separations are worth asking about again once the voice-profile key is read.
///
/// The answer decides whether a call is re-queued by itself. Too narrow and a call whose only
/// problem was a locked keychain stays failed, which is what happened to the 2026-09-24 11:13 call;
/// too wide and the app starts separations nobody asked for.
@Suite("Calls waiting for the voice-profile key")
struct SpeakerAnalysisIssueTests {
    @Test("a separation refused for want of the key is one to ask about again")
    func anIdentityFailureIsRecognised() {
        #expect(
            SpeakerAnalysisIssue.waitedForVoiceIdentity(
                details: "CallRecorderApp.SpeakerReviewError.identityUnavailable",
                summary: nil
            )
        )
        // The words can arrive in either half of the record, and the summary is what the stage
        // writes when there are no details.
        #expect(
            SpeakerAnalysisIssue.waitedForVoiceIdentity(
                details: nil,
                summary: "SpeakerReviewError.identityUnavailable"
            )
        )
    }

    @Test("a separation that failed for its own reasons is left alone")
    func otherFailuresAreLeftAlone() {
        #expect(
            !SpeakerAnalysisIssue.waitedForVoiceIdentity(
                details: "CallRecorderApp.DiarizerError.noSpeakersDetected",
                summary: "Background processing failed."
            )
        )
        #expect(
            !SpeakerAnalysisIssue.waitedForVoiceIdentity(
                details: "Traceback (most recent call last): scriptFailed",
                summary: nil
            )
        )
    }

    @Test("a call with nothing recorded about its failure is left alone")
    func anUnrecordedFailureIsLeftAlone() {
        #expect(!SpeakerAnalysisIssue.waitedForVoiceIdentity(details: nil, summary: nil))
        #expect(!SpeakerAnalysisIssue.waitedForVoiceIdentity(details: "", summary: ""))
    }
}

