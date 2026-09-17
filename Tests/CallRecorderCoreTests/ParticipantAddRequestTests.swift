import Foundation
import Testing
@testable import CallRecorderApp

/// The window has one way in for a typed name, and it carries that name into the editor.
///
/// The row under the list used to create the person itself from the name alone, while the
/// toolbar opened the editor that collects a role, a company, and an address. One job with two
/// outcomes and nothing on the surface to say which had been used. The row now opens the same
/// editor, so the name has to survive the trip and a blank field has to make no trip at all.
@Suite("Participant add requests")
struct ParticipantAddRequestTests {
    @Test("a typed name reaches the editor with its padding removed")
    func nameIsTrimmed() {
        let request = PendingParticipantName.typedName("  Nadia Rahimi\n")
        #expect(request?.name == "Nadia Rahimi")
    }

    @Test("a blank field makes no request")
    func blankMakesNoRequest() {
        for raw in ["", "   ", "\n\t"] {
            #expect(PendingParticipantName.typedName(raw) == nil)
        }
    }

    @Test("the same name twice is two requests, so the sheet reopens")
    func repeatedNameReopensTheSheet() {
        // A sheet presented on a name that never changes does nothing the second time, which
        // reads as a button that stopped working. The identity is what makes the second press
        // open the editor again.
        let first = PendingParticipantName.typedName("Sam")
        let second = PendingParticipantName.typedName("Sam")
        #expect(first?.id != second?.id)
        #expect(first?.name == second?.name)
    }

    @Test("the toolbar's blank editor is still allowed")
    func toolbarStillOpensAnEmptyEditor() {
        // Add Person opens the editor with nothing in it. That request is built directly rather
        // than through typedName, which refuses blank input.
        let request = PendingParticipantName(name: "")
        #expect(request.name.isEmpty)
    }
}
