import Foundation
import Testing
@testable import CallRecorderApp

@Suite("Transcript participant line")
struct ParticipantHeaderTests {
    @Test("reads the participant line a transcript shows")
    func readsParticipantLine() {
        let markdown = """
            # Meeting Transcript

            Participants: Dana Holt, Sam
            Glossary: Globex (also Globexx)

            **Sam**: Hello.
            """
        #expect(storedParticipantHeader(in: markdown) == "Dana Holt, Sam")
    }

    @Test("reports no participant line when the transcript has none")
    func reportsMissingLine() {
        let markdown = """
            # Meeting Transcript

            **Sam**: Hello.
            """
        #expect(storedParticipantHeader(in: markdown) == nil)
    }

    @Test("a header that names a removed duplicate no longer matches the saved participants")
    func detectsStaleDuplicateName() {
        // This is the state left behind when two profiles for one person were merged.
        let markdown = """
            # Meeting Transcript

            Participants: Emma (Liza), Evan, Evan Novak, Sam
            """
        let saved = ["Emma (Liza)", "Evan", "Sam"].joined(separator: ", ")
        #expect(storedParticipantHeader(in: markdown) != saved)
    }

    @Test("a line of speech that opens with the same word is not read as the participant line")
    func ignoresTheSameWordsInsideTheBody() {
        // The search stops at the first line of speech. Reading on would find this line, take it
        // for the header, and rewrite what somebody said.
        let markdown = """
            # Meeting Transcript

            Participants: Dana Holt, Sam

            Participants: everyone who joined late should get the notes.
            """

        #expect(storedParticipantHeader(in: markdown) == "Dana Holt, Sam")
    }

    @Test("a name that differs only in case is the same person")
    func foldedNameFlattensCaseAndSpacing() {
        // The library holds one file whose line reads "Acme Team" against a stored "Acme Team",
        // and the repair has to see those as one entry to correct the spelling.
        #expect(AppModel.foldedName("Acme Team") == AppModel.foldedName("Acme Team"))
        #expect(AppModel.foldedName("Emma (Liza)") == AppModel.foldedName("Emma  (Liza)"))
        // Nothing else folds, so two different people never match.
        #expect(AppModel.foldedName("Alex Kim") != AppModel.foldedName("Alex Palmer"))
        #expect(AppModel.foldedName("Christy Ng") != AppModel.foldedName("Nicolia Ng"))
    }
}
