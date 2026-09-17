import Foundation
import Testing
@testable import CallRecorderCore

@Suite("Glossary usage ranking")
struct GlossaryUsageTests {
    private func term(_ preferred: String, aliases: [String] = []) -> GlossaryTerm {
        GlossaryTerm(id: GlossaryTermID(rawValue: UUID()), preferred: preferred, aliases: aliases)
    }

    @Test("terms used in recent transcripts come first")
    func ranksByRecentUse() {
        let terms = [term("Alpha"), term("Beta"), term("Gamma")]

        let ranked = GlossaryUsage.ranked(terms, usageCounts: ["gamma": 7, "alpha": 2])

        #expect(ranked.map(\.preferred) == ["Gamma", "Alpha", "Beta"])
    }

    @Test("terms that spell a participant name are listed separately")
    func findsTermsThatNameParticipants() {
        let terms = [term("Sam", aliases: ["Samuel"]), term("Globex"), term("Pat", aliases: ["Priya (Pat)"])]
        let participants = [Participant(id: ParticipantID(rawValue: UUID()), name: "Priya (Pat)")]

        let named = GlossaryUsage.namingParticipants(terms, participants: participants)

        // The participant is "Priya (Pat)", and the term "Pat" carries that alias.
        #expect(named.map(\.preferred) == ["Pat"])
    }

    @Test("an unused glossary keeps alphabetical order so the list does not jump around")
    func keepsAlphabeticalOrderWithoutUsage() {
        let terms = [term("Zulu"), term("alfa"), term("Mike")]

        let ranked = GlossaryUsage.ranked(terms, usageCounts: [:])

        #expect(ranked.map(\.preferred) == ["alfa", "Mike", "Zulu"])
    }
}
