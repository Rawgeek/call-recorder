import CallRecorderCore
import Foundation
import Testing
@testable import CallRecorderApp

/// A brief written by the real model on this Mac.
///
/// The unit tests around the brief check the words that are sent and the shape of the answer. What
/// they cannot check is whether the model, the runtime that loads it, and the prompt actually
/// produce something worth reading. That costs a minute of this Mac's time and a model of two and
/// a half gigabytes, so it runs where those are and is skipped where they are not.
@Suite("Brief on this Mac")
struct BriefEndToEndTests {
    /// The brief model, from the app's own folder or from a path a run was pointed at.
    static var modelFile: URL? {
        if let configured = ProcessInfo.processInfo.environment["CALL_RECORDER_BRIEF_MODEL"] {
            let url = URL(filePath: configured)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        let support = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/CallRecorder", directoryHint: .isDirectory)
        guard let component = SupportingModel.catalog.first(where: { $0.id == CallBrief.modelID }),
            let name = component.ggufFileName
        else { return nil }
        let url = component.directory(in: support).appending(path: name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static var canWriteBrief: Bool {
        modelFile != nil && ToolLocator.standard.locate("llama-server") != nil
    }

    /// A call with a ticket in it, an agreement, a task, and a number, in the invented library the
    /// documentation uses.
    static let markdown = """
        # Call with Dana Holt

        Participants: Dana Holt, Ilya Marsh, Priya Raman
        Date: 18 September 2026

        **Dana Holt**: Right, let us start. The warehouse rate change for the three Vietnam lanes \
        is the first thing.

        **Ilya Marsh**: I checked the numbers this morning. The new card comes to about four \
        percent higher on the air lane, and lower on the two sea lanes. I put the comparison into \
        FS-20481.

        **Dana Holt**: Good. Does that change what we quote?

        **Ilya Marsh**: Not for the quotes already sent. Those hold until the end of the month. I \
        would like to apply the new card from the first of October.

        **Dana Holt**: Fine, apply it from the first of October, and put a note on the ticket.

        **Priya Raman**: One thing - the reconciliation report is showing a difference of 812 \
        dollars on the July invoices. I think we are picking up a duplicated charge.

        **Ilya Marsh**: That is the second time this month. Can you send me the invoice numbers?

        **Priya Raman**: I will send them today.

        **Dana Holt**: Priya, if it is a duplicate, raise it on the same ticket and I will look at \
        it on Monday. Anything else?

        **Priya Raman**: The carrier still has not answered about the damaged pallet. I will chase \
        them again tomorrow.

        **Dana Holt**: Thanks. Let us stop there.
        """

    @Test(
        "a real model writes a brief that names the ticket, the people, and the tasks",
        .enabled(if: BriefEndToEndTests.canWriteBrief)
    )
    func writesABriefWithTheRealModel() async throws {
        let runtime = try #require(ToolLocator.standard.locate("llama-server"))
        let model = try #require(Self.modelFile)
        let summarizer = Summarizer(runtime: runtime, model: model)

        let brief = try await summarizer.writeBrief(
            transcript: SummaryTranscript.plainText(fromMarkdown: Self.markdown),
            context: CallContext(
                startedAt: Date(timeIntervalSince1970: 1_789_718_400),
                durationSeconds: 15 * 60,
                participants: ["Dana Holt", "Ilya Marsh", "Priya Raman"],
                language: "en"
            )
        )

        // The brief is short, because that is the point of it.
        #expect(brief.count < 2_000)
        // It keeps the identifier somebody has to act on.
        #expect(brief.contains("FS-20481"))
        // It writes the names the transcript used, rather than a speaker number.
        #expect(brief.contains("Priya Raman") || brief.contains("Ilya Marsh"))
        #expect(!brief.lowercased().contains("speaker 1"))
        // And it is written as sections rather than as a paragraph of prose.
        #expect(brief.contains("##"))
    }
}
