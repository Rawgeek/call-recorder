import CallRecorderCore
import Foundation
import Testing
@testable import CallRecorderApp

@Suite("Renaming a transcript that has no metadata")
struct RenameTranscriptTests {
    @Test("renames the participant line and the speaker labels")
    func renamesBothPlaces() {
        let markdown = """
            # Meeting Transcript

            Participants: Sam Rivers, Nora
            Glossary: Sam (also Sams)

            **Sam Rivers**: Hello everyone.
            **Nora**: Hi.
            """
        let result = rewritingNames(in: markdown, renames: ["Sam Rivers": "Sam"])

        let updated = try? #require(result)
        #expect(updated?.markdown.contains("Participants: Sam, Nora") == true)
        #expect(updated?.markdown.contains("**Sam**: Hello everyone.") == true)
        #expect(updated?.markdown.contains("Sam Rivers") == false)
        #expect(updated?.replacements == 2)
    }

    @Test("leaves the file alone when no name matches")
    func keepsUnrelatedFile() {
        let markdown = "Participants: Nora\n\n**Nora**: Hi."
        #expect(rewritingNames(in: markdown, renames: ["Sam Rivers": "Sam"]) == nil)
    }

    @Test("keeps the rest of the transcript wording unchanged")
    func keepsWording() {
        let markdown = """
            # Meeting Transcript

            Participants: Sam Rivers
            Glossary: Globex (also Globexx)

            **Sam Rivers**: We ship to Hong Kong.
            """ + "\n"
        let result = rewritingNames(in: markdown, renames: ["Sam Rivers": "Sam"])
        let updated = try? #require(result)

        // The glossary line is not asserted here: the repair removes it before this runs, so what
        // a rename preserves is the wording of the call.
        #expect(updated?.markdown.contains("We ship to Hong Kong.") == true)
        #expect(updated?.markdown.hasSuffix("Hong Kong.\n") == true)
    }

    @Test("the file a rename writes carries no glossary line")
    func renameDropsTheGlossaryLine() {
        // The launch repair finds every file that still has the line, strips it, and hands the
        // stripped file to the rename. This pins that order: the line is gone before the names
        // are rewritten, so the file that lands on disk is the final shape.
        let markdown = "# Meeting Transcript\n\nParticipants: Sam Rivers\n"
            + "Glossary: Globex (also Globexx)\n\n**Sam Rivers**: We ship to Hong Kong.\n"
        let stripped = TranscriptRenderer.removingGlossaryLine(from: markdown)
        let result = stripped.flatMap { rewritingNames(in: $0, renames: ["Sam Rivers": "Sam"]) }
        let updated = result?.markdown ?? ""

        #expect(!updated.isEmpty)
        #expect(!updated.contains("Glossary:"))
        #expect(updated.contains("Participants: Sam\n"))
        #expect(updated.contains("**Sam**: We ship to Hong Kong."))
    }
}
