import Foundation
import Testing
@testable import CallRecorderCore

/// The test that decides a recording holds no speech, and therefore that its file is removed.
///
/// This is the narrowest rule in the project and the only one whose wrong answer destroys data, so
/// the cases that matter are the ones where it must say no. They are not invented: every transcript
/// it has to keep is a recording that was actually measured against the rule and flagged by the
/// wider test the app uses elsewhere. Four recordings of 6 680, 18 136, 56 461 and 69 819
/// characters were nearly deleted by that wider test, and three of these cases are built from their
/// real openings.
@Suite("Silence-only transcripts")
struct SilenceOnlyTranscriptTests {
    // MARK: - What it must catch

    @Test("each of the three files in the library that held nothing is caught")
    func catchesTheRealOnes() {
        #expect(TranscriptArtifacts.holdsOnlySilence("Thank you for watching.\nI hope you enjoyed this video."))
        #expect(TranscriptArtifacts.holdsOnlySilence("Thank you for watching.\nSee you next time."))
        #expect(TranscriptArtifacts.holdsOnlySilence("Thank you for watching.\n1, 2, 3, 1, 2, 3, 1, 2, 3."))
    }

    @Test("a recording of counting is caught whether it is written in digits or in words")
    func catchesCounting() {
        #expect(TranscriptArtifacts.holdsOnlySilence("One, two, three, four, five."))
        #expect(TranscriptArtifacts.holdsOnlySilence("1, 2, 3, 4, 5."))
        #expect(TranscriptArtifacts.holdsOnlySilence("раз, два, три"))
    }

    @Test("markers and phrases together are still nothing")
    func catchesMixedSilence() {
        #expect(TranscriptArtifacts.holdsOnlySilence("[музыка]\nThank you for watching.\n[Pause]"))
        #expect(TranscriptArtifacts.holdsOnlySilence("(Music)\nПродолжение следует..."))
    }

    // MARK: - What it must never catch

    @Test("one line of real speech anywhere keeps the recording")
    func keepsAnythingReal() {
        let real = [
            // The real opening of the 18 136-character call the wide test flagged.
            "So, that's it for today.\nThank you for watching.",
            // And of the 69 819-character one.
            "[Подписываюся на канал, ставлю лайки и подписываюся на канал]\nHeroku Proxy is the same as the CLI.",
            // And of the 6 680-character one.
            "Давайте потихоньку начнем, Джон.\n\nОкей, окей, ладно.",
            "[музыка]\nLet's start the meeting.",
        ]
        for text in real {
            #expect(!TranscriptArtifacts.holdsOnlySilence(text), "this recording is real and was nearly lost")
        }
    }

    @Test("the words a person really repeats are not silence")
    func keepsRepeatedSpeech() {
        // Every one of these is in the library as somebody's actual words. A rule built on length
        // or on repetition would take them; this one asks what each line is instead.
        for said in ["Okay.", "Yeah.", "Спасибо.", "Hello.", "Bye.", "Поехали.", "No."] {
            #expect(!TranscriptArtifacts.holdsOnlySilence(said), "\(said) is speech")
        }
        #expect(!TranscriptArtifacts.holdsOnlySilence("Okay.\nYeah.\nOkay."))
    }

    @Test("counting said inside a conversation is not a recording of counting")
    func keepsCountingInAConversation() {
        // A warehouse person does say a count out loud. It is only the rule's requirement that
        // *every* line be a count that makes it safe to treat a pure count as a test signal.
        #expect(!TranscriptArtifacts.holdsOnlySilence("One, two, three, four, five.\nNow the second pallet."))
        #expect(!TranscriptArtifacts.holdsOnlySilence("How many?\nOne, two, three."))
    }

    @Test("a phrase that is only part of a sentence does not make the line silence")
    func keepsPhrasesInsideSentences() {
        #expect(!TranscriptArtifacts.holdsOnlySilence("I said thank you for watching the demo."))
        #expect(!TranscriptArtifacts.holdsOnlySilence("He asked us to subscribe to the feed."))
        #expect(!TranscriptArtifacts.holdsOnlySilence("So, that is the whole thing for today, thanks."))
    }

    @Test("empty text is not a silence-only transcript")
    func refusesToJudgeNothing() {
        // Nothing to remove is not the same as something to remove, and an empty body means the
        // caller has no transcript to judge rather than one that is empty of speech.
        #expect(!TranscriptArtifacts.holdsOnlySilence(""))
        #expect(!TranscriptArtifacts.holdsOnlySilence("\n\n  \n"))
    }
}
