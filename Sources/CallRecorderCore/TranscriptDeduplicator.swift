import Foundation

/// Removes the speech a transcript holds twice.
///
/// Two faults put the same sentence into a transcript more than once, and both were measured on
/// the calls in the library before this type existed.
///
/// The audio is transcribed in chunks that overlap, so the last words of one chunk are also the
/// first words of the next, and the overlap is decoded twice. The two copies rarely match word for
/// word: the cut lands in a different place, so one copy starts a syllable earlier and the words
/// around the join come out differently.
///
/// A laptop microphone also hears the meeting coming out of its speakers. That copy is quieter and
/// later than the one taken from the system, and it is transcribed as speech by the other person.
///
/// Both faults have one shape: the same run of words, appearing again a few dozen words later.
/// Over the four calls measured here, 174 runs were found and 1 358 words of 7 917 were repeated,
/// which is 17.2% of the library.
///
/// The rule is deliberately the strict one: only words that are the same words are removed, five
/// at a time. A run where the model heard a word differently is left where it is, because a pass
/// that guesses which of two different words was said is a pass that can put words in someone's
/// mouth. What it does not remove costs a reader a line; what it got wrong would cost the
/// transcript its use as a record.
public enum TranscriptDeduplicator {
    /// What a pass removed, and the segments that are left.
    public struct Outcome: Equatable, Sendable {
        public let segments: [TranscriptSegment]
        /// Runs of repeated speech that were taken out.
        public let removedRuns: Int
        /// Words those runs held, which is what the reader no longer pays for.
        public let removedWords: Int

        public var didChange: Bool { removedRuns > 0 }

        public init(segments: [TranscriptSegment], removedRuns: Int, removedWords: Int) {
            self.segments = segments
            self.removedRuns = removedRuns
            self.removedWords = removedWords
        }
    }

    /// How many words a repeat has to hold before it counts as one.
    ///
    /// Five. A person does say "хорошо, хорошо" and does repeat a number, and two turns that share
    /// four words are ordinary speech. Nobody repeats the same five words by accident inside one
    /// paragraph, and the runs this pass is for are 5 to 20 words long.
    public static let minimumRunWords = 5

    /// How far apart the two copies may be, counted in words.
    ///
    /// A chunk seam or a room echo puts the copy on the next turn, within a few dozen words. The
    /// distance is capped so a phrase said twice in one meeting does not match itself: measured
    /// across the library, 50 words and 400 words remove the same runs.
    public static let maximumGapWords = 200

    // MARK: - Segments

    /// The same pass over segments, for the transcript a call is saved and indexed from.
    ///
    /// A segment that held nothing but a repeat is dropped, so it stops reaching the search index;
    /// a segment that held some is kept with the repeated words removed, so no speech goes with it.
    public static func deduplicate(segments: [TranscriptSegment]) -> Outcome {
        let pass = removeRepeats(from: segments.map(\.text))
        guard pass.removedRuns > 0 else {
            return Outcome(segments: segments, removedRuns: 0, removedWords: 0)
        }
        var kept: [TranscriptSegment] = []
        kept.reserveCapacity(segments.count)
        for (index, segment) in segments.enumerated() {
            let text = pass.lines[index]
            guard !text.isEmpty else { continue }
            guard text != segment.text else {
                kept.append(segment)
                continue
            }
            kept.append(
                TranscriptSegment(
                    startMs: segment.startMs,
                    endMs: segment.endMs,
                    text: text,
                    speakerIndex: segment.speakerIndex,
                    source: segment.source,
                    participantID: segment.participantID,
                    speakerName: segment.speakerName
                )
            )
        }
        return Outcome(
            segments: kept,
            removedRuns: pass.removedRuns,
            removedWords: pass.removedWords
        )
    }

    /// The same pass over a transcript held as text, one line per segment.
    ///
    /// A line whose every word was a repeat is taken out rather than left blank, because the
    /// transcripts this runs over are also the files a person reads, and a blank line between two
    /// paragraphs is a change to the layout.
    public static func deduplicate(
        text: String
    ) -> (text: String, removedRuns: Int, removedWords: Int) {
        let pass = removeRepeats(from: text.components(separatedBy: "\n"))
        var lines: [String] = []
        lines.reserveCapacity(pass.lines.count)
        for (index, line) in pass.lines.enumerated() {
            if pass.emptiedLines.contains(index) { continue }
            lines.append(line)
        }
        return (lines.joined(separator: "\n"), pass.removedRuns, pass.removedWords)
    }

    // MARK: - The pass

    private struct Token {
        let normalized: String
        let range: Range<String.Index>
    }

    private struct RepeatRun {
        let start: Int
        let length: Int
    }

    private struct Pass {
        let lines: [String]
        let removedRuns: Int
        let removedWords: Int
        let emptiedLines: Set<Int>
    }

    /// One pass over the words of every line, read as if the lines were one text.
    ///
    /// Reading across the line breaks is what makes this work on a transcript: the repeated run
    /// starts in one turn and finishes in the next, and a rule that looked at one line at a time
    /// would see two different half-sentences instead.
    private static func removeRepeats(from lines: [String]) -> Pass {
        let tokenized = lines.map(tokens(in:))
        var words: [String] = []
        var owner: [Int] = []
        var offset: [Int] = []
        for (index, tokens) in tokenized.enumerated() {
            words.reserveCapacity(words.count + tokens.count)
            for (position, token) in tokens.enumerated() {
                words.append(token.normalized)
                owner.append(index)
                offset.append(position)
            }
        }
        let found = repeats(in: words)
        guard !found.marked.isEmpty else {
            return Pass(lines: lines, removedRuns: 0, removedWords: 0, emptiedLines: [])
        }

        // Grouped by line, because a line is what gets rebuilt: the repeated run is removed from
        // the text it was found in, and the line around it is left alone. A run that crosses from
        // one turn into the next is removed from both.
        var removals: [Int: [Range<Int>]] = [:]
        for index in found.marked.sorted() {
            let line = owner[index]
            let position = offset[index]
            var ranges = removals[line] ?? []
            if let last = ranges.last, last.upperBound == position {
                ranges[ranges.count - 1] = last.lowerBound..<(position + 1)
            } else {
                ranges.append(position..<(position + 1))
            }
            removals[line] = ranges
        }

        var rebuilt = lines
        var emptied: Set<Int> = []
        for (line, offsets) in removals {
            let tokens = tokenized[line]
            let covers = offsets.reduce(0) { $0 + $1.count }
            if covers >= tokens.count, tokens.count > 0 {
                emptied.insert(line)
                rebuilt[line] = ""
                continue
            }
            let text = tidied(lines[line], removing: offsets.compactMap { offset in
                guard offset.lowerBound < tokens.count, offset.upperBound <= tokens.count else {
                    return nil
                }
                return tokens[offset.lowerBound].range.lowerBound
                    ..< tokens[offset.upperBound - 1].range.upperBound
            })
            // A line left holding nothing but the punctuation around the copy is a line the copy
            // took with it.
            guard text.contains(where: { $0.isLetter || $0.isNumber }) else {
                emptied.insert(line)
                rebuilt[line] = ""
                continue
            }
            rebuilt[line] = text
        }
        return Pass(
            lines: rebuilt,
            removedRuns: found.runs.count,
            removedWords: found.marked.count,
            emptiedLines: emptied
        )
    }

    /// Every run of words that appears again within reach.
    ///
    /// The search walks the text once for each distance between the two copies: five words apart,
    /// six, and so on to the cap. On one of those walks the copy and the original line up word for
    /// word, and the run of equal words is what comes out. Walking the distances instead of
    /// searching each position for a similar run is what keeps the result honest: an alignment is
    /// taken because it holds the same words, not because it scored highest against a threshold,
    /// and a run broken by one word heard differently cannot be stitched back together.
    ///
    /// The first copy of the speech stays. The second one is marked, and it is the one that goes.
    private static func repeats(
        in words: [String]
    ) -> (runs: [RepeatRun], marked: Set<Int>) {
        let count = words.count
        var runs: [RepeatRun] = []
        var marked: Set<Int> = []
        var distance = minimumRunWords
        while distance <= maximumGapWords, distance < count {
            var start = 0
            var length = 0
            var index = 0

            func record() {
                defer { length = 0 }
                guard length >= minimumRunWords else { return }
                let range = (start + distance)..<(start + distance + length)
                guard range.upperBound <= count else { return }
                if !range.allSatisfy({ marked.contains($0) }) {
                    runs.append(RepeatRun(start: range.lowerBound, length: length))
                }
                marked.formUnion(range)
            }

            while index + distance < count {
                if words[index] == words[index + distance] {
                    if length == 0 { start = index }
                    length += 1
                } else {
                    record()
                }
                index += 1
            }
            record()
            distance += 1
        }
        return (runs, marked)
    }

    // MARK: - Text

    private static func tokens(in line: String) -> [Token] {
        var tokens: [Token] = []
        var index = line.startIndex
        while index < line.endIndex {
            guard isWordCharacter(line[index]) else {
                index = line.index(after: index)
                continue
            }
            let start = index
            var end = line.index(after: index)
            while end < line.endIndex, isWordCharacter(line[end]) {
                end = line.index(after: end)
            }
            tokens.append(Token(normalized: String(line[start..<end]).lowercased(), range: start..<end))
            index = end
        }
        return tokens
    }

    /// Whether a character belongs to a word.
    ///
    /// Letters and digits, in any script, so Russian and English are read the same way and a word
    /// the model wrote with its own punctuation still lines up. A hyphen is not part of a word, so
    /// the two halves of a hyphenated term are read as the two words they are.
    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "'" || character == "’"
    }

    /// The line without the ranges, with the gaps they leave closed.
    ///
    /// Removing a word leaves the spaces that were around it, and the punctuation that followed it
    /// now has a space in front. Only the line a word came out of is touched, so a transcript whose
    /// punctuation was already odd keeps the shape it had.
    private static func tidied(_ line: String, removing ranges: [Range<String.Index>]) -> String {
        let ordered = ranges.sorted { $0.lowerBound < $1.lowerBound }
        var kept = ""
        var cursor = line.startIndex
        for range in ordered {
            guard range.lowerBound >= cursor else { continue }
            kept += line[cursor..<range.lowerBound]
            cursor = range.upperBound
        }
        kept += line[cursor...]
        return closing(kept).trimmingCharacters(in: .whitespaces)
    }

    /// Closes the gaps a removal left, using the rules the renderer already writes by.
    private static func closing(_ text: String) -> String {
        // The mark the copy ended on can be left doubled, as in "Хорошо,, если успеем". Only the
        // marks that a sentence cannot double are collapsed; a full stop is left alone, because
        // three of them are an ellipsis and not a fault.
        var result = text.replacingOccurrences(
            of: "([,;:!?])[ \\t]*\\1+",
            with: "$1",
            options: .regularExpression
        )
        // A copy taken from the front of a turn leaves the comma that followed it. Nothing in the
        // renderer starts a turn with one, so it belongs to the speech that was removed.
        result = result.replacingOccurrences(
            of: "^[,;:]+[ \\t]*",
            with: "",
            options: .regularExpression
        )
        result = result.replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
        result = result.replacingOccurrences(
            of: "[ \\t]+([,.;:!?…”\\)\\]»])",
            with: "$1",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: "([„“«\\(\\[])[ \\t]+",
            with: "$1",
            options: .regularExpression
        )
        return result
    }
}
