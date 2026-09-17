import Foundation
import Testing
@testable import CallRecorderCore

/// The rule that takes out speech a transcript holds twice.
///
/// The cases are the shapes the library was measured on, with the words replaced: a turn that
/// opens with the last words of the turn above it, a turn that is nothing but that copy, and a
/// copy whose words are split across two turns. The tests that matter most are the ones that
/// assert what is kept, because a rule that removes a duplicate is only correct while it leaves
/// ordinary speech alone.
@Suite("Repeated speech")
struct TranscriptDeduplicatorTests {
    private func segment(
        _ startMs: Int,
        _ text: String,
        source: TranscriptAudioSource = .system
    ) -> TranscriptSegment {
        TranscriptSegment(
            startMs: startMs,
            endMs: startMs + 5_000,
            text: text,
            speakerIndex: 0,
            source: source
        )
    }

    private func filler(_ count: Int) -> String {
        (1...count).map { "ф\($0)" }.joined(separator: " ")
    }

    // MARK: - A copy is removed

    @Test("a turn that opens with the words of the turn above it loses the copy")
    func removesTheSeamCopy() {
        // Given: two turns whose opening words are the same speech cut in two places, which is
        // what a chunk seam produces.
        let segments = [
            segment(0, "Мы обсудили трекинг карты и решили начать на следующей неделе"),
            segment(5_000, "обсудили трекинг карты и решили начать на следующей неделе, "
                + "если никто не против"),
        ]

        // When
        let outcome = TranscriptDeduplicator.deduplicate(segments: segments)

        // Then: the first copy stays, and the words that followed the copy stay with it.
        #expect(outcome.removedRuns == 1)
        #expect(outcome.removedWords == 9)
        #expect(outcome.segments.count == 2)
        #expect(outcome.segments[0].text == segments[0].text)
        #expect(outcome.segments[1].text == "если никто не против")
    }

    @Test("the words around one the model spelt differently still come out")
    func removesTheWordsAroundADifferentSpelling() {
        // Given: the same sentence twice with one term written two ways, so the run is broken in
        // the middle and both halves have to stand on their own.
        let segments = [
            segment(0, "Сегодня покажу демо трекинга карты и потом отвечу на вопросы"),
            segment(5_000, "покажу демо трекинга каппи и потом отвечу на вопросы, которые пришли"),
        ]

        // When
        let outcome = TranscriptDeduplicator.deduplicate(segments: segments)

        // Then: the half that matches word for word goes, and the half that does not stays.
        #expect(outcome.removedRuns == 1)
        #expect(outcome.removedWords == 5)
        #expect(outcome.segments[1].text == "покажу демо трекинга каппи, которые пришли")
    }

    @Test("a copy split across two turns is removed from both of them")
    func removesACopyThatSpansTwoTurns() {
        // Given: the copy starts in one turn and finishes in the next.
        let segments = [
            segment(0, "начало один два три четыре пять шесть семь восемь девять"),
            segment(5_000, "один два три четыре пять шесть семь восемь девять"),
            segment(10_000, "десять одиннадцать двенадцать"),
        ]

        // When
        let outcome = TranscriptDeduplicator.deduplicate(segments: segments)

        // Then: the turn that held nothing but the copy goes.
        #expect(outcome.removedWords == 9)
        #expect(outcome.segments.count == 2)
        #expect(outcome.segments[0].text == segments[0].text)
        #expect(outcome.segments[1].text == "десять одиннадцать двенадцать")
    }

    @Test("the copy is removed across the two audio sources as well")
    func removesACopyThatArrivedOnBothSources() {
        // Given: the microphone heard what the speakers were playing, so the same speech arrives
        // on the other track a moment later.
        let segments = [
            segment(0, "если можно я попрошу пришли ответ по трекингу карты", source: .system),
            segment(5_000, "пришли ответ по трекингу карты на следующей неделе", source: .microphone),
        ]

        // When
        let outcome = TranscriptDeduplicator.deduplicate(segments: segments)

        // Then
        #expect(outcome.removedWords == 5)
        #expect(outcome.segments[1].text == "на следующей неделе")
    }

    // MARK: - Ordinary speech is kept

    @Test("four shared words are not a copy")
    func keepsAFourWordOverlap() {
        // Given: the longest overlap that reads as a copy but is ordinary speech.
        let segments = [
            segment(0, "Мы решили начать на следующей неделе"),
            segment(5_000, "начать на следующей неделе, если никто не против"),
        ]

        // When
        let outcome = TranscriptDeduplicator.deduplicate(segments: segments)

        // Then
        #expect(!outcome.didChange)
        #expect(outcome.segments == segments)
    }

    @Test("a run broken by one word heard differently is left where it is")
    func keepsARunBrokenByOneWord() {
        // Given: one sentence with a term the model wrote two ways in the two copies. The pass
        // cannot tell which spelling was said, so it keeps both copies rather than choosing.
        let segments = [
            segment(0, "Мы обсудили трекинг каппи и решили начать"),
            segment(5_000, "трекинг карты и решили начать на неделе"),
        ]

        // When
        let outcome = TranscriptDeduplicator.deduplicate(segments: segments)

        // Then
        #expect(!outcome.didChange)
    }

    @Test("two sentences that say different things are kept")
    func keepsTwoDifferentSentences() {
        // Given
        let segments = [
            segment(0, "Мы обсудили трекинг карты и решили начать в понедельник"),
            segment(5_000, "Мы посмотрели склада карты и решили отложить до пятницы"),
        ]

        // When
        let outcome = TranscriptDeduplicator.deduplicate(segments: segments)

        // Then
        #expect(!outcome.didChange)
    }

    @Test("the same sentence said again later in the meeting is kept")
    func keepsARepeatAcrossTheMeeting() {
        // Given: two copies of one sentence with 250 words between them, which is a person saying
        // it twice rather than one recording of it arriving twice.
        let segments = [
            segment(0, "Мы обсудили трекинг карты и решили начать на следующей неделе"),
            segment(5_000, filler(250)),
            segment(10_000, "Мы обсудили трекинг карты и решили начать на следующей неделе"),
        ]

        // When
        let outcome = TranscriptDeduplicator.deduplicate(segments: segments)

        // Then
        #expect(!outcome.didChange)
    }

    @Test("a short word said twice in a turn is kept")
    func keepsAShortWordSaidTwice() {
        // Given / When
        let outcome = TranscriptDeduplicator.deduplicate(
            segments: [segment(0, "Да, да, хорошо, хорошо, спасибо, спасибо.")]
        )

        // Then
        #expect(!outcome.didChange)
    }

    // MARK: - Text

    @Test("a line that held nothing but the copy is taken out of the text")
    func textPassDropsTheEmptiedLine() {
        // Given
        let text = [
            "Мы обсудили трекинг карты и решили начать на следующей неделе",
            "обсудили трекинг карты и решили начать на следующей неделе",
            "Хорошо, тогда идем дальше.",
        ].joined(separator: "\n")

        // When
        let outcome = TranscriptDeduplicator.deduplicate(text: text)

        // Then
        #expect(outcome.removedRuns == 1)
        #expect(outcome.text == [
            "Мы обсудили трекинг карты и решили начать на следующей неделе",
            "Хорошо, тогда идем дальше.",
        ].joined(separator: "\n"))
    }

    @Test("the punctuation a removed word left behind closes up")
    func textPassClosesTheGapAPunctuationLeft() {
        // Given: the copy sits in the middle of the turn, so the comma that followed it is left
        // with a space in front of it.
        let text = [
            "Сегодня покажу демо трекинга карты клиенту, и потом отвечу",
            "Хорошо, покажу демо трекинга карты клиенту, если успеем.",
        ].joined(separator: "\n")

        // When
        let outcome = TranscriptDeduplicator.deduplicate(text: text)

        // Then
        #expect(outcome.text == [
            "Сегодня покажу демо трекинга карты клиенту, и потом отвечу",
            "Хорошо, если успеем.",
        ].joined(separator: "\n"))
    }

    @Test("a text with nothing repeated is returned word for word")
    func textPassLeavesCleanTextAlone() {
        // Given
        let text = "Первая строка.\nВторая строка, и в ней ни одного повтора."

        // When
        let outcome = TranscriptDeduplicator.deduplicate(text: text)

        // Then
        #expect(outcome.removedRuns == 0)
        #expect(outcome.text == text)
    }
}
