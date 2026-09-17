import Foundation
import Testing
@testable import CallRecorderCore

/// The picker is typed into, so what it answers with is the whole feature.
@Suite("Participant search")
struct ParticipantSearchTests {
    private func person(_ name: String, company: String? = nil, email: String? = nil) -> Participant {
        Participant(
            id: ParticipantID(rawValue: UUID()),
            name: name,
            company: company,
            email: email
        )
    }

    @Test("a name that starts with what was typed comes first")
    func prefixBeatsContainment() {
        // Given a library where the typed word appears in the middle of one name and at the start
        // of another.
        let participants = [person("Ivan Lindqvist"), person("Lin Osei"), person("Anna Lindholm")]

        // When
        let matches = SpeakerReviewCandidates.matching(participants, query: "lin")

        // Then the name that starts with it leads. The other two match inside a word, and a tie
        // keeps the order the caller gave: the people on the call first, then name order.
        #expect(matches.map(\.name) == ["Lin Osei", "Ivan Lindqvist", "Anna Lindholm"])
    }

    @Test("any word of a name counts as a start")
    func wordStartsCount() {
        // Given a surname, which is what a search is usually typed with.
        let participants = [person("Nadia Rahimi"), person("Zoe Ferrante")]

        // When
        let matches = SpeakerReviewCandidates.matching(participants, query: "rahimi")

        // Then it finds the person whose surname it is, and nobody else.
        #expect(matches.map(\.name) == ["Nadia Rahimi"])
    }

    @Test("a first name that begins with the letters leads a surname that does")
    func nameStartBeatsWordStart() {
        // Given
        let participants = [person("Nadia Rahimi"), person("Rahima Osei")]

        // When
        let matches = SpeakerReviewCandidates.matching(participants, query: "rahim")

        // Then the person whose name begins with the letters comes first, and the one whose
        // surname matches follows.
        #expect(matches.map(\.name) == ["Rahima Osei", "Nadia Rahimi"])
    }

    @Test("a company or an address is searched when no name answers")
    func otherFieldsAreSearched() {
        // Given
        let participants = [
            person("Dana Holt", company: "Globex Freight", email: "dana@globex.example"),
            person("Someone Else", company: "Vendor"),
        ]

        // When
        let matches = SpeakerReviewCandidates.matching(participants, query: "globex")

        // Then
        #expect(matches.map(\.name) == ["Dana Holt"])
    }

    @Test("an empty search keeps the order it was given")
    func emptyQueryKeepsOrder() {
        // Given the people on the call first, which is how the picker is handed its list.
        let participants = [person("On Call"), person("Alpha"), person("Beta")]

        // Then an empty field offers everyone in that order rather than re-sorting them.
        #expect(SpeakerReviewCandidates.matching(participants, query: "   ").map(\.name)
            == ["On Call", "Alpha", "Beta"])
    }

    @Test("a name already in the library is not offered to be added")
    func exactMatchFindsAnExistingPerson() {
        // Given
        let participants = [person("Mira Halvorsen")]

        // Then the same name typed with different spacing or case is still that person, and a
        // different name is nobody.
        #expect(SpeakerReviewCandidates.exactMatch(participants, query: "  mira halvorsen ") != nil)
        #expect(SpeakerReviewCandidates.exactMatch(participants, query: "Mira") == nil)
        #expect(SpeakerReviewCandidates.exactMatch(participants, query: "   ") == nil)
    }
}
