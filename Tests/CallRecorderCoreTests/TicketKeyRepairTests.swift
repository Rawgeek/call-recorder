import Foundation
import Testing
@testable import CallRecorderCore

/// The ticket numbers the 2026-09-18 call lost, and the keys the same file still writes in full.
///
/// Every case here is a shape from that transcript: "182 86" split across two segments, "1867" for
/// FP-18167, "313" for FP-18313. None of them is a guess about what a number should be -- the repair
/// works against the keys the file itself holds, and a number with no key behind it is left alone.
@Suite("Ticket key repair")
struct TicketKeyRepairTests {
    @Test("a number the decoder clipped is written back as the key it belongs to")
    func repairsAClippedKey() {
        let text = [
            "Мы обсуждали FP-18167 и решили, что 1867 нужно доработать.",
            "Ещё есть FP-18313 и FP-18286.",
        ].joined(separator: "\n")

        let outcome = TicketKeyRepair.repairing(text)

        #expect(outcome.text.contains("FP-18167 нужно доработать"))
        #expect(!outcome.text.contains(" что 1867"))
        #expect(outcome.repairs == 1)
    }

    @Test("a number split across two segments is joined back into one key")
    func joinsASplitKey() {
        let segments = [
            TranscriptSegment(startMs: 0, endMs: 2_000, text: "Речь была про тикет FP-182"),
            TranscriptSegment(startMs: 2_000, endMs: 4_000, text: "86, и это важно."),
            TranscriptSegment(startMs: 4_000, endMs: 6_000, text: "FP-18286 уже в работе."),
        ]

        let outcome = TicketKeyRepair.repairing(segments: segments)

        #expect(outcome.segments[0].text == "Речь была про тикет FP-18286")
        #expect(outcome.segments[1].text == "и это важно.")
        #expect(outcome.repairs == 1)
    }

    @Test("a three-digit number is a ticket only where the line says so")
    func repairsAShortKeyOnlyInContext() {
        let withWord = "По тикету 313 нужно обновить FP-18313."
        let withoutWord = "На складе осталось 313 единиц, а FP-18313 закрыт."

        #expect(TicketKeyRepair.repairing(withWord).text == "По тикету FP-18313 нужно обновить FP-18313.")
        // The key is there all the same, and the sentence is talking about stock rather than about
        // the ticket. The word decides.
        #expect(TicketKeyRepair.repairing(withoutWord).text == withoutWord)
    }

    @Test("a number two keys could explain is left alone")
    func keepsAnAmbiguousNumber() {
        let text = "Тикет 167 и FP-18167, и ещё FP-9167."

        #expect(TicketKeyRepair.repairing(text).text == text)
    }

    @Test("a transcript with no key in it is not touched")
    func keepsTextWithoutKeys() {
        let text = "Мы обсудили 1867 позиций и 313 заказов, ключей в файле нет."

        let outcome = TicketKeyRepair.repairing(text)

        #expect(outcome.text == text)
        #expect(outcome.repairs == 0)
    }

    @Test("a key the call writes in full is not touched")
    func keepsAFullKey() {
        let text = "FP-18286 и FP-18167 в одном письме."

        let outcome = TicketKeyRepair.repairing(text)

        #expect(outcome.text == text)
        #expect(outcome.repairs == 0)
    }
}
