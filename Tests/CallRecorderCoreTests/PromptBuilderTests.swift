import Foundation
import Testing
@testable import CallRecorderCore

struct PromptBuilderTests {
    @Test func whisperContextIncludesParticipantsAndVocabulary() {
        let participants = [
            Participant(id: ParticipantID(rawValue: UUID()), name: "Alice"),
            Participant(id: ParticipantID(rawValue: UUID()), name: "Bob"),
        ]
        let glossary = [
            GlossaryTerm(
                id: GlossaryTermID(rawValue: UUID()),
                preferred: "Globex",
                aliases: ["Globexx"]
            )
        ]

        let context = PromptBuilder.whisperContext(participants: participants, glossary: glossary)

        // The prompt carries the correct spelling only. A wrong spelling in the prompt would
        // bias the model toward that wrong spelling.
        #expect(context == "A conversation with Alice and Bob. Domain terms: Globex.")
    }

    @Test func whisperContextSpendsTheBudgetOnTermsTheUserActuallySays() {
        let glossary = [
            GlossaryTerm(id: GlossaryTermID(rawValue: UUID()), preferred: "NeverSaid", aliases: []),
            GlossaryTerm(id: GlossaryTermID(rawValue: UUID()), preferred: "SaidOften", aliases: []),
            GlossaryTerm(id: GlossaryTermID(rawValue: UUID()), preferred: "SaidOnce", aliases: []),
        ]
        let usage = ["saidoften": 40, "saidonce": 1]

        let ordered = PromptBuilder.prioritizedTerms(
            glossary,
            participants: [],
            usageCounts: usage
        ).map(\.preferred)

        #expect(ordered == ["SaidOften", "SaidOnce", "NeverSaid"])
    }

    @Test func whisperContextKeepsThePayloadInsideTheBudgetWithUsageRanking() {
        let participants = [Participant(id: ParticipantID(rawValue: UUID()), name: "Sam")]
        let glossary = (0..<120).map { index in
            GlossaryTerm(
                id: GlossaryTermID(rawValue: UUID()),
                preferred: "Term\(index)",
                aliases: ["Alt \(index)", "Альт \(index)"]
            )
        }
        let usage = Dictionary(uniqueKeysWithValues: glossary.map {
            ($0.preferred.lowercased(), $0.preferred == "Term119" ? 5 : 1)
        })

        let context = PromptBuilder.whisperContext(
            participants: participants,
            glossary: glossary,
            usageCounts: usage
        )

        #expect(context.count <= PromptBuilder.whisperPromptCharacterBudget)
        #expect(context.contains("Sam"))
        // The term the user says most often survives even though the glossary is 120 terms long.
        #expect(context.contains("Term119"))
    }

    @Test func whisperContextWithSingleParticipant() {
        let participants = [
            Participant(id: ParticipantID(rawValue: UUID()), name: "Dana")
        ]

        let context = PromptBuilder.whisperContext(participants: participants, glossary: [])

        #expect(context == "A conversation with Dana.")
    }

    @Test func whisperContextKeepsNamesWhenTheGlossaryIsLong() {
        let participants = [
            Participant(id: ParticipantID(rawValue: UUID()), name: "Sam"),
            Participant(id: ParticipantID(rawValue: UUID()), name: "Priya (Pat)"),
            Participant(id: ParticipantID(rawValue: UUID()), name: "Dana Holt"),
        ]
        let glossary = (0..<60).map { index in
            GlossaryTerm(
                id: GlossaryTermID(rawValue: UUID()),
                preferred: "DomainTerm\(index)",
                aliases: ["Domain Term \(index)", "Домен \(index)"]
            )
        }

        let context = PromptBuilder.whisperContext(participants: participants, glossary: glossary)

        // whisper.cpp drops the front of a long prompt, so the names must survive the budget.
        for name in participants.map(\.name) {
            #expect(context.contains(name))
        }
        #expect(context.count <= PromptBuilder.whisperPromptCharacterBudget)
        #expect(!context.isEmpty)
    }

    @Test func whisperContextPutsParticipantNamesInFrontOfOtherTerms() {
        let participants = [Participant(id: ParticipantID(rawValue: UUID()), name: "Nora")]
        let glossary = [
            GlossaryTerm(id: GlossaryTermID(rawValue: UUID()), preferred: "AaaTerm", aliases: []),
            GlossaryTerm(id: GlossaryTermID(rawValue: UUID()), preferred: "Nora", aliases: []),
        ]

        let context = PromptBuilder.whisperContext(
            participants: participants,
            glossary: glossary,
            characterBudget: 60
        )

        // The name term keeps its place in front of the alphabetical term that came first.
        #expect(context == "A conversation with Nora. Domain terms: Nora; AaaTerm.")
    }

    @Test func whisperContextStopsAtTheBudget() {
        let glossary = (0..<40).map { index in
            GlossaryTerm(
                id: GlossaryTermID(rawValue: UUID()),
                preferred: "Term\(index)",
                aliases: []
            )
        }

        let context = PromptBuilder.whisperContext(
            participants: [],
            glossary: glossary,
            characterBudget: 80
        )

        #expect(context.count <= 80)
        #expect(context.hasPrefix("Domain terms: Term0; Term1"))
    }

    @Test func oneLongTermDoesNotEvictEveryShorterTerm() {
        // A working glossary mixes long entries, such as participant names with aliases, with
        // short ones. A long entry must not stop a short term from being sent.
        let glossary = [
            GlossaryTerm(
                id: GlossaryTermID(rawValue: UUID()),
                preferred: "SaidOften",
                aliases: ["Long Alias One", "Long Alias Two", "Long Alias Three"]
            ),
            GlossaryTerm(id: GlossaryTermID(rawValue: UUID()), preferred: "Globex", aliases: []),
            GlossaryTerm(id: GlossaryTermID(rawValue: UUID()), preferred: "RMA", aliases: []),
        ]
        let usage = ["saidoften": 30, "globex": 9, "rma": 20]

        let context = PromptBuilder.whisperContext(
            participants: [],
            glossary: glossary,
            usageCounts: usage,
            characterBudget: 60
        )

        #expect(context.contains("RMA"))
        #expect(context.contains("Globex"))
        #expect(context.count <= 60)
    }

    @Test func transcriptHeaderCarriesNoGlossaryLine() {
        // The terms belong in the prompt, where they can still change what the model hears. The
        // copy in the saved file was the same list at the top of every transcript, and it could
        // not change a word of any of them.
        let participants = [Participant(id: ParticipantID(rawValue: UUID()), name: "Sam")]
        let glossary = [
            GlossaryTerm(id: GlossaryTermID(rawValue: UUID()), preferred: "Sam", aliases: []),
        ] + (0..<80).map { index in
            GlossaryTerm(
                id: GlossaryTermID(rawValue: UUID()),
                preferred: "VeryLongDomainTermNumber\(index)",
                aliases: []
            )
        }

        let header = PromptBuilder.transcriptHeader(participants: participants)

        #expect(header == "# Meeting Transcript\n\nParticipants: Sam\n")
        #expect(!header.contains("Glossary:"))

        // The same terms still reach the model inside whisper's token budget.
        let context = PromptBuilder.whisperContext(participants: participants, glossary: glossary)
        #expect(context.contains("Sam"))
        #expect(context.count <= PromptBuilder.whisperPromptCharacterBudget)
    }

    @Test func transcriptHeaderStoresMetadataWithoutClaimingSpeakerLabels() {
        let participants = [Participant(id: ParticipantID(rawValue: UUID()), name: "Alice")]

        let header = PromptBuilder.transcriptHeader(participants: participants)

        #expect(header == "# Meeting Transcript\n\nParticipants: Alice\n")
    }

    @Test func bodyOfANewFileIsTheSpokenText() {
        let markdown = "# Meeting Transcript\n\nParticipants: Sam\n\nHello there.\n"

        #expect(TranscriptRenderer.body(of: markdown) == "Hello there.\n")
        #expect(
            TranscriptRenderer.replacingBody(of: markdown, with: "Goodbye.\n")
                == "# Meeting Transcript\n\nParticipants: Sam\n\nGoodbye.\n"
        )
    }

    @Test func bodyOfAFileWrittenBeforeTheGlossaryLineLeftIsTheSpokenText() {
        // Files with this shape are still on disk and are read by hand in the recovery window,
        // so the split has to land in the same place with the glossary line present or absent.
        let markdown = """
            # Meeting Transcript

            Participants: Sam
            Glossary: Globex (also Globexx), Geodis

            Hello there.
            """
            + "\n"
        let body = TranscriptRenderer.body(of: markdown)

        #expect(body == "Hello there.\n")
        #expect(
            TranscriptRenderer.replacingBody(of: markdown, with: "Goodbye.\n")
                == "# Meeting Transcript\n\nParticipants: Sam\nGlossary: Globex (also Globexx),"
                    + " Geodis\n\nGoodbye.\n"
        )
    }

    @Test func bodyOfPlainTextIsTheWholeFile() {
        let text = "Hello there.\nMore of it.\n"

        #expect(TranscriptRenderer.body(of: text) == text)
        #expect(TranscriptRenderer.replacingBody(of: text, with: "Replaced.") == "Replaced.")
    }

    @Test func removingTheGlossaryLineTouchesNothingElse() {
        let markdown = "# Meeting Transcript\n\nParticipants: Sam\n"
            + "Glossary: Globex (also Globexx)\n\n**Sam**: Hello there.\n"
        let stripped = TranscriptRenderer.removingGlossaryLine(from: markdown)

        #expect(stripped == "# Meeting Transcript\n\nParticipants: Sam\n\n**Sam**: Hello there.\n")
        // The body is the same text before and after, which is what makes this a tidy-up rather
        // than a rewrite of anything that was said.
        #expect(stripped.map(TranscriptRenderer.body(of:)) == TranscriptRenderer.body(of: markdown))
    }

    @Test func removingTheGlossaryLineLeavesOtherFilesAlone() {
        #expect(
            TranscriptRenderer.removingGlossaryLine(
                from: "# Meeting Transcript\n\nParticipants: Sam\n\nHello.\n"
            ) == nil
        )
        #expect(TranscriptRenderer.removingGlossaryLine(from: "Hello there.\n") == nil)
    }

    @Test func rendererOutputsNoTimestamps() {
        let transcript = WhisperTranscript(
            language: "en",
            segments: [
                TranscriptSegment(startMs: 0, endMs: 1_250, text: "Hello."),
                TranscriptSegment(startMs: 2_000, endMs: 3_500, text: "Hi there."),
            ]
        )

        let markdown = TranscriptRenderer.markdown(
            transcript: transcript,
            participants: []
        )

        #expect(!markdown.contains("[00:"))
        #expect(!markdown.contains("→"))
        #expect(markdown.contains("Hello."))
        #expect(markdown.contains("Hi there."))
    }

    @Test func rendererStripsFillerTags() {
        let transcript = WhisperTranscript(
            language: "en",
            segments: [
                TranscriptSegment(startMs: 0, endMs: 1_000, text: "Hello."),
                TranscriptSegment(startMs: 1_000, endMs: 2_000, text: "[music] Song plays"),
                TranscriptSegment(startMs: 2_000, endMs: 3_000, text: "[silence]"),
                TranscriptSegment(startMs: 3_000, endMs: 4_000, text: "World."),
            ]
        )

        let markdown = TranscriptRenderer.markdown(
            transcript: transcript,
            participants: []
        )

        #expect(!markdown.contains("[music]"))
        #expect(!markdown.contains("[silence]"))
        #expect(markdown.contains("Song plays"))
        #expect(markdown.contains("Hello."))
        #expect(markdown.contains("World."))
    }

    @Test func rendererUsesSpeakerLabelsWhenParticipantsProvided() {
        let transcript = WhisperTranscript(
            language: "en",
            segments: [
                TranscriptSegment(startMs: 0, endMs: 1_000, text: "Hello world."),
            ]
        )

        let markdown = TranscriptRenderer.markdown(
            transcript: transcript,
            participants: [Participant(id: ParticipantID(rawValue: UUID()), name: "Sam")]
        )

        #expect(markdown.contains("**Sam**: Hello world."))
    }

    @Test func rendererUsesAnonymousLabelsForDiarizedSpeakers() {
        let transcript = WhisperTranscript(
            language: "en",
            segments: [
                TranscriptSegment(startMs: 0, endMs: 1_000, text: "Hello.", speakerIndex: 0),
                TranscriptSegment(startMs: 1_000, endMs: 2_000, text: "Hi.", speakerIndex: 1),
            ]
        )

        let markdown = TranscriptRenderer.markdown(
            transcript: transcript,
            participants: []
        )

        #expect(markdown.contains("**Speaker 1**: Hello."))
        #expect(markdown.contains("**Speaker 2**: Hi."))
    }

    @Test func rendererPrefersConfirmedSpeakerName() {
        let participant = Participant(id: ParticipantID(rawValue: UUID()), name: "Sam")
        let transcript = WhisperTranscript(
            language: "en",
            segments: [
                TranscriptSegment(
                    startMs: 0,
                    endMs: 1_000,
                    text: "Hello.",
                    speakerIndex: 4,
                    source: .microphone,
                    participantID: participant.id,
                    speakerName: participant.name
                ),
            ]
        )

        let markdown = TranscriptRenderer.markdown(
            transcript: transcript,
            participants: [participant]
        )

        #expect(markdown.contains("**Sam**: Hello."))
        #expect(!markdown.contains("Speaker 5"))
    }

    @Test func remoteSystemAudioNeverInheritsTheLocalParticipantName() {
        let sam = Participant(id: ParticipantID(rawValue: UUID()), name: "Sam")
        let transcript = WhisperTranscript(
            language: "en",
            segments: [
                TranscriptSegment(
                    startMs: 0,
                    endMs: 1_000,
                    text: "Remote hello.",
                    source: .system
                ),
            ]
        )

        let markdown = TranscriptRenderer.markdown(
            transcript: transcript,
            participants: [sam]
        )

        #expect(markdown.contains("**Speaker 1**: Remote hello."))
        #expect(!markdown.contains("**Sam**: Remote hello."))
    }

    @Test("the terms reported as in the prompt are the ones the prompt actually carries")
    func reportedTermsMatchThePrompt() {
        // These two code paths must not drift apart: the Vocabulary tab tells the user which
        // terms are in force, and that claim has to match the text sent to the model.
        let participants = [
            Participant(id: ParticipantID(rawValue: UUID()), name: "Dana Holt"),
            Participant(id: ParticipantID(rawValue: UUID()), name: "Sam Rivers"),
        ]
        let glossary = (0..<60).map { index in
            GlossaryTerm(
                id: GlossaryTermID(rawValue: UUID()),
                // Padded so no name is a prefix of another, which would make the substring
                // checks below fire on an unrelated term.
                preferred: String(format: "Term%03d", index),
                aliases: ["wrong\(index)"]
            )
        }
        let usage = Dictionary(
            uniqueKeysWithValues: glossary.enumerated().map {
                (String(format: "term%03d", $0.offset), $0.offset)
            }
        )

        let prompt = PromptBuilder.whisperContext(
            participants: participants,
            glossary: glossary,
            usageCounts: usage
        )
        let reported = PromptBuilder.termsInPrompt(
            participants: participants,
            glossary: glossary,
            usageCounts: usage
        )

        // Something has to be left out, otherwise this test proves nothing.
        #expect(reported.count < glossary.count)
        #expect(reported.isEmpty == false)
        for term in reported {
            #expect(prompt.contains(term.preferred))
        }
        // And nothing outside the reported set may appear after the header.
        let domainSection = prompt.components(separatedBy: "Domain terms: ").last ?? ""
        for term in glossary where !reported.contains(term) {
            #expect(domainSection.contains(term.preferred) == false)
        }
    }

    @Test("the reported identifiers match the reported terms")
    func reportedIdentifiersMatch() {
        let glossary = [
            GlossaryTerm(id: GlossaryTermID(rawValue: UUID()), preferred: "Globex", aliases: []),
            GlossaryTerm(id: GlossaryTermID(rawValue: UUID()), preferred: "Vendor Bill", aliases: []),
        ]
        let ids = PromptBuilder.promptTermIDs(participants: [], glossary: glossary)
        let terms = PromptBuilder.termsInPrompt(participants: [], glossary: glossary)
        #expect(ids == Set(terms.map(\.id)))
        #expect(ids.isEmpty == false)
    }

    @Test("many participant names can crowd every term out of the prompt")
    func participantNamesSqueezeTermsOut() {
        // Measured against the live glossary: 135 terms and 46 saved people. Passing all 46
        // names spent the whole 480-character budget, so the prompt carried no domain terms at
        // all, and the Vocabulary tab reported "0 of 135 in the prompt".
        //
        // A real call sends only the people who were on it, so the app is correct; the preview
        // has to assume a small set for the same reason. This test records the shape of the
        // problem so the preview is never built from every saved person again.
        let many = (0..<46).map { index in
            Participant(
                id: ParticipantID(rawValue: UUID()),
                name: "Participant Number \(String(format: "%02d", index))"
            )
        }
        let glossary = (0..<135).map { index in
            GlossaryTerm(
                id: GlossaryTermID(rawValue: UUID()),
                preferred: String(format: "Term%03d", index),
                aliases: []
            )
        }

        let crowded = PromptBuilder.termsInPrompt(participants: many, glossary: glossary)
        let roomy = PromptBuilder.termsInPrompt(participants: [], glossary: glossary)

        // With 46 names the prompt keeps the names it fits and drops the rest of the list, so
        // a few terms still reach the model. What matters is that it stays inside the budget
        // and still names people, rather than reporting zero terms as it once did.
        #expect(crowded.count > 0)
        #expect(crowded.count < roomy.count)
        #expect(roomy.isEmpty == false)
        // The prompt itself must still be built, and must still carry the names.
        let prompt = PromptBuilder.whisperContext(participants: many, glossary: glossary)
        #expect(prompt.contains("Participant Number 00"))
        #expect(prompt.count <= PromptBuilder.whisperPromptCharacterBudget)
    }

    @Test func foldsConsecutiveTurnsOfOneSpeakerIntoOneParagraph() {
        // The shape the library is full of: one voice across three turns, then another. 68% of
        // the saved speaker lines continue the speaker of the line above.
        let body = [
            "**Sam**: first part",
            "",
            "**Sam**: second part",
            "",
            "**Sam**: third part",
            "",
            "**Speaker 1**: a reply",
        ].joined(separator: "\n")

        let folded = TranscriptRenderer.foldingSpeakerTurns(body)

        #expect(folded.text == "**Sam**: first part second part third part\n\n**Speaker 1**: a reply")
        #expect(folded.foldedLines == 2)
    }

    @Test func foldingChangesLayoutAndNotOneWord() {
        let body = [
            "**Sam**: alpha beta",
            "",
            "**Sam**: gamma delta",
        ].joined(separator: "\n")

        let folded = TranscriptRenderer.foldingSpeakerTurns(body)

        #expect(folded.text.contains("alpha beta gamma delta"))
        #expect(folded.text.contains("**Sam**"))
    }

    @Test func aDifferentSpeakerAlwaysStartsANewParagraph() {
        let body = [
            "**Sam**: one",
            "",
            "**Leva**: two",
            "",
            "**Sam**: three",
        ].joined(separator: "\n")

        let folded = TranscriptRenderer.foldingSpeakerTurns(body)

        #expect(folded.text == body)
        #expect(folded.foldedLines == 0)
    }

    @Test func speakerTenIsNotReadAsSpeakerOne() {
        // The label is compared whole, so a run of Speaker 1 does not swallow Speaker 10.
        let body = [
            "**Speaker 1**: one",
            "",
            "**Speaker 10**: ten",
        ].joined(separator: "\n")

        let folded = TranscriptRenderer.foldingSpeakerTurns(body)

        #expect(folded.text == body)
        #expect(folded.foldedLines == 0)
    }

    @Test func aParagraphStopsGrowingAtTheLimit() {
        // One call in the library is 700 turns of one voice. Without a limit it would fold into
        // a single 40,000-character paragraph.
        let turn = String(repeating: "x", count: 60)
        let body = Array(repeating: "**Sam**: \(turn)", count: 40).joined(separator: "\n\n")

        let folded = TranscriptRenderer.foldingSpeakerTurns(body, maximumParagraphCharacters: 200)

        let paragraphs = folded.text.components(separatedBy: "\n\n")
        #expect(paragraphs.allSatisfy { $0.count <= 200 })
        #expect(paragraphs.count > 1)
        // Every turn is still in the file exactly once.
        #expect(folded.text.components(separatedBy: turn).count - 1 == 40)
    }

    @Test func textWithoutSpeakerTagsIsLeftAlone() {
        let plain = "Just a paragraph.\n\nAnd another one."

        let folded = TranscriptRenderer.foldingSpeakerTurns(plain)

        #expect(folded.text == plain)
        #expect(folded.foldedLines == 0)
    }

    @Test func foldingTwiceChangesNothingTheSecondTime() {
        // The pass runs at every launch where the rule version has moved, and a rule that kept
        // finding work would rewrite the whole library on every start.
        let body = [
            "**Sam**: one",
            "",
            "**Sam**: two",
            "",
            "**Leva**: three",
        ].joined(separator: "\n")

        let once = TranscriptRenderer.foldingSpeakerTurns(body)
        let twice = TranscriptRenderer.foldingSpeakerTurns(once.text)

        #expect(twice.text == once.text)
        #expect(twice.foldedLines == 0)
    }

    @Test func theRenderedMarkdownIsFolded() {
        let participants = [Participant(id: ParticipantID(rawValue: UUID()), name: "Sam")]
        let transcript = WhisperTranscript(
            language: "en",
            segments: [
                TranscriptSegment(startMs: 0, endMs: 1_000, text: "one", speakerName: "Sam"),
                TranscriptSegment(
                    startMs: 1_000,
                    endMs: 2_000,
                    text: "two",
                    speakerName: "Sam"
                ),
            ]
        )

        let markdown = TranscriptRenderer.markdown(transcript: transcript, participants: participants)

        #expect(markdown.contains("**Sam**: one two"))
    }

    @Test func anEmptyBodyFoldsToNothing() {
        // A call whose every segment was filler reaches the renderer as an empty body.
        let folded = TranscriptRenderer.foldingSpeakerTurns("")

        #expect(folded.text.isEmpty)
        #expect(folded.foldedLines == 0)
    }

    @Test func aBodyInCyrillicFoldsTheSameWay() {
        // The library holds Russian calls, and the tag is compared as text, not as bytes.
        let body = "**Стас**: привет\n\n**Стас**: как дела"

        let folded = TranscriptRenderer.foldingSpeakerTurns(body)

        #expect(folded.text == "**Стас**: привет как дела")
        #expect(folded.foldedLines == 1)
    }

    @Test func trailingBlankLinesSurviveFolding() {
        // The repair rewrites files in place, so a pass that dropped the blank lines at the
        // end of a file would report a change it did not make.
        let body = "**Sam**: one\n\n\n"

        let folded = TranscriptRenderer.foldingSpeakerTurns(body)

        #expect(folded.text == body)
        #expect(folded.foldedLines == 0)
    }

    @Test func anEmojiAndASurrogatePairDoNotBreakTheLimit() {
        // Characters are counted in Swift characters, so a turn of emoji counts as the
        // people who wrote it would count it, not as the bytes it takes to store.
        let turn = String(repeating: "\u{1F600}", count: 40)
        let body = "**Sam**: \(turn)\n\n**Sam**: \(turn)"

        let folded = TranscriptRenderer.foldingSpeakerTurns(body, maximumParagraphCharacters: 50)

        #expect(folded.text == body)
        #expect(folded.foldedLines == 0)
    }
}
