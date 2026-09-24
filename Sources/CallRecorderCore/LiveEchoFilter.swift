import Foundation

/// Hides the microphone's copy of what the speakers played.
///
/// A call recorded without headphones puts the far end into the room, and the room is what the
/// microphone hears: every sentence arrives twice, once as `Others` from the system track and once
/// as `You` from the microphone a moment later. Amanu measured the size of this on a real call —
/// the far end at −3 dB on their own track for 35 minutes, loud enough to be attributed to the
/// wrong side — and shipped the filter this one is built from.
///
/// The rules are deliberately shy, because the cost of a mistake is not symmetric: a line wrongly
/// dropped is speech somebody said and cannot get back, while a line wrongly kept is a duplicate a
/// reader skips. So a line is only ever dropped when three things hold at once:
///
/// - it is long enough to be a sentence rather than a reply,
/// - the two sides said it at almost the same moment,
/// - and its words cover what the system track holds for that minute, closely enough to allow for
///   the recognition differences between two recordings of one voice.
public enum LiveEchoFilter {
    /// How far apart the two copies of one sentence may start.
    ///
    /// The echo is the room, and sound takes a moment to cross it; both tracks are also transcribed
    /// in chunks that do not split at the same instant. Four seconds holds those apart from the
    /// case this must never catch: somebody answering a sentence a few seconds after it was said.
    static let maximumStartDeltaSeconds = 4.0

    /// How much of the system side is compared against one microphone line.
    ///
    /// The same sentence can be split differently on the two sides — the microphone hears a pause
    /// the system track did not, or the other way round — so the played words are gathered from a
    /// minute around the match rather than from a single line. A minute is one long utterance, and
    /// short enough that the comparison does not grow with the length of the call.
    static let maximumCombinedStartDeltaSeconds = 60.0

    /// The fewest words a microphone line needs before it can be a copy of anything.
    ///
    /// Under this, a line is a reply: "yes, exactly", "right", "okay then". Those are the words a
    /// person says into their own microphone right after the far end stopped, which is exactly what
    /// a careless filter would delete.
    static let minimumWords = 5

    /// The fewest words a microphone line must share with one system line to anchor the match.
    static let minimumAnchorWords = 3

    /// The share of the microphone line that must appear in the system side.
    ///
    /// Measured by amanu on a ten-word echo that differed in one word: nine of ten is 0.90, and the
    /// sentence has to survive the two recognisers disagreeing about a name or a number.
    static let minimumCoverage = 0.90

    /// The lines to keep, given everything else that is on screen.
    ///
    /// - Parameters:
    ///   - candidates: the lines just added, which are the only ones ever judged.
    ///   - all: the conversation including the candidates, which is what they are compared with.
    /// - Returns: the candidates, less any that are the room hearing the speakers.
    public static func keepingSpeech(
        _ candidates: [LiveTranscriptEntry],
        against all: [LiveTranscriptEntry]
    ) -> [LiveTranscriptEntry] {
        let system = all.filter { $0.source == .system }
        guard !system.isEmpty else { return candidates }
        // A line already drawn is never taken back. The filter judges what has just arrived, so the
        // window cannot lose a sentence somebody is reading because a later chunk explained it.
        return candidates.filter { entry in
            entry.source == .microphone ? !isEcho(entry, of: system) : true
        }
    }

    static func isEcho(_ microphone: LiveTranscriptEntry, of system: [LiveTranscriptEntry]) -> Bool {
        let heard = words(microphone.text)
        guard heard.count >= minimumWords else { return false }
        let anchors = system.filter { line in
            guard abs(microphone.startSeconds - line.startSeconds) <= maximumStartDeltaSeconds else {
                return false
            }
            return longestCommonSubsequence(heard, words(line.text)) >= minimumAnchorWords
        }
        guard !anchors.isEmpty else { return false }
        let heardCharacters = Array(heard.joined())
        return anchors.contains { anchor in
            let played = system
                .filter {
                    abs($0.startSeconds - anchor.startSeconds) <= maximumCombinedStartDeltaSeconds
                }
                .flatMap { words($0.text) }
            guard !played.isEmpty else { return false }
            let wordCoverage = Double(longestCommonSubsequence(heard, played)) / Double(heard.count)
            let playedCharacters = Array(played.joined())
            let characterCoverage =
                Double(longestCommonSubsequence(heardCharacters, playedCharacters))
                / Double(heardCharacters.count)
            // Two measures because the two sides are two recordings of one voice: the same words can
            // come back spelled differently, and a name that is one word to one recogniser is two to
            // the other. Whichever measure is more generous is the one that counts.
            return max(wordCoverage, characterCoverage) >= minimumCoverage
        }
    }

    static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    static func longestCommonSubsequence<Element: Equatable>(_ lhs: [Element], _ rhs: [Element]) -> Int {
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        var previous = Array(repeating: 0, count: rhs.count + 1)
        for left in lhs {
            var current = Array(repeating: 0, count: rhs.count + 1)
            for (index, right) in rhs.enumerated() {
                current[index + 1] =
                    left == right
                    ? previous[index] + 1
                    : max(previous[index + 1], current[index])
            }
            previous = current
        }
        return previous[rhs.count]
    }
}
