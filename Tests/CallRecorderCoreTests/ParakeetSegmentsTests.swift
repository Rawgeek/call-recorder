import CallRecorderCore
import Foundation
import Testing

/// The rules that turn a recogniser's timed words into the turns the transcript keeps.
struct ParakeetSegmentsTests {
    private func word(_ text: String, _ startMs: Int, _ endMs: Int) -> RecognizedWord {
        RecognizedWord(text: text, startMs: startMs, endMs: endMs)
    }

    @Test("words said without a pause are one turn")
    func wordsWithoutAPauseAreOneTurn() throws {
        let segments = ParakeetSegments.build(words: [
            word("The new card lands", 1_000, 2_000),
            word("on the first of October.", 2_100, 3_500),
        ])

        // Demanded rather than expected: a wrong count would make the lines below read past the
        // end of the list and end the whole run, which hides every test after this one.
        try #require(segments.count == 1)
        #expect(segments[0].startMs == 1_000)
        #expect(segments[0].endMs == 3_500)
        #expect(segments[0].text == "The new card lands on the first of October.")
    }

    @Test("a pause between two words ends the turn")
    func aPauseEndsTheTurn() throws {
        // The first word carries no punctuation, so nothing but the length of the silence between
        // them can end the turn: the sentence rule is not what this test is about.
        let segments = ParakeetSegments.build(words: [
            word("Understood", 1_000, 2_000),
            word("I will write both up today.", 3_000, 4_400),
        ])

        try #require(segments.count == 2)
        #expect(segments[0].text == "Understood")
        #expect(segments[1].startMs == 3_000)
    }

    @Test("a sentence ends the turn when a breath follows it")
    func aSentenceEndsTheTurnAtABreath() {
        let segments = ParakeetSegments.build(words: [
            word("The card changes on the first.", 1_000, 2_000),
            word("The surcharge moves with it.", 2_200, 3_000),
        ])

        #expect(segments.count == 2)
    }

    @Test("a sentence read on without a breath stays in its turn")
    func aSentenceWithoutABreathStaysInItsTurn() throws {
        let segments = ParakeetSegments.build(words: [
            word("Yes.", 1_000, 1_400),
            word("That is what I said.", 1_450, 2_600),
        ])

        try #require(segments.count == 1)
        #expect(segments[0].text == "Yes. That is what I said.")
    }

    @Test("a turn that never pauses is cut so no turn runs past twelve seconds")
    func aTurnWithoutAPauseIsCut() {
        // Sixteen words of 900 ms with a 50 ms breath between them: fifteen seconds of speech, which
        // the transcript has to hold as two turns rather than one.
        let words = (0..<16).map { index in
            word("word" + String(index), index * 950, index * 950 + 900)
        }
        let segments = ParakeetSegments.build(words: words)

        #expect(segments.count == 2)
        for segment in segments {
            #expect(segment.endMs - segment.startMs <= ParakeetSegments.maximumMilliseconds)
        }
        #expect(segments[0].text.hasPrefix("word0 word1"))
    }

    @Test("nothing said is no turn at all")
    func nothingSaidIsNoTurn() {
        #expect(ParakeetSegments.build(words: []).isEmpty)
        let blank = [RecognizedWord(text: "   ", startMs: 0, endMs: 100)]
        #expect(ParakeetSegments.build(words: blank).isEmpty)
    }

    @Test("a word with impossible times still lands in order")
    func aWordWithImpossibleTimesLandsInOrder() throws {
        // Three answers this app has to survive: a recogniser that reports an end before its start,
        // a negative start, and a word that reports no length at all. The words are still the words.
        let segments = ParakeetSegments.build(words: [
            word("First.", 500, 400),
            word("Second.", 4_000, 3_900),
        ])

        try #require(segments.count == 2)
        #expect(segments[0].startMs == 500)
        #expect(segments[0].endMs == 500)
        #expect(segments[1].startMs == 4_000)

        let negative = ParakeetSegments.build(words: [word("Third.", -200, 100)])
        try #require(negative.count == 1)
        #expect(negative[0].startMs == 0)
        #expect(negative[0].endMs == 100)

        #expect(segments.allSatisfy { $0.endMs >= $0.startMs })
    }

    @Test("words keep the language they were said in")
    func wordsKeepTheirLanguage() {
        let segments = ParakeetSegments.build(words: [
            word("Спасибо всем,", 0, 900),
            word("что присоединились.", 1_000, 2_000),
        ])

        #expect(segments.count == 1)
        #expect(segments[0].text == "Спасибо всем, что присоединились.")
    }

    @Test("turns are written in the order they were said, without gaps between them")
    func turnsAreWrittenInOrder() throws {
        let segments = ParakeetSegments.build(words: [
            word("One.", 1_000, 2_000),
            word("Two.", 3_500, 4_000),
            word("Three.", 6_000, 6_500),
        ])

        try #require(segments.count == 3)
        #expect(segments.map(\.startMs) == [1_000, 3_500, 6_000])
        for index in 1..<segments.count {
            #expect(segments[index].startMs >= segments[index - 1].endMs)
        }
    }
}

/// Which engine answers a call, as a decision table.
struct SpeechEngineChoiceTests {
    @Test("the chosen engine is honoured where Parakeet reads the language")
    func theChosenEngineIsHonoured() {
        #expect(
            SpeechEngineChoice.engine(requested: .parakeet, language: "ru", parakeetIsReady: true)
                == .parakeet
        )
        #expect(
            SpeechEngineChoice.engine(requested: .whisper, language: "ru", parakeetIsReady: true)
                == .whisper
        )
    }

    @Test("a language nobody named is answered by Parakeet, which detects it as it decodes")
    func anUnnamedLanguageIsAnsweredByParakeet() {
        for language in ["auto", "", "unknown", "AUTO"] {
            #expect(
                SpeechEngineChoice.engine(
                    requested: .parakeet,
                    language: language,
                    parakeetIsReady: true
                ) == .parakeet
            )
        }
    }

    @Test("a language Parakeet was not trained for is answered by whisper")
    func anUntrainedLanguageIsAnsweredByWhisper() {
        #expect(
            SpeechEngineChoice.engine(requested: .parakeet, language: "ja", parakeetIsReady: true)
                == .whisper
        )
        #expect(
            SpeechEngineChoice.engine(requested: .parakeet, language: "zh", parakeetIsReady: true)
                == .whisper
        )
    }

    @Test("a language that names its region is read by its first two letters")
    func aRegionalLanguageIsRead() {
        #expect(SpeechEngineChoice.parakeetReads("ru-RU"))
        #expect(SpeechEngineChoice.parakeetReads("EN"))
        #expect(SpeechEngineChoice.parakeetReads("uk_UA"))
        #expect(!SpeechEngineChoice.parakeetReads("ja-JP"))
    }

    @Test("a setting that cannot be honoured falls back to whisper rather than failing")
    func aMissingModelFallsBackToWhisper() {
        #expect(
            SpeechEngineChoice.engine(requested: .parakeet, language: "ru", parakeetIsReady: false)
                == .whisper
        )
        #expect(
            SpeechEngineChoice.engine(requested: .parakeet, language: "auto", parakeetIsReady: false)
                == .whisper
        )
    }

    @Test("the language table holds the languages it claims")
    func theTableHoldsItsLanguages() {
        #expect(SpeechEngineChoice.parakeetLanguages.count == 25)
        #expect(SpeechEngineChoice.parakeetLanguages.contains("ru"))
        #expect(SpeechEngineChoice.parakeetLanguages.contains("en"))
        #expect(!SpeechEngineChoice.parakeetLanguages.contains("ja"))
    }
}
