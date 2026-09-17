import Foundation
import Testing
@testable import CallRecorderApp

/// The two editor sheets state what an edit will do to transcripts already saved.
///
/// Both used to say that saved transcripts keep their wording. That was true when they were
/// written and stopped being true when the repairs were added: an alternative corrects the saved
/// files, and a renamed person is written into their headers. The claim is checked here because
/// the sheet is the one place a reader would not think to doubt it, and because the copy did not
/// move when the behaviour did.
@Suite("Editor claims")
struct EditorClaimTests {
    /// The words that made the promise the app no longer keeps.
    private let staleClaim = "keep their wording"

    @Test("the term sheet does not promise saved transcripts are left alone")
    func termSheetDoesNotPromise() {
        for isNew in [true, false] {
            let subtitle = GlossaryTermEditor.subtitle(isNew: isNew)
            #expect(!subtitle.localizedCaseInsensitiveContains(staleClaim))
            #expect(subtitle.isEmpty == false)
        }
    }

    @Test("the person sheet does not promise saved transcripts are left alone")
    func personSheetDoesNotPromise() {
        for isNew in [true, false] {
            let subtitle = ParticipantEditor.subtitle(isNew: isNew)
            #expect(!subtitle.localizedCaseInsensitiveContains(staleClaim))
            #expect(subtitle.isEmpty == false)
        }
    }

    @Test("editing a term says where the correction is applied")
    func termSheetNamesTheRepair() {
        let subtitle = GlossaryTermEditor.subtitle(isNew: false)

        // The reader has to be able to act on it, so the line names the button that does it.
        #expect(subtitle.contains("saved transcripts"))
        #expect(subtitle.contains("Re-apply"))
    }

    @Test("editing a person says where the correction is applied")
    func personSheetNamesTheRepair() {
        let subtitle = ParticipantEditor.subtitle(isNew: false)

        #expect(subtitle.contains("saved transcripts"))
        #expect(subtitle.contains("Fix Transcript Names"))
    }

    @Test("a new term or person keeps its own wording")
    func newEntriesHaveTheirOwnCopy() {
        // The add sheets are about spelling, not about repairing a library, and the two must not
        // read as the same sentence.
        #expect(GlossaryTermEditor.subtitle(isNew: true) != GlossaryTermEditor.subtitle(isNew: false))
        #expect(ParticipantEditor.subtitle(isNew: true) != ParticipantEditor.subtitle(isNew: false))
    }
}

