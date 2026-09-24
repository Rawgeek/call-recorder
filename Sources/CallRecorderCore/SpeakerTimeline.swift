import Foundation

/// When each voice spoke, in the one shape a timeline can draw.
///
/// The transcript holds every turn and every word; a timeline needs the opposite of that, and this
/// is it: one row per voice, the times it spoke, and nothing else. Naming a voice is a listening
/// task, and the picture is what tells the user which part of the recording to listen to and where
/// the voice they cannot place is.
///
/// The rows obey the two rules the separation itself applies to a voice, so the picture agrees with
/// the words beside it: a turn shorter than a quarter of a second is not speech, and a pause of a
/// third of a second inside a turn is a pause. The numbers are the ones diarize.py writes with,
/// which joins the same way before this reads what it wrote.
public struct SpeakerTimeline: Equatable, Sendable {
    /// One stretch of speech that belongs to one voice without interruption.
    public struct Run: Equatable, Sendable, Identifiable {
        public let startMs: Int
        public let endMs: Int

        public init(startMs: Int, endMs: Int) {
            self.startMs = startMs
            self.endMs = endMs
        }

        /// Runs are read in order and a voice cannot speak twice at the same millisecond, so the
        /// start is an identity here.
        public var id: Int { startMs }

        public var durationMs: Int { max(0, endMs - startMs) }

        public func holds(_ milliseconds: Int) -> Bool {
            startMs <= milliseconds && milliseconds < endMs
        }
    }

    /// One voice, and the runs it is heard on.
    public struct Lane: Equatable, Sendable, Identifiable {
        public let speakerIndex: Int
        /// The person this voice was named as, when the call has been through naming.
        public let name: String?
        /// The voice waiting to be named, when this row is one of them.
        public let clusterID: SpeakerClusterID?
        public let runs: [Run]

        public init(
            speakerIndex: Int,
            name: String? = nil,
            clusterID: SpeakerClusterID? = nil,
            runs: [Run]
        ) {
            self.speakerIndex = speakerIndex
            self.name = name
            self.clusterID = clusterID
            self.runs = runs
        }

        public var id: Int { speakerIndex }

        public var firstStartMs: Int { runs.first?.startMs ?? 0 }
        public var lastEndMs: Int { runs.last?.endMs ?? 0 }
        public var speakingMilliseconds: Int { runs.reduce(0) { $0 + $1.durationMs } }

        /// What to call this voice on screen: the person, when it was named, and its number
        /// otherwise. The number is the one the transcript carries, which is also the one the
        /// card for this voice shows.
        public var label: String {
            guard let name, !name.isEmpty else { return SpeakerVoiceName.numbered(speakerIndex) }
            return name
        }

        public func holds(_ milliseconds: Int) -> Bool {
            runs.contains { $0.holds(milliseconds) }
        }
    }

    public let lanes: [Lane]
    /// The length the picture covers: the last run, or the recording when that is longer.
    public let durationMs: Int

    /// The row the person recording gets.
    ///
    /// The microphone track carries no voice number of its own: it is not one of the voices the
    /// separation found, it is the person doing the recording.
    public static let localSpeakerIndex = -1

    public var isEmpty: Bool { lanes.isEmpty }

    /// Below this a turn is not speech. The same number the separation writes with.
    public static let minimumRunMilliseconds = 250
    /// A pause this short inside one voice's turn is a breath, not the end of the turn.
    public static let joinGapMilliseconds = 300

    public init(lanes: [Lane], durationMs: Int) {
        self.lanes = lanes
        self.durationMs = max(0, durationMs)
    }

    public func lane(for speakerIndex: Int) -> Lane? {
        lanes.first { $0.speakerIndex == speakerIndex }
    }

    public func lane(for clusterID: SpeakerClusterID) -> Lane? {
        lanes.first { $0.clusterID == clusterID }
    }

    /// Builds the rows from a transcript, in the order the voices were first heard.
    ///
    /// - Parameters:
    ///   - reviews: The voices of this call, so a row can say which one it belongs to and whether
    ///     the store holds a name for it. A call whose reviews have expired has none, and the rows
    ///     are read from the transcript alone.
    ///   - durationMs: The length of the recording, when it is known. It is the floor of the
    ///     picture: a call whose last words are at four minutes is drawn on the five minutes the
    ///     file holds.
    public static func build(
        segments: [TranscriptSegment],
        reviews: [SpeakerReviewItem] = [],
        durationMs: Int = 0
    ) -> SpeakerTimeline {
        // A voice the store still holds as a question has no name, whatever its lines say. Moving
        // one line of a voice onto a person is not naming the voice, and reading the name off the
        // lines drew "Alexey Ponomaryov" over the row of a voice the card under it called
        // "Speaker 1" on 2026-09-24, from the five lines of that voice that had been moved by hand.
        var unnamedIndexes: Set<Int> = []
        for review in reviews where review.state == .suggested || review.state == .unknown {
            unnamedIndexes.insert(review.speakerIndex)
        }
        var turnsByVoice: [Int: [Run]] = [:]
        var namesByVoice: [Int: String] = [:]
        for segment in segments {
            guard segment.endMs > segment.startMs else { continue }
            // A turn with no voice number is not a detected voice, and a line with neither a number
            // nor a name is not a voice at all. The microphone track has no number and does have a
            // name: it is the person recording, and it is the row that says which words of the call
            // are theirs. It used to be dropped, and on 2026-09-24 the user read his own speech out
            // of the remote voice whose bars run under it and asked for that voice to be named
            // after him, because his own voice had no row to point at.
            let index: Int
            if let numbered = segment.speakerIndex {
                index = numbered
            } else if segment.speakerName != nil {
                index = localSpeakerIndex
            } else {
                continue
            }
            // The person recording is named by the name on their own track: no store keeps it, and
            // nobody is asked to name them.
            if let name = segment.speakerName, !name.isEmpty,
                index == localSpeakerIndex || !unnamedIndexes.contains(index)
            {
                namesByVoice[index] = name
            }
            turnsByVoice[index, default: []].append(
                Run(startMs: max(0, segment.startMs), endMs: segment.endMs)
            )
        }
        let clusters = Dictionary(
            reviews.map { ($0.speakerIndex, $0.clusterID) },
            uniquingKeysWith: { first, _ in first }
        )
        let lanes = turnsByVoice
            .map { index, turns in
                Lane(
                    speakerIndex: index,
                    name: namesByVoice[index],
                    clusterID: clusters[index],
                    runs: runs(from: turns, against: turnsByVoice, of: index)
                )
            }
            .sorted { ($0.firstStartMs, $0.speakerIndex) < ($1.firstStartMs, $1.speakerIndex) }
        let lastEnd = lanes.map(\.lastEndMs).max() ?? 0
        return SpeakerTimeline(lanes: lanes, durationMs: max(durationMs, lastEnd))
    }

    /// One voice's turns as the runs it is heard on.
    ///
    /// Sorting first is what makes the rest a single pass: turns arrive in transcript order, and a
    /// transcript merged from two tracks is not ordered by time.
    static func runs(from turns: [Run], against all: [Int: [Run]], of index: Int) -> [Run] {
        let sorted = turns.sorted { ($0.startMs, $0.endMs) < ($1.startMs, $1.endMs) }
        var joined: [Run] = []
        for turn in sorted {
            guard let last = joined.last else {
                joined.append(turn)
                continue
            }
            if turn.startMs <= last.endMs {
                joined[joined.count - 1] = Run(
                    startMs: last.startMs,
                    endMs: max(last.endMs, turn.endMs)
                )
            } else if turn.startMs - last.endMs <= joinGapMilliseconds,
                !interrupted(from: last.endMs, to: turn.startMs, by: all, except: index)
            {
                joined[joined.count - 1] = Run(startMs: last.startMs, endMs: turn.endMs)
            } else {
                joined.append(turn)
            }
        }
        let speech = joined.filter { $0.durationMs >= minimumRunMilliseconds }
        guard speech.isEmpty else { return speech }
        // Every turn this voice has is a fragment. The separation passes those by, and a row that
        // vanished with them would leave a voice in the transcript that the user cannot see,
        // place, or name, so the longest fragment stands for it.
        guard let longest = joined.max(by: { $0.durationMs < $1.durationMs }) else { return [] }
        return [longest]
    }

    /// Whether another voice speaks in a pause, which is what makes the pause a turn boundary.
    static func interrupted(
        from endMs: Int,
        to startMs: Int,
        by all: [Int: [Run]],
        except index: Int
    ) -> Bool {
        all.contains { other, turns in
            other != index
                && turns.contains { $0.startMs < startMs && $0.endMs > endMs }
        }
    }
}

extension SpeakerTimeline {
    /// Listening to one voice's own words, with everything that is not theirs passed over.
    ///
    /// A sample is a voice's turn, and the pause before its next turn belongs to nobody. On a call
    /// where a voice speaks at minute five and again at minute nine, playing the sample through
    /// means hearing four minutes of a conversation the sample is not about, so the playhead moves
    /// to the next turn instead. What is skipped is what the picture shows as a gap, because the
    /// runs here are the runs it draws.
    public struct ListeningPass: Equatable, Sendable {
        public let startMs: Int
        public let endMs: Int
        private let runs: [Run]

        public init(runs: [Run], startMs: Int, endMs: Int) {
            self.startMs = max(0, startMs)
            self.endMs = max(self.startMs, endMs)
            self.runs = runs
        }

        public init(lane: Lane, startMs: Int, endMs: Int) {
            self.init(runs: lane.runs, startMs: startMs, endMs: endMs)
        }

        /// What a player should do with the playhead at one moment of the sample.
        public enum Step: Equatable, Sendable {
            /// The voice is speaking here, or there is nothing to go by where it speaks.
            case playOn
            /// A pause before the voice's next turn: move there and play on.
            case jump(toMs: Int)
            /// Nothing of this voice is left in the sample, or its end was reached.
            case finished
        }

        /// What to do at one moment, as a rule with three answers rather than two.
        ///
        /// The end of the last turn inside the sample is a finish, not a jump: a sample of a voice
        /// that speaks at minute five and again at minute nine ends when its turn does, rather than
        /// running on into whatever the recording holds next.
        public func step(at positionMs: Int) -> Step {
            guard positionMs < endMs else { return .finished }
            // A voice the picture has no runs for, which is a call whose separation found nothing,
            // has nothing to skip: the sample plays through.
            guard !runs.isEmpty else { return .playOn }
            if runs.contains(where: { $0.holds(positionMs) }) { return .playOn }
            guard let next = runs.first(where: { $0.startMs > positionMs })?.startMs, next < endMs
            else { return .finished }
            return .jump(toMs: next)
        }
    }
}
