import Foundation
import Testing
@testable import CallRecorderCore

@Suite("Call briefs")
struct CallSummaryTests {
    @Test("the brief is asked for in the language the call was held in")
    func systemPromptKeepsTheLanguageOfTheCall() {
        let system = SummaryPrompt.system()

        #expect(system.contains("Write in the language the call was held in"))
        #expect(system.contains("Never write Speaker 1 when the"))
        #expect(system.contains("under 150 words"))
        for section in ["## About", "## Decisions", "## To do", "## Open", "## Numbers"] {
            #expect(system.contains(section))
        }
    }

    @Test("one pass carries what is known about the call and the words that were said")
    func userPromptCarriesTheCallAndTheTranscript() {
        let context = CallContext(
            startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            durationSeconds: 2_040,
            participants: ["Dana Holt", "Ilya Marsh"],
            language: "en"
        )

        let prompt = SummaryPrompt.user(transcript: "Dana Holt: Let us start.", context: context)

        #expect(prompt.contains("Length: 34 minutes."))
        #expect(prompt.contains("People on the call: Dana Holt, Ilya Marsh."))
        #expect(prompt.contains("The transcript says this language: en."))
        #expect(prompt.contains("Transcript:\nDana Holt: Let us start."))
        // The language rule is repeated after the transcript, where the model that has just read
        // the call still looks. A Russian call answered in English is the failure it prevents.
        #expect(prompt.hasSuffix("Write the brief in English."))
    }

    @Test("a part says which part it is, and the last pass is given every part brief")
    func longCallsAreReadInPartsAndMerged() {
        let part = SummaryPrompt.user(
            transcript: "words",
            context: CallContext(),
            part: (index: 1, count: 4)
        )
        #expect(part.contains("This is part 2 of 4 of the call"))

        let merged = SummaryPrompt.merge(
            briefs: ["first", "second"],
            context: CallContext(participants: ["Dana Holt"])
        )
        #expect(merged.contains("read in 2"))
        #expect(merged.contains("Brief of part 1:\nfirst"))
        #expect(merged.contains("Brief of part 2:\nsecond"))
        #expect(merged.contains("People on the call: Dana Holt."))
    }

    @Test("a call whose language is known asks for the brief in that language")
    func theBriefIsAskedForInTheLanguageOfTheCall() {
        let russian = CallContext(language: "ru")
        #expect(russian.languageInstruction == "Write the brief in Russian.")

        let english = CallContext(language: "en")
        #expect(english.languageInstruction == "Write the brief in English.")

        let prompt = SummaryPrompt.user(
            transcript: "Dana Holt: Let us start.",
            context: russian
        )
        #expect(prompt.hasSuffix("\n\nWrite the brief in Russian."))

        // A code no language answers to leaves the model to read the language off the call, and a
        // context that never learned one asks for nothing at all.
        #expect(CallContext(language: "not-a-language").languageInstruction == nil)
        #expect(CallContext(language: "").languageInstruction == nil)
        #expect(CallContext().languageInstruction == nil)
    }

    @Test("lengths are written the way a person writes them")
    func lengthsReadAsSentences() {
        #expect(CallContext.duration(30) == "1 minute")
        #expect(CallContext.duration(60) == "1 minute")
        #expect(CallContext.duration(12 * 60 + 30) == "12 minutes")
        #expect(CallContext.duration(60 * 60) == "1 hour")
        #expect(CallContext.duration(95 * 60) == "1 hour 35 minutes")
        #expect(CallContext.duration(120 * 60) == "2 hours")
    }

    @Test("the header and the app's bold marks come off before the model reads it")
    func theTranscriptIsReadWithoutItsHeader() {
        let markdown = """
            # Call with Dana Holt

            Participants: Dana Holt, Ilya Marsh
            Date: 18 September 2026

            **Dana Holt**: Right, let us start.

            **Ilya Marsh**: The card comes to four percent more.
            """

        let text = SummaryTranscript.plainText(fromMarkdown: markdown)

        #expect(!text.contains("**"))
        #expect(!text.contains("Participants:"))
        #expect(text.hasPrefix("Dana Holt: Right, let us start."))
        #expect(text.contains("Ilya Marsh: The card comes to four percent more."))
    }

    @Test("a long call is cut on its line breaks and nothing is lost")
    func aLongTranscriptIsSplitWithoutLosingWords() {
        let line = "Dana Holt: A sentence that goes on for a while.\n"
        let text = String(repeating: line, count: 40)

        let parts = SummaryTranscript.parts(of: text, maxCharacters: 300)

        #expect(parts.count > 1)
        for part in parts {
            #expect(part.count <= 300)
            #expect(!part.hasPrefix(" "))
            #expect(!part.hasSuffix(" "))
        }
        // Nothing is dropped but the whitespace the cut lands on, which is what makes a long call
        // safe to read in parts.
        let squeezed = { (value: String) in value.filter { !$0.isWhitespace } }
        #expect(squeezed(parts.joined()) == squeezed(text))
    }

    @Test("a line longer than the limit is kept whole rather than cut in half")
    func anOverlongLineIsKeptWhole() {
        let text = String(repeating: "a", count: 500)

        let parts = SummaryTranscript.parts(of: text, maxCharacters: 100)

        #expect(parts == [text])
    }

    @Test("a call with a sentence in it is not worth a model run")
    func shortCallsAreNotWrittenUp() {
        #expect(!CallBrief.isWorthWriting(transcriptCharacters: 120))
        #expect(CallBrief.isWorthWriting(transcriptCharacters: CallBrief.minimumCharacters))
        #expect(CallBrief.modelID == SupportingModel.callBriefID)
    }

    @Test("a brief is written once per call, replaced when it is written again, and dies with the call")
    func aBriefIsStoredBesideItsCall() async throws {
        let path = FileManager.default.temporaryDirectory
            .appending(path: "call-brief-\(UUID().uuidString).db").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try CallStore(path: path)
        try await store.migrate()
        let callID = CallID(rawValue: UUID())
        let otherCallID = CallID(rawValue: UUID())
        try await store.createCall(.started(id: callID, at: Date(timeIntervalSince1970: 1_800_000_000)))
        try await store.createCall(.started(id: otherCallID, at: Date(timeIntervalSince1970: 1_800_000_500)))

        #expect(try await store.summary(for: callID) == nil)

        let first = CallSummary(
            callID: callID,
            text: "## About\nThe launch.",
            modelID: CallBrief.modelID,
            generatedAt: Date(timeIntervalSince1970: 1_800_000_600),
            coveredSeconds: 900
        )
        try await store.saveSummary(first)
        #expect(try await store.summary(for: callID) == first)

        // A call that has no brief is absent from a list rather than present and empty, which is
        // what lets the row draw nothing at all.
        let listed = try await store.summaries(for: [callID, otherCallID])
        #expect(listed.count == 1)
        #expect(listed[callID] == first)

        let second = CallSummary(
            callID: callID,
            text: "## About\nThe launch, again.",
            modelID: CallBrief.modelID,
            generatedAt: Date(timeIntervalSince1970: 1_800_000_900),
            coveredSeconds: 1_200
        )
        try await store.saveSummary(second)
        #expect(try await store.summary(for: callID) == second)

        try await store.deleteCall(callID)
        #expect(try await store.summary(for: callID) == nil)
        #expect(try await store.summary(for: otherCallID) == nil)
        #expect(try await store.integrityReport().isHealthy)
    }

    @Test("a brief cannot be written for a call that does not exist")
    func aBriefNeedsItsCall() async throws {
        let path = FileManager.default.temporaryDirectory
            .appending(path: "call-brief-missing-\(UUID().uuidString).db").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try CallStore(path: path)
        try await store.migrate()
        let summary = CallSummary(
            callID: CallID(rawValue: UUID()),
            text: "## About\nNothing.",
            modelID: CallBrief.modelID,
            generatedAt: Date(),
            coveredSeconds: 0
        )

        await #expect(throws: CallStoreError.self) {
            try await store.saveSummary(summary)
        }
    }
}
