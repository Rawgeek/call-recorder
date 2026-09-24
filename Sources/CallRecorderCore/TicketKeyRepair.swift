import Foundation

/// Puts back the ticket numbers the decoder clipped or split in two.
///
/// A call is full of keys nobody can hear as words: FP-18286, FP-18167, FP-18313. Whisper writes
/// them the way they sounded to it -- "1867" for one, "313" for another, "182 86" when the seam
/// between two segments fell inside the number -- and a transcript whose whole point is the keys
/// then cannot be searched for them.
///
/// The repair is not a guess about what a number should be. It works only against a key the same
/// call writes out in full somewhere: a clipped number is put back when it is the tail of exactly
/// one key the file itself holds, and a number split across two segments is joined when the two
/// halves sound out the digits of exactly one such key. That is what makes it a repair: the file
/// is the evidence.
public enum TicketKeyRepair {
    /// What a repair pass changed.
    public struct Outcome: Equatable, Sendable {
        public let text: String
        /// Keys written back, each counted once.
        public let repairs: Int

        public init(text: String, repairs: Int) {
            self.text = text
            self.repairs = repairs
        }
    }

    /// How many digits a bare number may have and still be read as a clipped key.
    ///
    /// Three, and only where the line says it is talking about a ticket: "313" is a quantity in any
    /// other sentence. Four or five digits are long enough to be a key on their own, and the rule
    /// below still needs one the call writes in full.
    static let shortestBareDigits = 3

    /// A key written in full, and the digits that identify it.
    struct Key: Equatable {
        let text: String
        let digits: String
    }

    /// The keys the text writes out in full.
    static func keys(in text: String) -> [Key] {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var seen = Set<String>()
        var keys: [Key] = []
        for match in keyPattern.matches(in: text, options: [], range: range) {
            guard
                let fullRange = Range(match.range, in: text),
                let digitsRange = Range(match.range(at: 1), in: text)
            else { continue }
            let full = String(text[fullRange])
            let digits = String(text[digitsRange])
            guard seen.insert(full.lowercased()).inserted else { continue }
            keys.append(Key(text: full, digits: digits))
        }
        return keys
    }

    /// The one key these digits belong to, or nil when the call holds none or several.
    ///
    /// A decoder drops a digit as well as clipping the end: "1867" is what FP-18167 sounds like with
    /// one digit lost, and "313" is the tail of FP-18313. So the digits have to sit inside the key's
    /// digits in order, and the key may not be more than two digits longer, which is what stops a
    /// four-digit figure from claiming a six-digit key. A number two of the call's keys could explain
    /// is left alone: that is not evidence, it is a coincidence.
    static func key(explaining digits: String, in keys: [Key]) -> Key? {
        let matches = keys.filter { key in
            key.digits == digits
                || key.digits.hasSuffix(digits)
                || (key.digits.count - digits.count <= 2 && isSubsequence(digits, of: key.digits))
        }
        return matches.count == 1 ? matches[0] : nil
    }

    /// Whether the digits appear inside the other run in order, with anything between them.
    static func isSubsequence(_ digits: String, of other: String) -> Bool {
        var remaining = Substring(other)
        for digit in digits {
            guard let found = remaining.firstIndex(of: digit) else { return false }
            remaining = remaining[remaining.index(after: found)...]
        }
        return true
    }

    /// Rewrites the clipped and split numbers in one text.
    public static func repairing(_ text: String) -> Outcome {
        let keys = keys(in: text)
        guard !keys.isEmpty else { return Outcome(text: text, repairs: 0) }
        var repairs = 0
        // The split number first: joining the halves is what makes the digits long enough for the
        // clipped-number pass to have something to repair.
        var working = joiningSplitNumbers(in: text, keys: keys, repairs: &repairs)
        working = repairingClippedNumbers(in: working, keys: keys, repairs: &repairs)
        return Outcome(text: working, repairs: repairs)
    }

    /// The same repair over the segments of a call, including a number split between two of them.
    ///
    /// A whisper segment ends where the decoder stopped, and the seam can fall inside a ticket
    /// number: the 2026-09-18 call has "182" ending one segment and "86" opening the next. The text
    /// of the two is read as one place for that reason, and the key is written into the first of
    /// them.
    public static func repairing(
        segments: [TranscriptSegment]
    ) -> (segments: [TranscriptSegment], repairs: Int) {
        guard !segments.isEmpty else { return (segments, 0) }
        let keys = keys(in: segments.map(\.text).joined(separator: " "))
        guard !keys.isEmpty else { return (segments, 0) }
        var repairs = 0
        var texts = segments.map(\.text)

        // The seam first, because a number the model split is not repairable while it is in two
        // pieces.
        for index in texts.indices.dropLast() {
            guard
                let tail = trailingDigits(texts[index]),
                let head = leadingDigits(texts[index + 1])
            else { continue }
            let digits = tail + head
            guard digits.count >= shortestBareDigits, let key = key(explaining: digits, in: keys),
                key.digits == digits
            else { continue }
            texts[index] = replacing(texts[index], trailingDigitsWith: key.text)
            texts[index + 1] = replacing(texts[index + 1], leadingDigitsWith: "")
                // The digits took their punctuation with them: what is left of ", и это важно." is
                // the sentence, not a leading comma.
                .trimmingCharacters(in: CharacterSet(charactersIn: " \t,;:"))
            repairs += 1
        }

        for index in texts.indices {
            let outcome = repairing(texts[index])
            guard outcome.repairs > 0 else { continue }
            texts[index] = outcome.text
            repairs += outcome.repairs
        }
        let repaired = segments.enumerated().map { index, segment in
            texts[index] == segment.text
                ? segment
                : Self.replacingText(of: segment, with: texts[index])
        }
        return (repaired, repairs)
    }

    /// The same segment with its text replaced, keeping the timing and the speaker.
    static func replacingText(of segment: TranscriptSegment, with text: String) -> TranscriptSegment {
        TranscriptSegment(
            startMs: segment.startMs,
            endMs: segment.endMs,
            text: text,
            speakerIndex: segment.speakerIndex,
            source: segment.source,
            participantID: segment.participantID,
            speakerName: segment.speakerName
        )
    }

    // MARK: - The two shapes

    /// Joins runs of digits the decoder split with a space, when the run is a key the call holds.
    static func joiningSplitNumbers(
        in text: String,
        keys: [Key],
        repairs: inout Int
    ) -> String {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = splitNumberPattern.matches(in: text, options: [], range: range)
        guard !matches.isEmpty else { return text }
        var output = ""
        output.reserveCapacity(text.count)
        var cursor = text.startIndex
        for match in matches {
            guard
                let matchRange = Range(match.range, in: text),
                let firstRange = Range(match.range(at: 1), in: text),
                let secondRange = Range(match.range(at: 2), in: text)
            else { continue }
            let digits = String(text[firstRange]) + String(text[secondRange])
            guard let key = key(explaining: digits, in: keys), key.digits == digits else { continue }
            output.append(contentsOf: text[cursor..<matchRange.lowerBound])
            output.append(contentsOf: key.text)
            cursor = matchRange.upperBound
            repairs += 1
        }
        output.append(contentsOf: text[cursor...])
        return output
    }

    /// Writes the prefix back onto a number the decoder clipped to the tail of a key.
    static func repairingClippedNumbers(
        in text: String,
        keys: [Key],
        repairs: inout Int
    ) -> String {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = bareNumberPattern.matches(in: text, options: [], range: range)
        guard !matches.isEmpty else { return text }
        var output = ""
        output.reserveCapacity(text.count)
        var cursor = text.startIndex
        for match in matches {
            guard let matchRange = Range(match.range, in: text) else { continue }
            let digits = String(text[matchRange])
            // A number equal to a key's own digits is the key spoken without its prefix, so the
            // prefix is written back there too: the file already holds the key, and the number
            // standing alone is the copy that cannot be searched for.
            guard let key = key(explaining: digits, in: keys) else { continue }
            // A three-digit number is only a ticket where the sentence says so. Everything longer
            // still needs a key of the call to end with it, which no quantity or date does by
            // accident.
            if digits.count == shortestBareDigits,
                !mentionsTicket(in: line(around: matchRange, of: text)) {
                continue
            }
            output.append(contentsOf: text[cursor..<matchRange.lowerBound])
            output.append(contentsOf: key.text)
            cursor = matchRange.upperBound
            repairs += 1
        }
        output.append(contentsOf: text[cursor...])
        return output
    }

    // MARK: - Text helpers

    /// The line a range sits on, so a rule can read the sentence around a number.
    static func line(around range: Range<String.Index>, of text: String) -> String {
        var start = range.lowerBound
        while start > text.startIndex {
            let previous = text.index(before: start)
            if text[previous] == "\n" { break }
            start = previous
        }
        var end = range.upperBound
        while end < text.endIndex, text[end] != "\n" {
            end = text.index(after: end)
        }
        return String(text[start..<end])
    }

    static func mentionsTicket(in line: String) -> Bool {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        return ticketWordPattern.firstMatch(in: line, options: [], range: range) != nil
    }

    /// The digits a segment ends with, or nil when it ends with anything else.
    static func trailingDigits(_ text: String) -> String? {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = trailingDigitsPattern.firstMatch(in: text, options: [], range: range),
            let digitsRange = Range(match.range, in: text)
        else { return nil }
        return String(text[digitsRange])
    }

    /// The digits a segment starts with, or nil when it starts with anything else.
    static func leadingDigits(_ text: String) -> String? {
        let trimmed = text.drop(while: { $0.isWhitespace })
        let digits = trimmed.prefix(while: { $0.isNumber })
        return digits.isEmpty ? nil : String(digits)
    }

    /// The text with its trailing run of digits replaced, the prefix before them included.
    static func replacing(_ text: String, trailingDigitsWith replacement: String) -> String {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = trailingDigitsWithPrefixPattern.firstMatch(in: text, options: [], range: range),
            let matchRange = Range(match.range, in: text)
        else { return text }
        return String(text[..<matchRange.lowerBound]) + replacement
    }

    /// The text with its leading run of digits taken off.
    static func replacing(_ text: String, leadingDigitsWith replacement: String) -> String {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = leadingDigitsPattern.firstMatch(in: text, options: [], range: range),
            let matchRange = Range(match.range, in: text)
        else { return text }
        return replacement + String(text[matchRange.upperBound...])
    }

    // MARK: - Patterns

    /// A key the call writes in full: two to six letters, a hyphen, three to six digits.
    private static let keyPattern = try! NSRegularExpression(
        pattern: "\\b[A-Za-z]{2,6}-(\\d{3,6})\\b"
    )

    /// Two runs of digits separated by a space, not touching a key or another number.
    private static let splitNumberPattern = try! NSRegularExpression(
        pattern: "(?<![\\dA-Za-z-])(\\d{2,6})[ \\t]+(\\d{1,6})(?![\\d])"
    )

    /// A number standing on its own, not part of a key.
    private static let bareNumberPattern = try! NSRegularExpression(
        pattern: "(?<![\\dA-Za-z-])(\\d{3,5})(?![\\d])"
    )

    private static let trailingDigitsPattern = try! NSRegularExpression(pattern: "(\\d+)$")

    private static let trailingDigitsWithPrefixPattern = try! NSRegularExpression(
        pattern: "([A-Za-z]{2,6}-)?(\\d+)$"
    )

    private static let leadingDigitsPattern = try! NSRegularExpression(pattern: "^[ \\t]*(\\d+)")

    private static let ticketWordPattern = try! NSRegularExpression(
        pattern: "(?i)(?:ticket|issue|jira|тикет|задач|заявк)"
    )
}
