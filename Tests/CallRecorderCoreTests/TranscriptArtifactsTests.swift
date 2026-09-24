import Foundation
import Testing
@testable import CallRecorderCore

/// The rules that decide what a transcript never said.
///
/// Every case here is taken from the library rather than invented, and the tests that matter most
/// are the ones that assert what is *kept*. A rule that removes a hallucination is only correct if
/// it leaves the speech around it where it was, and the shapes that look closest to a fault are the
/// ones a person really says: a short word repeated, and a sentence said twice.
@Suite("Transcript artefacts")
struct TranscriptArtifactsTests {
    // MARK: - Shapes taken from the library

    @Test("the glossary written back as speech is an echo, in each of its three recorded forms")
    func recognisesEveryRecordedEcho() {
        // The three forms the 174 lines in the library take.
        #expect(TranscriptArtifacts.isPromptEcho("WMS (also WMS, WMS)."))
        #expect(TranscriptArtifacts.isPromptEcho("VAT (VAT)"))
        #expect(TranscriptArtifacts.isPromptEcho("VAT (VAT, VAT, VAT, VAT, VAT, VAT, VAT, VAT, VAT)"))
        // A clipped decode of the same shape, which the library also holds once.
        #expect(TranscriptArtifacts.isPromptEcho("WM (also WMS, WMS)."))
    }

    @Test("a real aside in brackets is not an echo")
    func keepsARealParenthesis() {
        // Different words on each side of the bracket, and nothing repeated inside it. This is how
        // a person speaks an aside, and the rule has to leave it alone.
        #expect(!TranscriptArtifacts.isPromptEcho("Geodis (north) is billing us."))
        #expect(!TranscriptArtifacts.isPromptEcho("The WMS (our system) is down."))
        #expect(!TranscriptArtifacts.isPromptEcho("We shipped it (finally)."))
        #expect(!TranscriptArtifacts.isPromptEcho("Speaking."))
        #expect(!TranscriptArtifacts.isPromptEcho(""))
    }

    @Test("a line that is only a marker is not speech, in either language")
    func recognisesMarkers() {
        for marker in ["[музыка]", "[No audio]", "[Реклама]", "[Pause]", "[BLANK_AUDIO]",
                       "[смех]", "[Неразборчиво]", "[LAUGHTER]"] {
            #expect(TranscriptArtifacts.isNonSpeechTag(marker), "\(marker) should be a marker")
        }
    }

    @Test("a sentence that contains a bracket is speech")
    func keepsSpeechWithABracket() {
        #expect(!TranscriptArtifacts.isNonSpeechTag("So the invoice [for July] was posted."))
        #expect(!TranscriptArtifacts.isNonSpeechTag("Send it to Sam."))
        #expect(!TranscriptArtifacts.isNonSpeechTag(""))
    }

    // MARK: - The loop rule, and its floor

    @Test("a long sentence repeated five times keeps one copy")
    func collapsesALongLoop() {
        let line = "Я тут еще второй вопрос, как делать этот write, read?"
        let text = Array(repeating: line, count: 305).joined(separator: "\n")

        let outcome = TranscriptArtifacts.filter(text)

        #expect(outcome.text == line)
        #expect(outcome.loopDuplicates == 304)
    }

    @Test("a sentence said twice is left alone")
    func keepsATwiceSaidSentence() {
        // Ordinary emphasis, under the run floor. Removing this would be removing speech.
        let line = "Because we might end up even, you know, ditching the whole thing."
        let text = [line, line].joined(separator: "\n")

        let outcome = TranscriptArtifacts.filter(text)

        #expect(outcome.text == text)
        #expect(!outcome.didChange)
    }

    @Test("a short word repeated many times is left alone, however many times it is said")
    func keepsRepeatedShortSpeech() {
        // The library really holds these: a call ends with Спасибо said five times, and another
        // opens by agreeing twelve times. Every one of them is under the length floor.
        for said in ["Спасибо.", "Поехали.", "Hello.", "Всем пока.", "Okay.", "Yeah."] {
            let text = Array(repeating: said, count: 12).joined(separator: "\n")
            let outcome = TranscriptArtifacts.filter(text)
            #expect(outcome.text == text, "\(said) repeated is speech and was removed")
        }
    }

    @Test("a long line repeated below the run floor is left alone")
    func keepsFourCopies() {
        let line = "This is a sentence long enough to be caught by the length test, said four times."
        let text = Array(repeating: line, count: TranscriptArtifacts.loopMinimumRun - 1)
            .joined(separator: "\n")

        #expect(!TranscriptArtifacts.filter(text).didChange)
    }

    @Test("a phrase loop inside one line is cut back to one copy")
    func collapsesAPhraseLoopInsideOneLine() {
        // The 2026-09-18 call, verbatim: two words three times inside one segment, with a word
        // between the copies. The rule that looks at whole repeated lines cannot see this shape,
        // and the line was saved with the loop in it.
        let line = "межми грешен был межми грешен межми грешен смежим с миржем."

        let outcome = TranscriptArtifacts.filter(line)

        #expect(outcome.text == "межми грешен был смежим с миржем.")
        #expect(outcome.collapsedPhrases == 2)
        #expect(outcome.didChange)
    }

    @Test("a phrase a person repeats twice is left alone")
    func keepsAPhraseSaidTwice() {
        // Emphasis, not a loop: the phrase comes back twice and the rest of the sentence is
        // longer than the copies are.
        let line = "Мы обсудим это завтра, я не знаю, но давай сначала посмотрим заказ."

        #expect(!TranscriptArtifacts.filter(line).didChange)
    }

    @Test("one word repeated is speech, however many times it comes back")
    func keepsARepeatedSingleWord() {
        // A person says "no" three times. The shortest phrase the loop search looks for is two
        // words, which is what keeps this line out of it.
        for said in ["Нет, нет, нет.", "Да, да, да.", "Okay, okay, okay, thanks."] {
            #expect(!TranscriptArtifacts.filter(said).didChange, "\(said) is speech")
        }
    }

    @Test("the phrase loop is cut out of a segment before the segment is saved")
    func collapsesAPhraseLoopInSegments() {
        let segments = [
            TranscriptSegment(
                startMs: 0,
                endMs: 4_000,
                text: "межми грешен межми грешен межми грешен"
            )
        ]

        let cleaned = TranscriptArtifacts.filter(segments: segments)

        #expect(cleaned.segments.map(\.text) == ["межми грешен"])
        #expect(cleaned.outcome.collapsedPhrases == 2)
    }

    // MARK: - A whole transcript

    @Test("the speech around an artefact survives it, in order")
    func removesOnlyTheArtefact() {
        let text = [
            "**Sam**: WMS (also WMS, WMS).",
            "**Speaker 1**: Moving on to the next issue, storage.",
            "[музыка]",
            "**Sam**: WMS (also WMS, WMS).",
            "**Speaker 1**: Can we set the virtual warehouse storage to zero?",
        ].joined(separator: "\n")

        let outcome = TranscriptArtifacts.filter(text)

        #expect(outcome.text == [
            "**Speaker 1**: Moving on to the next issue, storage.",
            "**Speaker 1**: Can we set the virtual warehouse storage to zero?",
        ].joined(separator: "\n"))
        #expect(outcome.promptEchoes == 2)
        #expect(outcome.nonSpeechTags == 1)
        #expect(outcome.loopDuplicates == 0)
        #expect(outcome.removedLines == 3)
    }

    @Test("a transcript with nothing wrong is returned unchanged")
    func leavesACleanTranscriptAlone() {
        let text = [
            "# Meeting Transcript",
            "",
            "Participants: Sam",
            "",
            "**Sam**: Hello.",
            "**Speaker 1**: Hello. Thanks for joining.",
        ].joined(separator: "\n")

        let outcome = TranscriptArtifacts.filter(text)

        #expect(outcome.text == text)
        #expect(!outcome.didChange)
        #expect(outcome.removedLines == 0)
    }

    @Test("empty text is not a fault")
    func handlesEmpty() {
        #expect(TranscriptArtifacts.filter("") == TranscriptArtifacts.Outcome(text: ""))
    }

    @Test("the blank lines a removed line leaves behind are collapsed to one")
    func collapsesLeftoverBlankLines() {
        // A markdown transcript separates two segments with one blank line. Removing the segment
        // between them leaves two, and removing a run of them leaves a screen of whitespace.
        let text = [
            "**Speaker 1**: We shipped it.",
            "",
            "[музыка]",
            "",
            "[музыка]",
            "",
            "[музыка]",
            "",
            "**Speaker 1**: And it arrived.",
        ].joined(separator: "\n")

        let outcome = TranscriptArtifacts.filter(text)

        #expect(outcome.text == [
            "**Speaker 1**: We shipped it.",
            "",
            "**Speaker 1**: And it arrived.",
        ].joined(separator: "\n"))
        #expect(outcome.nonSpeechTags == 3)
    }

    @Test("blank lines that ran together are put back to one, with nothing removed")
    func normalisesBlankRunsOnTheirOwn() {
        // The transcript this app writes separates two segments with one blank line, so a run of
        // them is never the file's own formatting. It is what an earlier cleanup left behind, and
        // a transcript is read for what it says: whitespace costs the reader and the search index
        // the same as a line of invented text. This is the rule that lets a second pass tidy a
        // library a first pass already emptied of artefacts.
        let text = ["**Speaker 1**: Hello.", "", "", "", "**Speaker 2**: Hello."].joined(separator: "\n")

        let outcome = TranscriptArtifacts.filter(text)

        #expect(outcome.text == ["**Speaker 1**: Hello.", "", "**Speaker 2**: Hello."].joined(separator: "\n"))
        #expect(outcome.removedLines == 0)
        #expect(outcome.blankLinesCollapsed == 2)
        #expect(outcome.didChange)
    }

    @Test("a transcript that is already in the shape the app writes is returned byte for byte")
    func leavesACorrectlySpacedTranscriptAlone() {
        let text = ["**Speaker 1**: Hello.", "", "**Speaker 2**: Hello."].joined(separator: "\n")
        #expect(TranscriptArtifacts.filter(text).text == text)
        #expect(!TranscriptArtifacts.filter(text).didChange)
    }

    // MARK: - Segments, which are what the index is built from

    @Test("a segment that is only an artefact is dropped from the index, and a mixed one is not")
    func filtersSegments() {
        let segments = [
            TranscriptSegment(startMs: 0, endMs: 1000, text: "[музыка]"),
            TranscriptSegment(startMs: 1000, endMs: 2000, text: "We shipped it."),
            TranscriptSegment(startMs: 2000, endMs: 3000, text: "VAT (VAT)"),
            TranscriptSegment(startMs: 3000, endMs: 4000, text: "See the VAT (VAT) note."),
        ]

        let (kept, outcome) = TranscriptArtifacts.filter(segments: segments)

        #expect(kept.map(\.text) == ["We shipped it.", "See the VAT (VAT) note."])
        #expect(outcome.nonSpeechTags == 1)
        #expect(outcome.promptEchoes == 1)
    }

    @Test("a long segment repeated five times keeps its first copy and its timing")
    func collapsesSegmentLoop() {
        let line = "Поехали, давайте посмотрим на этот отчёт ещё раз вместе, хорошо?"
        let segments = (0..<5).map { index in
            TranscriptSegment(startMs: index * 1000, endMs: index * 1000 + 900, text: line)
        }

        let (kept, outcome) = TranscriptArtifacts.filter(segments: segments)

        #expect(kept.count == 1)
        #expect(kept[0].startMs == 0)
        #expect(kept[0].endMs == 900)
        #expect(outcome.loopDuplicates == 4)
    }

    // MARK: - Timestamps printed into the file

    @Test("a printed time range comes off the line and the words stay")
    func stripsPrintedTimestamps() {
        // Three transcripts in the library still carry one of these in front of every paragraph,
        // 1476 in a single file. The words after it are what somebody said.
        let text = "[00:00:11.840 → 00:00:41.740] Ну да, в общем, да, подготовлю."

        let outcome = TranscriptArtifacts.filter(text)

        #expect(outcome.text == "Ну да, в общем, да, подготовлю.")
        #expect(outcome.strippedTimestamps == 1)
        #expect(outcome.removedLines == 0)
        #expect(outcome.didChange)
    }

    @Test("the arrow symbols the app has written all count")
    func stripsEveryArrowShape() {
        for arrow in ["→", "->", "-->", "–", "-"] {
            let line = "[00:01:02.000 \(arrow) 00:01:04.000] Привет."
            let outcome = TranscriptArtifacts.filter(line)
            #expect(outcome.text == "Привет.", "\(arrow) should be a timestamp arrow")
        }
    }

    @Test("a spoken time is not a printed timestamp")
    func keepsSpokenTimes() {
        // The rule asks for two clock times joined by an arrow inside one pair of brackets at the
        // very start of the line. Anything with words around the number is somebody talking.
        let spoken = [
            "At 00:00:11 we shipped it.",
            "The meeting is [from 10:00 to 11:00].",
            "[00:00:11] was when it started, I think.",
            "Call me at 14:30.",
            "Мы начали в 10:30 и закончили в 11:00.",
        ]
        for line in spoken {
            let outcome = TranscriptArtifacts.filter(line)
            #expect(outcome.text == line, "\(line) should be untouched")
            #expect(outcome.strippedTimestamps == 0)
        }
    }

    @Test("a marker behind a timestamp is still a marker")
    func removesAMarkerBehindATimestamp() {
        // The strip runs first and the fixed point runs the rest, so a line that was only a
        // marker once its time was gone is removed rather than left as an empty line.
        let outcome = TranscriptArtifacts.filter("[00:00:00.000 → 00:00:04.160] [музыка]")

        #expect(outcome.text == "")
        #expect(outcome.strippedTimestamps == 1)
        #expect(outcome.nonSpeechTags == 1)
    }

    @Test("a time stamped transcript keeps every line of speech it had")
    func keepsEveryLineOfAStampedTranscript() {
        let text = [
            "[00:00:00.000 → 00:00:04.160] First thing said.",
            "[00:00:04.160 → 00:00:09.000] Second thing said.",
            "[00:00:09.000 → 00:00:12.000] Third thing said.",
        ].joined(separator: "\n")

        let outcome = TranscriptArtifacts.filter(text)

        #expect(outcome.text == "First thing said.\nSecond thing said.\nThird thing said.")
        #expect(outcome.strippedTimestamps == 3)
    }

    @Test("segments lose their printed time and keep their real one")
    func stripsSegmentTimestamps() {
        let segments = [
            TranscriptSegment(startMs: 11_840, endMs: 41_740, text: "[00:00:11.840 → 00:00:41.740] Подготовлю."),
            TranscriptSegment(startMs: 41_740, endMs: 56_740, text: "Спасибо."),
        ]

        let (kept, outcome) = TranscriptArtifacts.filter(segments: segments)

        #expect(kept.map(\.text) == ["Подготовлю.", "Спасибо."])
        #expect(kept[0].startMs == 11_840)
        #expect(outcome.strippedTimestamps == 1)
    }

    @Test("a transcript with no timestamp is returned byte for byte")
    func leavesCleanTextAlone() {
        let text = "**Sam**: Hello.\n\n**Nora**: Hi."

        let outcome = TranscriptArtifacts.filter(text)

        #expect(outcome.text == text)
        #expect(!outcome.didChange)
    }
}
