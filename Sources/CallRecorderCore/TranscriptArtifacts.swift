import Foundation

/// The three things a transcript can contain that are not speech.
///
/// A reader is a language model, and a language model that loses the audio does not stop: it
/// repeats the last thing it was given. The library carries the result of that in four shapes, and
/// every one of them was measured on the 80 saved transcripts before this type existed:
///
/// - **A prompt echo.** The prompt names the participants and the glossary. When the model loses
///   the audio it can write that list into the transcript as if someone had said it. Every hit in
///   the library had the shape `TERM (also TERM, TERM)`, which is a transcript header, not a
///   sentence. 174 lines across 3 calls.
/// - **A non-speech tag.** The model marks music, silence, and laughter with a bracketed word. The
///   renderer already dropped the English ones it knew, so what survived was the ones it did not:
///   `[музыка]` 123 times, `[No audio]` 114, `[Реклама]`, `[Pause]`, `[смех]`. 271 lines across 6
///   calls.
/// - **A repetition loop.** The same whole sentence, over and over, at the same length. Two
///   sentences account for all 383 duplicated lines in the library: a Russian question repeated
///   305 times and an English clause repeated 78.
///
/// A person does say "no" twelve times and does thank someone twice. That is why the loop rule
/// asks for a long line and many copies, and why the other two rules never look at how often a
/// line appears: they ask what the line *is*, and neither shape is sayable.
public enum TranscriptArtifacts {
    /// Bumped when a rule changes, so a library cleaned by an older rule is cleaned again.
    ///
    /// The value is part of what decides whether the repair pass runs, which is what keeps a rule
    /// change from needing anyone to remember to press a button.
    ///
    /// Four is the speaker-paragraph rule: consecutive turns of one voice are joined into one
    /// paragraph by ``TranscriptRenderer/foldingSpeakerTurns(_:maximumParagraphCharacters:)``.
    /// It is a layout rule rather than a cleaning rule, and it is counted by this version for the
    /// same reason: a library that has not been folded should be folded once, without a button.
    /// Five adds the repeated-speech rule, which is not a not-speech rule at all: it removes words
    /// that were said twice, because a chunk seam and a room echo write the same sentence into a
    /// transcript once per copy. It travels with this version because it rewrites the same files in
    /// the same pass, and because a library recorded before it exists is owed the same repair.
    /// Six adds the phrase loop inside a single line: the 2026-09-18 call holds
    /// "межми грешен был межми грешен межми грешен", three copies of one two-word phrase in one
    /// segment, which the cross-segment rule could not see. A line that repeats a phrase that many
    /// times is a decoder stuck on its own output, so the copies after the first go.
    public static let ruleVersion = 6

    /// The time range an early version of the app printed at the front of every paragraph.
    ///
    /// Three transcripts in the library still carry one, 1476 of them in a single file, and the
    /// markers cost about a quarter of that file's bytes. The shape is narrow on purpose: two clock
    /// times joined by an arrow, both inside one pair of square brackets, at the very start of the
    /// line. A sentence that merely mentions a time does not match, because a sentence has words
    /// around the number.
    private static let timestampPrefix = try! NSRegularExpression(
        pattern: "^\\[\\d{1,2}:\\d{2}:\\d{2}(?:[.,]\\d{1,3})?"
            + "\\s*(?:→|-->|->|–|-){1}\\s*"
            + "\\d{1,2}:\\d{2}:\\d{2}(?:[.,]\\d{1,3})?\\]\\s*"
    )

    /// The same line without a leading timestamp, and whether there was one to take off.
    static func strippingTimestamp(_ line: String) -> (line: String, stripped: Bool) {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = timestampPrefix.firstMatch(in: line, range: range) else {
            return (line, false)
        }
        guard let matchRange = Range(match.range, in: line) else { return (line, false) }
        return (String(line[matchRange.upperBound...]), true)
    }

    /// How long a line has to be before repeating it verbatim counts as a fault.
    ///
    /// Forty characters is roughly eight spoken words. A person can repeat "Спасибо." three times,
    /// and the renderer splits that into short lines that this rule leaves alone. Nobody produces
    /// the same long clause again and again, and the library's two real loops repeat 78 and 305
    /// times, so the margin on this floor is wide.
    public static let loopMinimumCharacters = 40

    /// How many verbatim copies of one long line are a fault.
    ///
    /// Five. One copy is kept, and the other four are removed, because a sentence said twice is
    /// ordinary and a sentence said five times is a model that has stopped listening.
    public static let loopMinimumRun = 5

    /// The bounds of the phrase the loop search looks for inside one line, in words.
    ///
    /// Two words is the shortest phrase that can read as a loop rather than as emphasis: a person
    /// does say "no, no, no", and a single word is left alone for exactly that reason. Eight keeps
    /// the search cheap and stops it from calling a long stretch of ordinary speech a loop.
    static let phraseLoopMinimumWords = 2
    static let phraseLoopMaximumWords = 8

    /// How many copies of one phrase inside a single line are a fault.
    static let phraseLoopMinimumCopies = 3

    /// How much of the line the extra copies have to make up before they are a fault.
    ///
    /// The 2026-09-18 line spends 4 of its 10 words on copies after the first. A threshold that low
    /// would fire on a two-word echo in a long paragraph, so the copies must also be a third of the
    /// line. A person repeating a phrase for effect keeps the rest of the sentence around it; a
    /// decoder loop has nothing else to say.
    static let phraseLoopMinimumShare = 0.35

    /// The phrase a line repeats, and how many times, or nil when the line does not loop.
    ///
    /// The longest phrase wins. A four-word loop is also two two-word loops, and cutting the long
    /// one out is what leaves the line as one statement instead of four pieces of shorthand.
    ///
    /// The share is a parameter because the two callers weigh the risk differently: the cleaning
    /// pass shortens the line and can afford to be generous, while the quality guard below throws
    /// the whole recording away and only fires when the loop is most of what the line says.
    static func repeatedPhrase(
        in words: [String],
        minimumShare: Double = phraseLoopMinimumShare
    ) -> (phrase: [String], copies: Int)? {
        guard words.count >= phraseLoopMinimumWords * phraseLoopMinimumCopies else { return nil }
        let longest = min(phraseLoopMaximumWords, words.count / phraseLoopMinimumCopies)
        guard longest >= phraseLoopMinimumWords else { return nil }
        for length in stride(from: longest, through: phraseLoopMinimumWords, by: -1) {
            // Copies are counted the way the cleaning pass removes them: laid end to end, each one
            // taken whole. Counting every start position instead made overlapping runs of a short
            // phrase look like a loop, which is how a person agreeing six times in one breath --
            // "да да да да да да" on the 2026-09-23 call -- held four overlapping "да да да" runs,
            // 53% of the line, and cost the whole 68 minute recording, twice. The cleaner can only
            // take out copies that do not overlap, so the guard must count the same ones.
            var copies: [[String]: Int] = [:]
            for start in 0...(words.count - length) {
                let phrase = Array(words[start..<(start + length)])
                guard copies[phrase] == nil else { continue }
                let count = nonOverlappingCopies(of: phrase, in: words)
                guard count >= phraseLoopMinimumCopies else { continue }
                copies[phrase] = count
            }
            let duplicated = copies.values.map { ($0 - 1) * length }.max() ?? 0
            guard Double(duplicated) / Double(words.count) >= minimumShare else {
                // A shorter phrase may still carry a large enough share, so the search goes on
                // rather than stopping at the first length with a hit.
                continue
            }
            let best = copies.max { left, right in
                left.value == right.value
                    ? left.key.count < right.key.count
                    : left.value < right.value
            }
            guard let best else { continue }
            return (best.key, best.value)
        }
        return nil
    }

    /// How many copies of one phrase sit end to end in a line.
    private static func nonOverlappingCopies(of phrase: [String], in words: [String]) -> Int {
        var count = 0
        var index = 0
        while index + phrase.count <= words.count {
            if Array(words[index..<(index + phrase.count)]) == phrase {
                count += 1
                index += phrase.count
            } else {
                index += 1
            }
        }
        return count
    }

    /// Removes the copies of a repeated phrase after the first, keeping the line's order.
    ///
    /// Repeats until no phrase is left to collapse, because cutting out the outer loop can expose
    /// the next one. The bound is a guard against a line nobody has seen, not an expected limit:
    /// every round strictly shortens the line.
    static func collapsingPhraseLoops(in line: String) -> (line: String, collapsed: Int) {
        guard !line.isEmpty else { return (line, 0) }
        var words = line.split(separator: " ").map(String.init)
        var collapsed = 0
        for _ in 0..<4 {
            guard let loop = repeatedPhrase(in: words) else { break }
            var kept: [String] = []
            kept.reserveCapacity(words.count)
            var index = 0
            var keptTheFirst = false
            while index < words.count {
                let end = index + loop.phrase.count
                if end <= words.count, Array(words[index..<end]) == loop.phrase {
                    if keptTheFirst {
                        collapsed += 1
                    } else {
                        keptTheFirst = true
                        kept.append(contentsOf: loop.phrase)
                    }
                    index = end
                    continue
                }
                kept.append(words[index])
                index += 1
            }
            words = kept
        }
        guard collapsed > 0 else { return (line, 0) }
        return (words.joined(separator: " "), collapsed)
    }

    /// What a cleaned transcript lost, so a repair can report what it did rather than a boolean.
    public struct Outcome: Equatable, Sendable {
        public let text: String
        public let promptEchoes: Int
        public let nonSpeechTags: Int
        public let loopDuplicates: Int
        /// Copies of a short phrase removed from inside one line.
        ///
        /// Counted apart from the whole-line duplicates because the two rules see different shapes:
        /// a duplicate is a line that came back, and a phrase loop is one line that says the same
        /// thing many times over. Both are the decoder repeating itself.
        public let collapsedPhrases: Int
        /// Blank lines that ran together once the lines between them were removed.
        ///
        /// Counted separately from the removals because it is a different kind of change: nothing
        /// was taken out of the transcript, and its whitespace was put back to the one blank line
        /// markdown uses between two segments. It is part of ``didChange`` so a transcript whose
        /// only fault is that whitespace is still tidied, which matters for a library cleaned by an
        /// earlier rule that left the runs behind.
        public let blankLinesCollapsed: Int
        /// Lines that carried a timestamp and no longer do.
        ///
        /// A third kind of change, and the only one that shortens a line instead of removing one.
        /// The transcript is read for what was said; a time range ahead of every paragraph is
        /// machine furniture. The segments keep their real times, so nothing that a time could be
        /// used for is lost -- only the copy of it printed into the file a person reads.
        public let strippedTimestamps: Int

        public var removedLines: Int { promptEchoes + nonSpeechTags + loopDuplicates }
        public var didChange: Bool {
            removedLines > 0 || blankLinesCollapsed > 0 || strippedTimestamps > 0
                || collapsedPhrases > 0
        }

        public init(
            text: String,
            promptEchoes: Int = 0,
            nonSpeechTags: Int = 0,
            loopDuplicates: Int = 0,
            collapsedPhrases: Int = 0,
            blankLinesCollapsed: Int = 0,
            strippedTimestamps: Int = 0
        ) {
            self.text = text
            self.promptEchoes = promptEchoes
            self.nonSpeechTags = nonSpeechTags
            self.loopDuplicates = loopDuplicates
            self.collapsedPhrases = collapsedPhrases
            self.blankLinesCollapsed = blankLinesCollapsed
            self.strippedTimestamps = strippedTimestamps
        }
    }

    /// A bracketed run that fills a line. Anything with words around it is someone speaking.
    ///
    /// Both bracket shapes count. The reader writes `[музыка]` and it also writes `(Music)`, and the
    /// library holds both: the round-bracket form was in one of the three recordings that turned
    /// out to hold nothing, so a rule that only knew the square one would have left that file in
    /// place with nothing in it but a marker and a hallucination.
    private static let tagOnly = try! NSRegularExpression(
        pattern: "^[\\[\\(][^\\[\\]\\(\\)]{1,40}[\\]\\)]\\.?$"
    )

    /// `TERM (also A, B)` — the shape a transcript header writes and a sentence does not have.
    private static let parenthesised = try! NSRegularExpression(
        pattern: "^(?<term>[^()]{1,60}?)\\s*\\((?:also\\s+)?(?<aliases>[^()]{1,200}?)\\)\\.?$"
    )

    /// Whether a line is the glossary written back out as speech.
    ///
    /// The test is narrow on purpose. It asks whether the word before the bracket is also one of
    /// the words inside it, or whether the list inside repeats a word — `WMS (also WMS, WMS)`,
    /// `VAT (VAT)`. Normal writing never does that, and a real aside such as `Geodis (north)` has
    /// neither shape, so it is left where it is.
    public static func isPromptEcho(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        guard let match = parenthesised.firstMatch(in: trimmed, range: range) else { return false }
        guard
            let termRange = Range(match.range(withName: "term"), in: trimmed),
            let aliasRange = Range(match.range(withName: "aliases"), in: trimmed)
        else { return false }
        let term = trimmed[termRange].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return false }
        let aliases = trimmed[aliasRange]
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !aliases.isEmpty else { return false }
        if aliases.contains(term) { return true }
        return Set(aliases).count < aliases.count
    }

    /// Whether a line is a bracketed marker rather than a word.
    ///
    /// The line has to be nothing but the bracket. `[музыка]` is a marker; a sentence that happens
    /// to contain a bracket is speech and is kept.
    public static func isNonSpeechTag(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        return tagOnly.firstMatch(in: trimmed, range: range) != nil
    }

    /// Removes the lines that are not speech, and the repeated copies of the ones that are.
    ///
    /// The pass is line-by-line rather than global: a stored transcript is one line per segment, so
    /// a rule that looked at the whole text could not tell which copies to drop. Order is kept and
    /// the first copy of a loop is the one that survives, so a transcript still reads in the order
    /// it was spoken.
    public static func filter(_ text: String) -> Outcome {
        // Removing a run can bring two other runs together, and one call in the library is built
        // almost entirely from ninety runs of one sentence. A single pass would leave twenty-five
        // copies behind; the pass therefore repeats until the text stops changing. Each round
        // strictly shortens the text, so the loop ends, and the cap is there because a rule this
        // shape should never be able to run away on a text nobody has seen.
        var current = text
        var echoes = 0
        var tags = 0
        var loops = 0
        var phrases = 0
        var blanks = 0
        var stamps = 0
        for _ in 0..<8 {
            let pass = singlePass(current)
            echoes += pass.promptEchoes
            tags += pass.nonSpeechTags
            loops += pass.loopDuplicates
            phrases += pass.collapsedPhrases
            blanks += pass.blankLinesCollapsed
            stamps += pass.strippedTimestamps
            guard pass.text != current else { break }
            current = pass.text
        }
        // Nothing at all moved, so the text is returned byte for byte and the caller can tell that
        // this transcript was not this pass's business.
        guard current != text else { return Outcome(text: text) }
        return Outcome(
            text: current,
            promptEchoes: echoes,
            nonSpeechTags: tags,
            loopDuplicates: loops,
            collapsedPhrases: phrases,
            blankLinesCollapsed: blanks,
            strippedTimestamps: stamps
        )
    }

    /// One round: every rule applied once, in the order a transcript reads.
    private static func singlePass(_ text: String) -> Outcome {
        // The timestamp comes off, and a phrase loop inside the line is cut down, before the rules
        // below judge the line. A line that says the same two words three times is a decoder stuck
        // on its own output, and cutting it here means the duplicate rule and the search index see
        // the same text the reader will.
        let lines: [(line: String, hadStamp: Bool, collapsed: Int)] = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { rawLine in
                let raw = rawLine.trimmingCharacters(in: .whitespaces)
                let (withoutStamp, hadStamp) = strippingTimestamp(raw)
                let (line, collapsed) = collapsingPhraseLoops(in: withoutStamp)
                return (line, hadStamp, collapsed)
            }
        guard !lines.isEmpty else { return Outcome(text: text) }

        var kept: [String] = []
        kept.reserveCapacity(lines.count)
        var echoes = 0
        var tags = 0
        var loops = 0
        var phrases = 0
        var blanksCollapsed = 0
        var stamps = 0
        var index = 0
        while index < lines.count {
            let entry = lines[index]
            let line = entry.line
            let hadStamp = entry.hadStamp
            var last = index
            while last + 1 < lines.count, lines[last + 1].line == line {
                last += 1
            }
            let run = last - index + 1
            if hadStamp { stamps += run }
            for position in index...last { phrases += lines[position].collapsed }

            if !line.isEmpty, isPromptEcho(line) {
                echoes += run
            } else if !line.isEmpty, isNonSpeechTag(line) {
                tags += run
            } else if run >= loopMinimumRun, line.count >= loopMinimumCharacters {
                // The first copy stays. It is only the copies the model invented that go.
                loops += run - 1
                kept.append(line)
            } else {
                // The line as it reads without its timestamp. A run is made of lines that match
                // once the time in front of each is gone, so writing the one text back is what
                // the run was.
                for _ in 0..<run { kept.append(line) }
            }
            index = last + 1
        }

        // Dropping a line leaves the blank line that separated it from its neighbours, so a run of
        // removed lines leaves a run of empty lines. Markdown uses one blank line between two
        // paragraphs, so the runs are collapsed back to one: a transcript is read for what it says,
        // and a screen of whitespace costs the reader and the search index the same as a screen of
        // invented lines.
        //
        // This runs whether or not a line was removed. A transcript holding two blank lines where
        // the app writes one is a transcript an earlier cleanup already emptied, and a rule that
        // only tidied whitespace on a pass that also removed something would never reach it. A
        // transcript that is already in the shape the app writes is returned untouched, so this
        // still costs nothing on a library that is already clean.
        var collapsed: [String] = []
        collapsed.reserveCapacity(kept.count)
        for line in kept {
            if line.isEmpty, collapsed.last?.isEmpty == true {
                blanksCollapsed += 1
                continue
            }
            collapsed.append(line)
        }
        while collapsed.first?.isEmpty == true {
            collapsed.removeFirst()
            blanksCollapsed += 1
        }
        while collapsed.last?.isEmpty == true {
            collapsed.removeLast()
            blanksCollapsed += 1
        }
        let cleaned = collapsed.joined(separator: "\n")
        return Outcome(
            text: cleaned,
            promptEchoes: echoes,
            nonSpeechTags: tags,
            loopDuplicates: loops,
            collapsedPhrases: phrases,
            blankLinesCollapsed: blanksCollapsed,
            strippedTimestamps: stamps
        )
    }

    /// The same pass over segments, for the JSON a call is indexed from.
    ///
    /// A segment that is nothing but an artefact is dropped, which is what stops the search index
    /// from carrying it; a segment that only holds some is kept with the rest removed, so no speech
    /// goes with it.
    public static func filter(
        segments: [TranscriptSegment]
    ) -> (segments: [TranscriptSegment], outcome: Outcome) {
        var kept: [TranscriptSegment] = []
        kept.reserveCapacity(segments.count)
        var echoes = 0
        var tags = 0
        var loops = 0
        var phrases = 0
        var index = 0
        var stamps = 0
        // The timestamp comes off each segment first, so the two rules below judge the words a
        // segment holds rather than the time in front of them, and the text that reaches the index
        // is the text a person reads.
        let stamped = segments.map { segment -> TranscriptSegment in
            let (withoutStamp, stripped) = strippingTimestamp(segment.text)
            if stripped { stamps += 1 }
            // The phrase loop is cut down here, before the duplicate rule measures runs and before
            // anything is written: a segment that holds the same phrase three times is one stuck
            // line, and only the first copy of it was said.
            let (text, collapsed) = collapsingPhraseLoops(in: withoutStamp)
            phrases += collapsed
            guard stripped || collapsed > 0 else { return segment }
            return TranscriptSegment(
                startMs: segment.startMs,
                endMs: segment.endMs,
                text: text,
                speakerIndex: segment.speakerIndex,
                source: segment.source,
                participantID: segment.participantID,
                speakerName: segment.speakerName
            )
        }
        // A run is measured over the segments that are left after the two sayability rules, so a
        // marker between two halves of a loop does not hide the loop.
        let surviving = stamped.filter { segment in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if isPromptEcho(text) { echoes += 1; return false }
            if isNonSpeechTag(text) { tags += 1; return false }
            return true
        }

        while index < surviving.count {
            let text = surviving[index].text.trimmingCharacters(in: .whitespacesAndNewlines)
            var last = index
            while last + 1 < surviving.count,
                  surviving[last + 1].text.trimmingCharacters(in: .whitespacesAndNewlines) == text
            {
                last += 1
            }
            let run = last - index + 1
            if run >= loopMinimumRun, text.count >= loopMinimumCharacters {
                loops += run - 1
                kept.append(surviving[index])
            } else {
                kept.append(contentsOf: surviving[index...last])
            }
            index = last + 1
        }
        let outcome = Outcome(
            text: kept.map(\.text).joined(separator: "\n"),
            promptEchoes: echoes,
            nonSpeechTags: tags,
            loopDuplicates: loops,
            collapsedPhrases: phrases,
            strippedTimestamps: stamps
        )
        return (kept, outcome)
    }

    // MARK: - A recording that holds no speech at all

    /// The phrases a reader answers silence with.
    ///
    /// A reader does not return nothing for silence. It returns what it was trained to see printed
    /// at the end of a video, because that is the text most often next to no speech. These are the
    /// phrases that cannot be said in a meeting: nobody asks a colleague to subscribe, and nobody
    /// thanks a warehouse operator for watching. Each is stored folded to lowercase, with its
    /// punctuation removed and its words separated by single spaces, because the model writes them
    /// with whatever punctuation it feels like.
    ///
    /// Nothing that a person can say belongs here. "Bye", "Okay", "Спасибо" and "Hello" are all
    /// absent on purpose: they are short, they repeat, and every one of them is real speech, which
    /// is exactly why the rule below cannot be a length or a repetition test.
    static let silencePhrases: Set<String> = [
        "thank you for watching", "thanks for watching", "thank you for watching my video",
        "i hope you enjoyed this video", "hope you enjoyed this video",
        "i hope you enjoyed watching", "thanks for watching this video",
        "see you next time", "see you in the next video", "see you in the next one",
        "please subscribe", "subscribe to my channel", "subscribe to the channel",
        "like and subscribe", "dont forget to subscribe", "please like and subscribe",
        "subtitles by", "subtitle by", "subtitled by", "transcription by", "transcribed by",
        "translated by", "amara org", "www amara org", "captions by", "captioning by",
        "thanks for watching and i will see you in the next video",
        "продолжение следует", "спасибо за просмотр", "подписывайтесь на канал",
        "подпишись на канал", "поставь лайк", "поставьте лайк", "ставлю лайки",
        "подписываюся на канал", "ставлю лайки и подписываюся на канал",
        "спасибо за внимание", "всем пока не забудьте подписаться",
    ]

    /// Counting that the model emits over noise, which it also does over a tone or a test signal.
    ///
    /// Kept apart from the phrases above because it is a shape rather than a sentence, and a
    /// meeting really can contain somebody counting. It only ever disqualifies a recording whose
    /// whole text is numbers, and a recording like that is a test signal rather than a call.
    private static let countingOnly = try! NSRegularExpression(
        pattern: "^[0-9]+([,. ]+[0-9]+)*\\.?$"
    )

    private static func isCounting(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        return countingOnly.firstMatch(in: trimmed, range: range) != nil
    }

    /// The same counting written as words, which is how the model writes it about half the time:
    /// `One, two, three, four, five.`
    ///
    /// A person counting stock does say this out loud, so it is not a phrase on the list above. It
    /// is a shape, and the rule that uses it asks for **every** line of the recording to be one, so
    /// it can only ever disqualify a recording whose whole content is a count. A meeting has other
    /// lines and is never touched by it.
    private static let numberWords: Set<String> = [
        "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
        "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen",
        "eighteen", "nineteen", "twenty", "thirty", "forty", "fifty", "sixty", "seventy",
        "eighty", "ninety", "hundred", "thousand",
        "один", "два", "три", "четыре", "пять", "шесть", "семь", "восемь", "девять",
        "десять", "раз",
    ]

    private static func isCountedOut(_ line: String) -> Bool {
        let tokens = line
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard tokens.count >= 3 else { return false }
        return tokens.allSatisfy { numberWords.contains($0) || Int($0) != nil }
    }

    /// Whether a line is one of the shapes the model writes over silence.
    private static func isSilenceLine(_ line: String) -> Bool {
        if isNonSpeechTag(line) { return true }
        if isCounting(line) { return true }
        if isCountedOut(line) { return true }
        let folded = line
            .lowercased()
            .replacingOccurrences(of: "[", with: "")
            .replacingOccurrences(of: "]", with: "")
            .components(separatedBy: CharacterSet.alphanumerics.union(.whitespaces).inverted)
            .joined(separator: " ")
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !folded.isEmpty else { return true }
        return silencePhrases.contains(folded)
    }

    /// Whether a whole transcript holds nothing a person said.
    ///
    /// Every line has to be a marked bracket, a silence phrase, or a run of numbers. One line of
    /// anything else and the recording is real, which is the property that makes this safe to use
    /// where the consequence is that a file is removed.
    ///
    /// This is deliberately NOT the test the app uses to decide whether to write a file back. That
    /// one also refuses a transcript it judges repetitive, and refusing to write costs nothing. It
    /// was measured against this library and it flags four recordings of 6 680, 18 136, 56 461 and
    /// 69 819 characters -- real meetings, in Russian and in English, that happen to repeat a
    /// sentence more often than a threshold allows. Writing is cheap and reversible; deleting is
    /// neither, so deleting asks the narrow question and nothing else.
    public static func holdsOnlySilence(_ text: String) -> Bool {
        let lines = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return false }
        return lines.allSatisfy(isSilenceLine)
    }
}
