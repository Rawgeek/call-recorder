import Foundation
import Testing
@testable import CallRecorderCore

@Suite("Glossary correction")
struct GlossaryCorrectorTests {
    private func term(_ preferred: String, aliases: [String]) -> GlossaryTerm {
        GlossaryTerm(id: GlossaryTermID(rawValue: UUID()), preferred: preferred, aliases: aliases)
    }

    /// A saved entry whose misspelling motivated this pass.
    private var globex: GlossaryTerm {
        term("Globex", aliases: ["Globexx", "Globe X", "Globe-X", "GlobeShift", "globe ship"])
    }

    @Test("the store's misspelling becomes the term the user saved")
    func correctsTheRealMisspelling() {
        let outcome = GlossaryCorrector.correct("Welcome to Globexx weekly sync.", terms: [globex])

        #expect(outcome.text == "Welcome to Globex weekly sync.")
        #expect(outcome.counts == ["Globex": 1])
        #expect(outcome.didChange)
    }

    @Test("a misspelling is corrected wherever it appears and however it is cased")
    func correctsEveryCasingAndOccurrence() {
        let outcome = GlossaryCorrector.correct(
            "GLOBEXX ships. globexx ships. Globexx ships.",
            terms: [globex]
        )

        #expect(outcome.text == "Globex ships. Globex ships. Globex ships.")
        #expect(outcome.counts == ["Globex": 3])
    }

    @Test("a multi-word mishearing is replaced as one phrase")
    func correctsMultiWordAlias() {
        let outcome = GlossaryCorrector.correct("We use Globe-X for that.", terms: [globex])

        #expect(outcome.text == "We use Globex for that.")
        #expect(outcome.counts == ["Globex": 1])
    }

    // MARK: - Short forms and titles

    /// Three people share a first name, so the short forms exist: a transcript that says only a
    /// surname, or an initial, has to land on the right person. The aliases mirror what a real
    /// directory records, so these cases are a directory read aloud.
    @Test("three people share a first name, and the short forms separate them")
    func shortFormsSeparateSharedFirstName() {
        let terms = [
            term("Alex Dawson", aliases: ["Alex D", "Dawson"]),
            term("Alex Kim", aliases: ["Alex K", "Kim", "Aleksei Kim"]),
            term("Alex Palmer", aliases: ["Alex P", "Palmer"]),
        ]
        let outcome = GlossaryCorrector.correct(
            "Alex P asked Alex K, and Dawson answered.",
            terms: terms
        )
        #expect(
            outcome.text
                == "Alex Palmer asked Alex Kim, and Alex Dawson answered."
        )
    }

    /// A surname alone is what people actually say in these calls: the surname appears far more
    /// often in the saved text than the full name.
    @Test("a surname alone reaches the person the directory gives it to")
    func surnameAloneResolves() {
        let outcome = GlossaryCorrector.correct(
            "Kim will check, and Palmer is on it.",
            terms: [
                term("Alex Kim", aliases: ["Kim"]),
                term("Alex Palmer", aliases: ["Palmer"]),
            ]
        )
        #expect(outcome.text == "Alex Kim will check, and Alex Palmer is on it.")
    }

    @Test("the formal name the directory records becomes the name the transcripts use")
    func formalNameBecomesTheUsedName() {
        let outcome = GlossaryCorrector.correct(
            "Daniel Garner reported it, and Danil Garner confirmed.",
            terms: [term("John", aliases: ["Daniel Garner", "Danil Garner"])]
        )
        #expect(outcome.text == "John reported it, and John confirmed.")
    }

    @Test("a nickname the directory records is corrected to the name the app stores")
    func nicknameResolves() {
        let outcome = GlossaryCorrector.correct(
            "Eugene and Zhenya joined with Arkady.",
            terms: [
                term("Evan", aliases: ["Eugene", "Zhenya"]),
                term("Arcady", aliases: ["Arkady"]),
            ]
        )
        #expect(outcome.text == "Evan and Evan joined with Arcady.")
    }

    /// A short form expands to the full name, and a longer form of another name collapses to
    /// the name the app stores. Both rules run in the same pass without interfering.
    @Test("a short form and a full name are corrected in the same pass")
    func shortFormAndFullNameCorrectedTogether() {
        let terms = [
            term("Kira Neri", aliases: ["Kira", "Neri"]),
            term("Anton", aliases: ["Antek", "Anton Zaytsev", "Antek Zaytsev"]),
        ]
        let outcome = GlossaryCorrector.correct("Kira joined, and Anton Zaytsev called.", terms: terms)
        #expect(outcome.text == "Kira Neri joined, and Anton called.")
    }

    /// A rule that looks useful is deliberately absent: rewriting this name would put a word on
    /// the page that the caller did not say. The reason is held here so it cannot be lost.
    @Test("a bare first name is not rewritten when the recordings contradict it")
    func ambiguousFirstNameIsLeftAlone() {
        // A directory may list "Tim" as Tamir Darwish's nickname, but the saved recordings use
        // "Tim" in calls where neither Tamir nor any other Tim was present. Rewriting it would
        // put a name on the page that the speaker did not say, so the alias was left out and the
        // transcript keeps the word as spoken.
        let outcome = GlossaryCorrector.correct(
            "Thanks, Tim. Can you scroll down?",
            terms: [term("Tamir", aliases: ["Tamour", "Tamir Darwish"])]
        )
        #expect(outcome.text == "Thanks, Tim. Can you scroll down?")
        #expect(!outcome.didChange)
    }

    @Test("the misspellings a transcript really shows are corrected")
    func correctsTheSpellingsFoundInTranscripts() {
        // Each pair is a line of the kind a transcript holds and the term it belongs to: a
        // mishearing at the start of a sentence, and a phonetic spelling the model chose. They
        // are the reason those aliases were added to the glossary in the first place.
        let meridian = term("Meridian", aliases: ["Merridian", "Meridien", "Merdic", "Meridion", "MERID"])
        let globex = term("Globex", aliases: ["Globexx", "Globe X", "Globe-X", "Globey"])
        let deepseek = term("DeepSeek", aliases: ["DeepSec", "Deep Seek"])
        let terms = [meridian, globex, deepseek]

        // "where all of MERID's warehouses are equipped" — the same call says Meridian properly.
        let maerskOutcome = GlossaryCorrector.correct(
            "all of MERID's warehouses are equipped",
            terms: terms
        )
        #expect(maerskOutcome.text == "all of Meridian's warehouses are equipped")

        // "Globey будет платить полностью за них через DeepSec" — one line, two corrections.
        let mixedOutcome = GlossaryCorrector.correct(
            "Globey will pay for them through DeepSec",
            terms: terms
        )
        #expect(mixedOutcome.text == "Globex will pay for them through DeepSeek")
        #expect(mixedOutcome.counts == ["Globex": 1, "DeepSeek": 1])
    }

    @Test("the longest alias wins so a shorter rule cannot split a phrase")
    func prefersTheLongestAlias() {
        // "Globe" is an alias of a different term, and "Globe X" starts with it. If the
        // shorter rule were tried first it would rewrite the first word and leave a fragment
        // that is neither term. The two spellings must not overlap this way.
        let longer = term("Globex", aliases: ["Globe X", "Globe-X"])
        let shorter = term("Glo", aliases: ["Globe"])

        let outcome = GlossaryCorrector.correct("Globe X is live.", terms: [longer, shorter])

        #expect(outcome.text == "Globex is live.")
        #expect(outcome.counts == ["Globex": 1])
    }

    @Test("a term is not replaced inside a longer word")
    func respectsWordEdges() {
        // The alias is a substring of real words at both edges: it ends "Globex" and it
        // starts "ships". Only the standalone word may change.
        let shipment = term("Shipment", aliases: ["ship"])

        let outcome = GlossaryCorrector.correct(
            "Globex ships one ship. Shipshape.",
            terms: [shipment]
        )

        #expect(outcome.text == "Globex ships one Shipment. Shipshape.")
        #expect(outcome.counts == ["Shipment": 1])
    }

    @Test("a short form inside the full name it expands to does not grow the text")
    func doesNotGrowInsideItsOwnExpansion() {
        // The case that corrupted a line: the glossary saves "Neri" as an alternative to
        // "Kira Neri", and the full name ends with the short form. Each pass used to expand the
        // tail again, so "Kira Neri might join" became a line of "Kira" repeated thirty times.
        let term = self.term("Kira Neri", aliases: ["Neri"])

        let first = GlossaryCorrector.correct("I think Kira Neri might join.", terms: [term])
        let second = GlossaryCorrector.correct(first.text, terms: [term])

        #expect(first.text == "I think Kira Neri might join.")
        #expect(first.replacementCount == 0)
        #expect(second.text == first.text)
    }

    @Test("a short form used alone still expands to the full name")
    func expandsStandaloneShortForm() {
        let term = self.term("Kira Neri", aliases: ["Neri"])

        let outcome = GlossaryCorrector.correct("Neri might join.", terms: [term])

        #expect(outcome.text == "Kira Neri might join.")
        #expect(outcome.counts == ["Kira Neri": 1])
    }

    @Test("a longer alternative that contains a saved spelling is still normalised")
    func normalisesLongerAlternative() {
        // "Meridian Line" contains the settled spelling "Meridian". Only a match that sits inside a
        // settled span is skipped, so this one still collapses to the saved name.
        let term = self.term("Meridian", aliases: ["Meridian Line", "Meridien"])

        let outcome = GlossaryCorrector.correct("Meridian Line called Meridian.", terms: [term])

        #expect(outcome.text == "Meridian called Meridian.")
        #expect(outcome.counts == ["Meridian": 1])
    }

    @Test("a spelling saved as correct is never rewritten, so a cycle cannot oscillate")
    func refusesToRewriteAuthoritativeSpellings() {
        // Two entries each saved the other's spelling as an alternative, so every pass rewrote
        // the previous pass and no pass ever settled.
        let short = term("Priya", aliases: ["Priti Singh"])
        let long = term("Priya Singh", aliases: ["Priti"])
        let terms = [short, long]

        let first = GlossaryCorrector.correct("Priti Singh joined.", terms: terms)
        let second = GlossaryCorrector.correct(first.text, terms: terms)

        // "Priti Singh" is corrected once, to the term that claims it. Neither "Priya" nor
        // "Priya Singh" is rewritten again, because both are saved as correct spellings, so the
        // result is a fixed point instead of a spelling that trades back and forth forever.
        #expect(first.text == "Priya joined.")
        #expect(second.text == first.text)
        #expect(second.replacementCount == 0)
    }

    @Test("a duplicate name pair converges to one spelling and then stops")
    func convergesOnDuplicatePair() {
        // The aliases that are not themselves saved terms still correct, and the result is a
        // fixed point: running the pass again changes nothing.
        let short = term("Priya", aliases: ["Priti"])
        let long = term("Priya Singh", aliases: ["Priti Singh"])
        let terms = [short, long]

        let first = GlossaryCorrector.correct("Priti joined. Priti Singh joined.", terms: terms)
        let second = GlossaryCorrector.correct(first.text, terms: terms)

        #expect(first.text == "Priya joined. Priya Singh joined.")
        #expect(second.text == first.text)
        #expect(second.replacementCount == 0)
    }

    @Test("correcting an already corrected transcript reports nothing")
    func isIdempotent() {
        let first = GlossaryCorrector.correct("Globexx and Globe-X.", terms: [globex])
        let second = GlossaryCorrector.correct(first.text, terms: [globex])

        #expect(first.text == "Globex and Globex.")
        #expect(second.text == first.text)
        #expect(second.replacementCount == 0)
    }

    @Test("an alias identical to its preferred term is not counted as a correction")
    func ignoresSelfAlias() {
        let term = self.term("Globex", aliases: ["Globex", "globex"])
        let outcome = GlossaryCorrector.correct("Globex is here.", terms: [term])

        #expect(outcome.text == "Globex is here.")
        #expect(outcome.replacementCount == 0)
    }

    @Test("text without any known misspelling is returned unchanged")
    func leavesCleanTextAlone() {
        let outcome = GlossaryCorrector.correct("Nothing to fix here.", terms: [globex])

        #expect(outcome.text == "Nothing to fix here.")
        #expect(outcome.counts.isEmpty)
    }

    @Test("an empty glossary leaves the text untouched")
    func handlesEmptyGlossary() {
        let outcome = GlossaryCorrector.correct("Globexx stays.", terms: [])

        #expect(outcome.text == "Globexx stays.")
        #expect(outcome.replacementCount == 0)
    }

    @Test("non-Latin text survives a correction pass")
    func preservesNonLatinText() {
        let term = self.term("Глобекс", aliases: ["Глоу бекс"])
        let outcome = GlossaryCorrector.correct(
            "Мы работаем с Глоу бекс, и всё хорошо. Globex тоже.",
            terms: [term]
        )

        #expect(outcome.text == "Мы работаем с Глобекс, и всё хорошо. Globex тоже.")
        #expect(outcome.counts == ["Глобекс": 1])
    }

    @Test("a correction keeps the surrounding punctuation and spacing byte for byte")
    func preservesSurroundingText() {
        let original = "  (Globexx),\n\tand  double  spaces  "
        let outcome = GlossaryCorrector.correct(original, terms: [globex])

        #expect(outcome.text == "  (Globex),\n\tand  double  spaces  ")
    }

    @Test("counts are reported per preferred term across several terms")
    func reportsCountsPerTerm() {
        let meridian = term("Meridian", aliases: ["Meridien", "Meridian Line"])
        let outcome = GlossaryCorrector.correct(
            "Meridien called. Globexx replied. Meridian Line confirmed.",
            terms: [globex, meridian]
        )

        #expect(outcome.text == "Meridian called. Globex replied. Meridian confirmed.")
        #expect(outcome.counts == ["Meridian": 2, "Globex": 1])
    }

    @Test("every segment is corrected and the timing and speaker labels are kept")
    func correctsWholeTranscript() {
        let transcript = WhisperTranscript(
            language: "en",
            segments: [
                TranscriptSegment(
                    startMs: 0,
                    endMs: 1_000,
                    text: "Globexx here.",
                    speakerIndex: 2,
                    source: .system,
                    speakerName: "Dana"
                ),
                TranscriptSegment(startMs: 1_000, endMs: 2_000, text: "Nothing to change."),
            ]
        )

        let corrected = transcript.applyingGlossary(terms: [globex])

        #expect(corrected.corrections == 1)
        #expect(corrected.transcript.text == "Globex here.\nNothing to change.")
        // Timing, source, and the speaker label are metadata about who spoke and when, so they
        // must survive a pass that only touches spelling.
        #expect(corrected.transcript.segments[0].startMs == 0)
        #expect(corrected.transcript.segments[0].endMs == 1_000)
        #expect(corrected.transcript.segments[0].speakerIndex == 2)
        #expect(corrected.transcript.segments[0].source == .system)
        #expect(corrected.transcript.segments[0].speakerName == "Dana")
        #expect(corrected.transcript.segments[1].text == "Nothing to change.")
    }

    @Test("a transcript with nothing to correct is returned as it was")
    func leavesCleanTranscriptAlone() {
        let transcript = WhisperTranscript(
            language: "en",
            segments: [TranscriptSegment(startMs: 0, endMs: 500, text: "All good.")]
        )

        let corrected = transcript.applyingGlossary(terms: [globex])

        #expect(corrected.corrections == 0)
        #expect(corrected.transcript == transcript)
    }

    @Test("a term containing regex characters is matched literally")
    func treatsAliasesAsLiterals() {
        let term = self.term("C++", aliases: ["C plus plus"])
        let outcome = GlossaryCorrector.correct("We ship with C plus plus, not C.plus.plus.", terms: [term])

        #expect(outcome.text == "We ship with C++, not C.plus.plus.")
        #expect(outcome.counts == ["C++": 1])
    }

    @Test("the same rules give the same fingerprint")
    func fingerprintIsStable() {
        let first = GlossaryCorrector.fingerprint(of: [globex])
        let second = GlossaryCorrector.fingerprint(of: [globex])

        #expect(first == second)
        #expect(!first.isEmpty)
    }

    @Test("the fingerprint does not depend on the order terms were saved in")
    func fingerprintIgnoresOrder() {
        let heroku = term("Heroku", aliases: ["Hiroku"])

        #expect(
            GlossaryCorrector.fingerprint(of: [globex, heroku])
                == GlossaryCorrector.fingerprint(of: [heroku, globex])
        )
    }

    @Test("adding a spelling moves the fingerprint")
    func fingerprintMovesWithARule() {
        let before = GlossaryCorrector.fingerprint(of: [globex])
        let after = GlossaryCorrector.fingerprint(of: [
            term("Globex", aliases: ["Globexx", "Globe X", "Globe-X", "GlobeShift", "globe ship", "Flowchip"]),
        ])

        // This is what tells the app the library is owed a repair. A value that did not move
        // would leave the corrected spelling out of the saved files until someone pressed the
        // button by hand.
        #expect(before != after)
    }

    @Test("a term that renames nothing leaves the fingerprint alone")
    func fingerprintIgnoresARuleThatChangesNothing() {
        // An alias equal to its own preferred spelling is dropped when the rules are built: it
        // would match, replace itself, and report a correction that never happened. The
        // fingerprint is built from the same rules, so it does not move either, and adding a
        // term that cannot change any text does not send the app over the whole library.
        let before = GlossaryCorrector.fingerprint(of: [globex])
        let after = GlossaryCorrector.fingerprint(of: [globex, term("Meridian", aliases: ["Meridian"])])

        #expect(before == after)
    }

    @Test("a library with no rules has a fingerprint that never matches a real one")
    func emptyGlossaryHasItsOwnFingerprint() {
        // The nil case is "never repaired" and this is the other end of it: a glossary that
        // repairs nothing. The two must not be confused, or an empty glossary would be recorded
        // as a completed repair.
        let empty = GlossaryCorrector.fingerprint(of: [])

        #expect(empty != GlossaryCorrector.fingerprint(of: [globex]))
        #expect(empty == GlossaryCorrector.fingerprint(of: []))
    }

    @Test("a term whose alias is a prefix of another alias is written once")
    func doesNotDoubleTheVendorBill() {
        let entry = term("Vendor Bill", aliases: [
            "VendorBilla", "Vendor Billa", "Venter Bill", "Wender Billa",
            "Wender Bill", "Vendor Billet", "Vendor Billed",
        ])
        // The library holds "Vendor Billa" and the Russian genitive "Vendor Billa Bill'a",
        // where the model repeated the name it had already written. Every alias must come out
        // as one plainly spelled term.
        for input in ["Vendor Billa", "Wender Bill", "Vendor Billet", "Vendor Billed"] {
            let out = GlossaryCorrector.correct(input, terms: [entry]).text
            #expect(out == "Vendor Bill", "\(input) became \(out)")
        }
        // Correction does not invent a repetition, and it does not remove one the model made:
        // this text is stored as Whisper wrote it, which is the reason the library shows it.
        #expect(GlossaryCorrector.correct("Vendor Bill Bill", terms: [entry]).text == "Vendor Bill Bill")
    }

    @Test("prints the vendor bill table")
    func printsVendorBillTable() {
        let entry = term("Vendor Bill", aliases: [
            "VendorBilla", "Vendor Billa", "Venter Bill", "Wender Billa",
            "Wender Bill", "Vendor Billet", "Vendor Billed",
        ])
        for input in [
            "Vendor Billa", "Wender Bill", "Vendor Billet", "Vendor Bill Bill",
            "Vendor Bill Billet", "Vendor Billa Bill'a", "Vendor Bill Bill'a",
        ] {
            let out = GlossaryCorrector.correct(input, terms: [entry]).text
            print("CASE  \(input)  ->  \(out)")
        }
    }

    // MARK: - The spellings the model invented for a declared term

    /// The six terms the 2026-09-18 call's glossary declares, and the six spellings its body
    /// actually holds. None of the spellings was a declared alias; every one is what the decoder
    /// heard.
    private var callTerms: [GlossaryTerm] {
        [
            term("Salla", aliases: []),
            term("DeepSeek", aliases: []),
            term("Whisper", aliases: []),
            term("Rasa", aliases: []),
            term("Airhouse", aliases: []),
            term("CartRover", aliases: []),
        ]
    }

    @Test("a term the decoder misheard is read back from its sound and its context")
    func readsBackTheMisheardTerms() {
        // The keys first, because everything else rests on them.
        #expect(GlossaryCorrector.phoneticKey("Whisper") == GlossaryCorrector.phoneticKey("биспер"))
        #expect(GlossaryCorrector.phoneticKey("Airhouse") == GlossaryCorrector.phoneticKey("Айрхаус"))
        #expect(
            GlossaryCorrector.phoneticKey("CartRover")
                == GlossaryCorrector.phoneticKey("карт-ровер")
        )
        #expect(
            GlossaryCorrector.phoneticDistance(
                GlossaryCorrector.phoneticKey("DeepSeek") ?? "",
                GlossaryCorrector.phoneticKey("DeepSecret") ?? ""
            ) == 2
        )
        // Each line names a term the glossary already matches, which is the context rule: the call
        // is talking about Salla and CartRover, so "салют" on the same line is Salla.
        let text = [
            "Мы интегрируем CartRover, и салют будет нашим партнёром.",
            "Сало и салай тоже подключатся к CartRover через API.",
            "DeepSecret работает лучше, но CartRover дешевле.",
            "В CartRover есть биспер для транскрипции.",
            "Роза утверждает, что CartRover быстрее.",
            "Айрхаус и карт-ровер уже в проде.",
        ].joined(separator: "\n")

        let (corrected, suggestions) = GlossaryCorrector.applyingSuggestedAliases(
            text,
            terms: callTerms
        )

        #expect(corrected.contains("Salla будет нашим партнёром"))
        #expect(corrected.contains("Salla и Salla тоже подключатся"))
        #expect(corrected.contains("DeepSeek работает лучше"))
        #expect(corrected.contains("Whisper для транскрипции"))
        #expect(corrected.contains("Rasa утверждает"))
        #expect(corrected.contains("Airhouse и CartRover уже в проде"))
        // Three spellings of Salla, and one of each other term: eight in all, and no ordinary word
        // of the call among them.
        #expect(suggestions.map(\.preferred).sorted()
            == [
                "Airhouse", "CartRover", "DeepSeek", "Rasa", "Salla", "Salla", "Salla", "Whisper",
            ].sorted())
        #expect(suggestions.map(\.found).sorted()
            == ["DeepSecret", "Айрхаус", "биспер", "карт-ровер", "Роза", "Сало", "салай", "салют"]
                .sorted())
    }

    @Test("a word that only sounds like a term is left alone away from the term's context")
    func keepsAWordWithNoContext() {
        // No declared term in these lines, so the sound rule never gets to speak. This is the guard
        // that keeps a meeting about anything else from having its words rewritten.
        let text = [
            "Мы обсудим это завтра и решим, что делать.",
            "Салют, коллеги, приветствую всех на созвоне.",
            "Роза расцвела в саду, и это было красиво.",
        ].joined(separator: "\n")

        let (corrected, suggestions) = GlossaryCorrector.applyingSuggestedAliases(
            text,
            terms: callTerms
        )

        #expect(corrected == text)
        #expect(suggestions.isEmpty)
    }

    @Test("an ordinary word used many times is the call's vocabulary, not a misheard name")
    func keepsAFrequentWord() {
        // The rarity rule. "салют" here comes back on more lines than the floor allows, all of them
        // next to a declared term, and the call is still not corrected: a word repeated that often
        // is a word this call means.
        let lines = (0..<6).map { "CartRover и салют, строка \($0)." }

        let (corrected, suggestions) = GlossaryCorrector.applyingSuggestedAliases(
            lines.joined(separator: "\n"),
            terms: callTerms
        )

        #expect(corrected == lines.joined(separator: "\n"))
        #expect(suggestions.isEmpty)
    }

    @Test("a short word is never taken for a term, however close its sound is")
    func keepsShortWords() {
        // "сто" is one edit from the key of Salla and one letter from the Russian word for a
        // hundred. Three characters is below the floor this pass will work with.
        let text = "CartRover просит сто единиц на складе."

        let (corrected, _) = GlossaryCorrector.applyingSuggestedAliases(text, terms: callTerms)

        #expect(corrected == text)
    }

    @Test("a spelling the glossary already declares is left as it is")
    func leavesDeclaredSpellingsAlone() {
        let withAlias = term("Salla", aliases: ["Sallla"])
        let text = "Sallla и CartRover работают вместе."

        let (corrected, suggestions) = GlossaryCorrector.applyingSuggestedAliases(
            text,
            terms: [withAlias, term("CartRover", aliases: [])]
        )

        // The declared alias is the declared pass's business, not this one's: this pass adds no
        // suggestion for a spelling the user already wrote down.
        #expect(corrected == text)
        #expect(suggestions.isEmpty)
    }

}
