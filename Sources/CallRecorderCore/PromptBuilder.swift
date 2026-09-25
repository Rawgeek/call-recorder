import Foundation

public enum PromptBuilder {
    /// Most words the reader is given beside the audio.
    ///
    /// The list is a hint, and a call with forty participants and a vocabulary of hundreds would
    /// hand the reader more words than it can weight. The words that matter most are the people on
    /// the call and the vocabulary the user actually uses, and names are counted first, so a
    /// crowded call keeps the people it was about.
    public static let hotwordLimit = 60

    /// The names and terms sent beside the audio, in the order they are sent.
    ///
    /// The reader takes a list rather than a prompt, so nothing here is trimmed to a token budget:
    /// the names come first, then the terms, and the list stops at ``hotwordLimit``.
    public static func hotwords(
        participants: [Participant],
        glossary: [GlossaryTerm],
        usageCounts: [String: Int] = [:]
    ) -> [String] {
        list(participants: participants, glossary: glossary, usageCounts: usageCounts).words
    }

    /// Names the terms that are sent, as identifiers, so a list can mark each row.
    public static func promptTermIDs(
        participants: [Participant],
        glossary: [GlossaryTerm],
        usageCounts: [String: Int] = [:]
    ) -> Set<GlossaryTermID> {
        Set(list(participants: participants, glossary: glossary, usageCounts: usageCounts).terms.map(\.id))
    }

    /// The list as the reader receives it, and the glossary entries inside it.
    ///
    /// One word is one hint however it was spelled, so a name that is also a saved term is sent
    /// once. The first spelling wins, and names are added first, which keeps the name a person is
    /// addressed by rather than the spelling a term happens to carry.
    private static func list(
        participants: [Participant],
        glossary: [GlossaryTerm],
        usageCounts: [String: Int]
    ) -> (words: [String], terms: [GlossaryTerm]) {
        let ranked = prioritizedTerms(glossary, participants: participants, usageCounts: usageCounts)
        let entries: [(word: String, term: GlossaryTerm?)] =
            participants.map { ($0.name, nil) } + ranked.map { ($0.preferred, $0) }
        var words: [String] = []
        var terms: [GlossaryTerm] = []
        var seen = Set<String>()
        for entry in entries {
            let word = entry.word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty, seen.insert(word.lowercased()).inserted else { continue }
            words.append(word)
            if let term = entry.term { terms.append(term) }
            if words.count == hotwordLimit { break }
        }
        return (words, terms)
    }

    /// Terms that spell a participant name come first, because a misheard name is the most
    /// visible error in a meeting transcript. The remaining terms follow in the order of how
    /// often they already appear in saved transcripts, then alphabetically so the order is
    /// stable for terms that never appeared.
    public static func prioritizedTerms(
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
    /// The list beside the audio is untouched: the names and the highest-priority terms still go
    /// to the reader with every track, which is the only place a term can change what it hears.
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
        transcript: SpeechTranscript,
        participants: [Participant],
        timestamps: Bool = false
    ) -> String {
        let hasDiarization = transcript.segments.contains { $0.speakerIndex != nil }
        let body = transcript.segments.compactMap { segment -> String? in
            let cleaned = clean(segment.text)
            guard !cleaned.isEmpty else { return nil }

            let speakerTag: String
            if let name = segment.speakerName {
                speakerTag = "**\(name)**: "
            } else if let idx = segment.speakerIndex {
                speakerTag = "**\(SpeakerVoiceName.numbered(idx))**: "
            } else if segment.source == .system {
                speakerTag = "**\(SpeakerVoiceName.numbered(0))**: "
            } else if segment.source == nil && !hasDiarization && participants.count == 1 {
                speakerTag = "**\(participants[0].name)**: "
            } else {
                speakerTag = ""
            }
            // The time goes after the speaker tag rather than in front of the line, so the shape a
            // turn has -- a bold label, a colon, the words -- is the shape every reader of this file
            // already knows how to find. The 2026-09-18 notes are read beside the audio, and the time
            // is the only thing that connects the two.
            let stamp = timestamps ? "[\(Self.timestamp(segment.startMs))] " : ""
            return "\(speakerTag)\(stamp)\(cleaned)"
        }.joined(separator: "\n\n")

        return """
            \(PromptBuilder.transcriptHeader(participants: participants))
            \(TranscriptRenderer.foldingSpeakerTurns(body).text)
            """
    }

    /// Strips filler tags a reader writes over silence and normalizes whitespace.
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

    /// The time a turn started, as hours, minutes and seconds.
    ///
    /// Hours are printed even when they are zero. A transcript read beside its recording is jumped
    /// into by time, and "00:12:03" is one shape to read rather than two.
    public static func timestamp(_ milliseconds: Int) -> String {
        let seconds = max(0, milliseconds) / 1000
        return String(
            format: "%02d:%02d:%02d",
            seconds / 3600,
            (seconds % 3600) / 60,
            seconds % 60
        )
    }
}
