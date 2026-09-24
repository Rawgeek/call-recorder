import Foundation

/// One word, and the time a recogniser said it.
public struct RecognizedWord: Equatable, Sendable {
    public let text: String
    public let startMs: Int
    public let endMs: Int

    public init(text: String, startMs: Int, endMs: Int) {
        self.text = text
        self.startMs = startMs
        self.endMs = endMs
    }
}

/// Turns a recogniser's timed words into the turns a transcript is written in.
///
/// Parakeet answers with one stream of words and the time each was said. A transcript is made of
/// turns, because a turn is what a voice is named against: the separation says who spoke between two
/// times, and a segment holding one person's sentence can be given to that person whole. The rules
/// below are the ones whisper.cpp's own segments already follow in practice: a pause ends a turn, a
/// sentence ends a turn when a breath follows it, and a turn that never pauses is cut at a word.
public enum ParakeetSegments {
    /// A silence this long between two words ends the turn.
    public static let pauseMilliseconds = 800
    /// A sentence ends the turn when at least this much silence follows it.
    public static let sentencePauseMilliseconds = 150
    /// No turn is longer than this, however little the speaker pauses.
    public static let maximumMilliseconds = 12_000

    public static func build(words: [RecognizedWord]) -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []
        var current: [RecognizedWord] = []

        func close() {
            defer { current = [] }
            guard let first = current.first, let last = current.last else { return }
            let text = current
                .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            guard !text.isEmpty else { return }
            let start = max(0, first.startMs)
            segments.append(
                TranscriptSegment(startMs: start, endMs: max(start, last.endMs), text: text)
            )
        }

        for word in words {
            guard !word.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            if let previous = current.last, let opening = current.first {
                let gap = word.startMs - max(previous.startMs, previous.endMs)
                if gap > pauseMilliseconds {
                    close()
                } else if endsASentence(previous.text), gap >= sentencePauseMilliseconds {
                    close()
                } else if word.endMs - opening.startMs > maximumMilliseconds {
                    close()
                }
            }
            current.append(word)
        }
        close()
        return segments
    }

    /// Whether a word ends a sentence, by the punctuation that follows it.
    public static func endsASentence(_ word: String) -> Bool {
        let punctuation = CharacterSet(charactersIn: ".!?…")
        guard
            let last = word.trimmingCharacters(in: .whitespacesAndNewlines).last,
            let scalar = last.unicodeScalars.last
        else { return false }
        return punctuation.contains(scalar)
    }
}
