import Foundation
import Testing
@testable import CallRecorderApp
@testable import CallRecorderCore

/// Which saved text a transcript file may be written back from.
///
/// The rule exists because a row can outlive its file. Writing a file back from the saved text is
/// what makes Open work, and writing one for a call that never held speech is worse than leaving
/// the row alone: the recordings folder would then hold a transcript of silence, under the same
/// kind of name as a real one, and nothing on the surface would say which was which.
@Suite("Restorable transcript text")
struct RestorableTranscriptTextTests {
    /// A paragraph of the length and shape a real call produces: many different lines, no line
    /// repeating more than a few times.
    private var spokenText: String {
        let lines = [
            "Yeah, I think so.",
            "Alright, let me share my screen.",
            "Can you see the dashboard now?",
            "This is the part I wanted to walk through.",
            "The numbers on the right are the ones that changed.",
            "We can pick this up tomorrow if it helps.",
            "No, that works for me.",
            "Let me note that down.",
        ]
        return (0..<40).map { lines[$0 % lines.count] }.joined(separator: "\n")
    }

    @Test("a real transcript is worth a file")
    @MainActor
    func spokenTextQualifies() {
        #expect(!AppModel.holdsNoSpeech(spokenText, language: "en"))
    }

    @Test("a call that captured only silence is not")
    @MainActor
    func silenceCapturesDoNotQualify() {
        // The three shapes the library holds: a music marker and a sign-off, the sign-off on its
        // own, and a bare marker.
        #expect(AppModel.holdsNoSpeech("(Music)\nThank you for watching.", language: "nn"))
        #expect(AppModel.holdsNoSpeech("Thank you for watching.", language: "nn"))
        #expect(AppModel.holdsNoSpeech("(Music)", language: "nn"))
        #expect(AppModel.holdsNoSpeech("", language: "nn"))
    }

    @Test("a hallucination loop is not speech however long it runs")
    @MainActor
    func repeatedLoopDoesNotQualify() {
        // This is the shape one real call holds, at full length: forty-two lines, 694 characters.
        // It is past any length floor, and every line says the same thing. Length alone would
        // have written it out as a transcript.
        let loop = String(repeating: "VAT (VAT)\n", count: 35)
            + String(repeating: "VAT (VAT, VAT, VAT, VAT, VAT, VAT, VAT, VAT, VAT)\n", count: 6)
            + "VAT (VAT, VAT, VAT, VAT, VAT, VAT, VAT, VAT)"
        #expect(loop.count >= 200, "the fixture must be past the length floor to mean anything")
        #expect(AppModel.holdsNoSpeech(loop, language: "nn"))
    }

    @Test("a short real answer is still refused for being short")
    @MainActor
    func shortSpeechIsRefused() {
        // The floor is deliberate: a few dozen characters is a model warming up or a single
        // syllable caught at the end, and a file built from it would claim a call was transcribed
        // when nearly nothing was said.
        #expect(AppModel.holdsNoSpeech("Yes. Okay.", language: "en"))
        #expect(AppModel.minimumRestorableTranscriptCharacters == 200)
    }
}

