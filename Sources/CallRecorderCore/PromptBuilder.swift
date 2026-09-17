import Foundation

public enum PromptBuilder {
    /// whisper.cpp keeps at most `n_text_ctx / 2` prompt tokens, which is 224 for the whisper
    /// models this app uses. It keeps the last tokens and silently drops the front, so an
    /// over-long prompt loses the participant names first. Measured with whisper-cli 1.9.1 and
    /// ggml-medium: 385 characters tokenize to 147 tokens, 478 to 184, and 560 to 214. This
    /// budget leaves room for names and aliases that tokenize worse than plain prose.
    public static let whisperPromptCharacterBudget = 480

    /// Builds the prompt inside `characterBudget`.
    ///
    /// Names are kept before terms, because a misheard name is the most visible error in a
    /// transcript. When the glossary holds more terms than the prompt can carry, `usageCounts`
    /// decides what is worth the space: terms the user already says, or already gets misheard.
    ///
    /// A long enough name list can consume the whole budget by itself, so the names are capped
    /// too. Leaving it uncapped was worse than dropping a name: whisper keeps the tail of an
    /// over-long prompt, so the front — every name, the reason the list exists — was discarded.
    public static func whisperContext(
        participants: [Participant],
        glossary: [GlossaryTerm],
        usageCounts: [String: Int] = [:],
        characterBudget: Int = whisperPromptCharacterBudget
    ) -> String {
        var context = participants.isEmpty
            ? ""
            : participantsPrompt(participants, characterBudget: characterBudget)
        guard characterBudget > 0 else { return context }
        let kept = selectedTerms(
            glossary,
            participants: participants,
            usageCounts: usageCounts,
            characterBudget: characterBudget,
            reserved: context.count
        ).map(formattedTerm)
        if !kept.isEmpty {
            let separator = context.isEmpty ? "" : " "
            context += separator + "Domain terms: " + kept.joined(separator: "; ") + "."
        }
        return context
    }

    /// The terms that fit the prompt budget after `reserved` characters of other text. Terms
    /// are taken in priority order. A term that is too long for the space left is skipped
    /// instead of ending the list, because one long entry would otherwise cost every shorter
    /// term behind it. Room only shrinks as terms are taken, so a skipped term never fits later.
    static func selectedTerms(
        _ glossary: [GlossaryTerm],
        participants: [Participant],
        usageCounts: [String: Int] = [:],
        characterBudget: Int = whisperPromptCharacterBudget,
        reserved: Int = 0
    ) -> [GlossaryTerm] {
        // The prompt closes the term list with a period, so that character is always spent.
        var room = characterBudget - reserved - 1
        var kept: [GlossaryTerm] = []
        for term in prioritizedTerms(
            glossary,
            participants: participants,
            usageCounts: usageCounts
        ) {
            let cost = formattedTerm(term).count
                + (kept.isEmpty ? " Domain terms: ".count : "; ".count)
            guard cost <= room else { continue }
            room -= cost
            kept.append(term)
        }
        return kept
    }

    /// The glossary terms that fit in the transcription prompt, in the order they are sent.
    ///
    /// Whisper keeps only the tail of a long prompt, so a glossary of any size is trimmed before
    /// it reaches the model. The Vocabulary tab uses this to say which terms are actually in
    /// force, instead of implying that every saved term is being sent.
    public static func termsInPrompt(
        participants: [Participant],
        glossary: [GlossaryTerm],
        usageCounts: [String: Int] = [:],
        characterBudget: Int = whisperPromptCharacterBudget
    ) -> [GlossaryTerm] {
        let context = participants.isEmpty
            ? ""
            : participantsPrompt(participants, characterBudget: characterBudget)
        return selectedTerms(
            glossary,
            participants: participants,
            usageCounts: usageCounts,
            characterBudget: characterBudget,
            reserved: context.count
        )
    }

    /// Names the terms that are sent, as identifiers, so a list can mark each row.
    public static func promptTermIDs(
        participants: [Participant],
        glossary: [GlossaryTerm],
        usageCounts: [String: Int] = [:],
        characterBudget: Int = whisperPromptCharacterBudget
    ) -> Set<GlossaryTermID> {
        Set(
            termsInPrompt(
                participants: participants,
                glossary: glossary,
                usageCounts: usageCounts,
                characterBudget: characterBudget
            ).map(\.id)
        )
    }

    /// The prompt closes the term list with a period, so that character is always spent.

    /// Terms that spell a participant name come first, because a misheard name is the most
    /// visible error in a meeting transcript. The remaining terms follow in the order of how
    /// often they already appear in saved transcripts, then alphabetically so the order is
    /// stable for terms that never appeared.
    static func prioritizedTerms(
        _ glossary: [GlossaryTerm],
        participants: [Participant],
        usageCounts: [String: Int] = [:]
    ) -> [GlossaryTerm] {
        let named = GlossaryUsage.namingParticipants(glossary, participants: participants)
        return GlossaryUsage.ranked(named, usageCounts: usageCounts) + GlossaryUsage.ranked(
            glossary.filter { term in !named.contains(term) },
            usageCounts: usageCounts
        )
    }

    /// The share of the prompt that participant names may take.
    ///
    /// Names come first because a misheard name is the most visible error, but they must not
    /// take everything. Measured against the live data, a call with 46 saved people produced a
    /// name list longer than the whole prompt, so the glossary never reached the model at all.
    /// Capping names here leaves room for terms on even the most crowded call.
    static let nameBudgetShare = 0.55

    /// Names the people on the call, keeping only as many as the budget allows.
    ///
    /// The first name is always kept, even when it alone fills its share: a prompt naming the
    /// owner of the Mac is still better than one naming nobody. Names are added in the order the
    /// call stored them, so the result is stable for the same call.
    static func participantsPrompt(_ participants: [Participant], characterBudget: Int) -> String {
        guard !participants.isEmpty else { return "" }
        let allNames = participants.map(\.name)
        // Try the whole list first, which is the normal case for a real call.
        let complete = sentence(for: allNames)
        guard characterBudget > 0 else { return complete }
        let share = Int(Double(characterBudget) * nameBudgetShare)
        if complete.count <= share { return complete }
        var kept: [String] = []
        for name in allNames {
            let candidate = sentence(for: kept + [name])
            if candidate.count > share, !kept.isEmpty { break }
            kept.append(name)
            if candidate.count > share { break }
        }
        return sentence(for: kept)
    }

    /// Reads as a sentence rather than a list, because the model is being told a fact about the
    /// recording, not handed data.
    private static func sentence(for names: [String]) -> String {
        let joined: String
        switch names.count {
        case 0: joined = ""
        case 1: joined = names[0]
        case 2: joined = "\(names[0]) and \(names[1])"
        default:
            let allButLast = names.dropLast().joined(separator: ", ")
            joined = "\(allButLast), and \(names.last!)"
        }
        return "A conversation with \(joined)."
    }

    private static func formattedTerm(_ term: GlossaryTerm) -> String {
        // The prompt shows the correct spelling only. A wrong spelling in the prompt biases the
        // model toward that same wrong spelling, and the alias list costs most of the prompt.
        // Aliases stay in the store, where they are used to detect and to rename mishearings.
        term.preferred
    }

    // MARK: - Transcript header

    /// The file's own header: a title and the people who were on the call.
    ///
    /// The glossary used to be written here as well, beside the alternatives each term had been
    /// misheard as, on the reasoning that the file should record what the model was told. It no
    /// longer is, and the reason is what the file is for. The terms shape the decode, and once the
    /// decode is done the list says nothing about the call: it is the same vocabulary at the top of
    /// every transcript, and the old files carried about 1 700 characters of it, against a few
    /// hundred characters of a short call. Every later reading of the file pays for it: the search
    /// index, the model handed a transcript as context, and the person who opens one to find out
    /// what was said.
    ///
    /// The alternatives are not lost. They live in the vocabulary itself, with the term they
    /// belong to, which is where the correction pass reads them from and how it repairs a
    /// mishearing in a file that is already written.
    ///
    /// The prompt is untouched. `whisperContext` still carries the names and the highest-priority
    /// terms inside whisper's own token budget, which is the only place a term can change what the
    /// model hears.
    public static func transcriptHeader(participants: [Participant]) -> String {
        let people = participants.map(\.name).joined(separator: ", ")
        return """
            # Meeting Transcript

            Participants: \(people.isEmpty ? "Not specified" : people)

            """
    }
}

// MARK: - Transcript rendering (no timestamps, diarized speaker labels)

public enum TranscriptRenderer {
    private static let fillerPattern = try! NSRegularExpression(
        pattern: #"\[(?:music|silence|applause|laughter|inaudible|noise|phone.ringing|typing|background|door|cough|sigh|clears.throat)\]\s*"#,
        options: [.caseInsensitive]
    )

    /// The lines a header is made of.
    ///
    /// A file this app writes opens with a title and the participant line, and nothing else. Files
    /// an earlier version wrote are still on disk and they carry more: a glossary line, and a
    /// language line above a body whose every paragraph starts with a printed time range. All four
    /// shapes are recognised, because a header line this list does not know is read as the first
    /// line of speech, and the split then lands inside the header.
    private static let headerPrefixes = [
        "# ", "Participants:", "Glossary:", "Language:", "Model:", "Duration:", "Date:",
    ]

    /// Where the spoken text starts, as an offset into the markdown.
    ///
    /// The header is a run of title, participant, and glossary lines at the top of the file. The
    /// split used to be found by searching for the text "Glossary: ", which stopped being a
    /// reliable marker the moment the glossary left the header: a file written without one holds no
    /// such text, and the body would then have been read as the whole file, header included, and
    /// written back that way. Splitting on the shape of the header instead of on one of its lines
    /// means an old file and a new one are read the same way.
    ///
    /// Returns nil when the file does not open with a header, which is how a plain text transcript
    /// passes through untouched.
    public static func spokenTextStart(in markdown: String) -> String.Index? {
        var index = markdown.startIndex
        var sawHeaderLine = false
        while index < markdown.endIndex {
            guard let lineEnd = markdown[index...].firstIndex(of: "\n") else { break }
            let line = markdown[index..<lineEnd].trimmingCharacters(in: .whitespaces)
            let isHeaderLine = headerPrefixes.contains { line.hasPrefix($0) }
            if isHeaderLine {
                sawHeaderLine = true
            } else if !line.isEmpty {
                // The first line that is neither blank nor part of the header. Everything from here
                // is spoken text.
                return sawHeaderLine ? index : nil
            }
            index = markdown.index(after: lineEnd)
        }
        return nil
    }

    /// Returns the spoken body of a rendered transcript, without its header.
    ///
    /// A correction pass rewrites the words that were said, so it has to be given the words that
    /// were said and nothing else: running it over the whole file would let a rule reach into the
    /// header and rewrite a participant's name out of the line that lists the people on the call.
    public static func body(of markdown: String) -> String {
        guard let start = spokenTextStart(in: markdown) else { return markdown }
        return String(markdown[start...])
    }

    /// Puts a corrected body back under the header it came from.
    public static func replacingBody(of markdown: String, with body: String) -> String {
        guard let start = spokenTextStart(in: markdown) else { return body }
        return String(markdown[..<start]) + body
    }

    /// The same file with its glossary line left out, or nil when it has no such line.
    ///
    /// The terms shape the decode and are kept in the vocabulary, so the line in a saved file is a
    /// copy of a list that lives somewhere else, at the top of every transcript. A file that an
    /// earlier version wrote is rewritten without it rather than left alone, because leaving it
    /// alone means the reason the line was dropped applies to every new file and to no old one.
    /// The rest of the header and the whole body are returned unchanged, which is what keeps this
    /// from being a rewrite of anything that was said.
    public static func removingGlossaryLine(from markdown: String) -> String? {
        guard let start = spokenTextStart(in: markdown) else { return nil }
        let header = markdown[..<start]
        guard header.contains("Glossary:") else { return nil }
        let kept = header
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("Glossary:") }
            .joined(separator: "\n")
        return kept + markdown[start...]
    }

    /// Renders a clean, speaker-aware markdown transcript.
    /// How long one speaker's paragraph may grow before the next turn starts a new one.
    ///
    /// Measured on the 73 saved transcripts. Every turn the transcriber produced became its own
    /// line, and 68% of those lines continue the speaker of the line above, so one voice talking
    /// for a minute is drawn as a dozen identical prefixes. Folding the runs takes 11.0% of the
    /// library's bytes away, and all but a tenth of a point of that is already reached here.
    ///
    /// The ceiling is what keeps a monologue readable. One call is 700 turns of one voice, which
    /// without a limit would fold into a single 40,000-character paragraph; 23 files would hold a
    /// paragraph longer than thirty turns. At this length the longest paragraph in the library is
    /// 900 characters, about 150 words.
    public static let maximumSpeakerParagraphCharacters = 900

    /// Joins the turns that one speaker holds into a single paragraph.
    ///
    /// A saved transcript is read through this app, not in it: the file on the Desktop, the text
    /// Copy Transcript puts on the clipboard, and what the MCP server hands to another agent are
    /// all this markdown. A prefix that repeats 18,000 times across the library is therefore paid
    /// again on every reading of it, and the reader is a model that pays by the token.
    ///
    /// Only the layout changes. No word is added, removed, or reordered, and a paragraph is only
    /// joined to the one directly above it, and only when that one belongs to the same speaker.
    /// A line with no speaker tag ends the run, so a header, a plain transcript, and any text a
    /// person pasted in are all left as they are.
    public static func foldingSpeakerTurns(
        _ body: String,
        maximumParagraphCharacters: Int = TranscriptRenderer.maximumSpeakerParagraphCharacters
    ) -> (text: String, foldedLines: Int) {
        var kept: [String] = []
        var openSpeaker: String?
        var pendingBlankLines = 0
        var folded = 0

        func flushPendingBlankLines() {
            while pendingBlankLines > 0 {
                kept.append("")
                pendingBlankLines -= 1
            }
        }

        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(line)
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard
                let match = speakerLine.firstMatch(in: text, range: range),
                let tagRange = Range(match.range(at: 1), in: text),
                let saidRange = Range(match.range(at: 2), in: text)
            else {
                if text.trimmingCharacters(in: .whitespaces).isEmpty, openSpeaker != nil {
                    // The blank line between two turns of one paragraph. It is dropped when the
                    // next line continues the speaker, and put back when it does not, so a file
                    // that is not folded comes out byte for byte the way it went in.
                    pendingBlankLines += 1
                    continue
                }
                flushPendingBlankLines()
                openSpeaker = nil
                kept.append(text)
                continue
            }

            let tag = String(text[tagRange])
            let said = String(text[saidRange])
            if !said.isEmpty,
                let openSpeaker,
                tag == openSpeaker,
                let previous = kept.last,
                previous.count + 1 + said.count <= maximumParagraphCharacters {
                kept[kept.count - 1] = previous + " " + said
                pendingBlankLines = 0
                folded += 1
                continue
            }
            flushPendingBlankLines()
            kept.append(text)
            openSpeaker = tag
        }
        // Trailing blank lines are put back as they were. Nothing reads the end of a file, and a
        // repair that quietly dropped them would report a change it did not make.
        flushPendingBlankLines()
        return (kept.joined(separator: "\n"), folded)
    }

    /// One rendered turn, split into the speaker's label and what they said.
    ///
    /// The label is kept whole in the first group, so two turns can be compared without parsing a
    /// name out of one, which is what keeps `Speaker 1` from being read as `Speaker 10`.
    private static let speakerLine = try! NSRegularExpression(
        pattern: "^(\\*\\*[^*]+\\*\\*: )(.*)$"
    )

    /// - When diarization assigned speakerIndex: "Speaker 1", "Speaker 2", etc.
    /// - When one participant and no diarization: auto-attaches their name.
    /// - Otherwise: plain text.
    public static func markdown(
        transcript: WhisperTranscript,
        participants: [Participant]
    ) -> String {
        let hasDiarization = transcript.segments.contains { $0.speakerIndex != nil }
        let body = transcript.segments.compactMap { segment -> String? in
            let cleaned = clean(segment.text)
            guard !cleaned.isEmpty else { return nil }

            let speakerTag: String
            if let name = segment.speakerName {
                speakerTag = "**\(name)**: "
            } else if let idx = segment.speakerIndex {
                speakerTag = "**Speaker \(idx + 1)**: "
            } else if segment.source == .system {
                speakerTag = "**Speaker 1**: "
            } else if segment.source == nil && !hasDiarization && participants.count == 1 {
                speakerTag = "**\(participants[0].name)**: "
            } else {
                speakerTag = ""
            }
            return "\(speakerTag)\(cleaned)"
        }.joined(separator: "\n\n")

        return """
            \(PromptBuilder.transcriptHeader(participants: participants))
            \(TranscriptRenderer.foldingSpeakerTurns(body).text)
            """
    }

    /// Strips Whisper filler tags and normalizes whitespace.
    public static func clean(_ text: String) -> String {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let stripped = fillerPattern.stringByReplacingMatches(
            in: text,
            options: [],
            range: range,
            withTemplate: ""
        )
        return stripped
            .replacingOccurrences(of: "[BLANK_AUDIO]", with: "")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
