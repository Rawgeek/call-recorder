import Foundation

public struct SpeakerClusterID: Codable, Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}

public struct SpeakerCluster: Equatable, Sendable {
    public let id: SpeakerClusterID
    public let modelVersion: String
    public let embedding: [Float]
    public let speechDurationMilliseconds: Int

    public init(
        id: SpeakerClusterID,
        modelVersion: String,
        embedding: [Float],
        speechDurationMilliseconds: Int
    ) {
        self.id = id
        self.modelVersion = modelVersion
        self.embedding = embedding
        self.speechDurationMilliseconds = speechDurationMilliseconds
    }
}

public struct SpeakerProfile: Equatable, Sendable {
    public let participantID: ParticipantID
    public let modelVersion: String
    public let samples: [[Float]]

    public init(
        participantID: ParticipantID,
        modelVersion: String,
        samples: [[Float]]
    ) {
        self.participantID = participantID
        self.modelVersion = modelVersion
        self.samples = samples
    }
}

/// The cards one call shows: the voice the user just clicked, then the voices still waiting.
///
/// A voice named on an earlier pass has no card of its own, so a row on the picture that opened
/// nothing would be a control that does nothing. Clicking that row puts its card at the top, where
/// the picture is: the samples to listen to, the name to change, and the way back to review are one
/// click from the row that was clicked. A voice that already had a card moves up rather than being
/// listed twice: the click asks for that voice's samples and its picker under the picture, and a
/// voice that is already waiting has both, so leaving it where it was answers with nothing.
public enum SpeakerReviewList {
    public static func cards(
        waiting: [SpeakerReviewItem],
        selected: SpeakerReviewItem?,
        callID: CallID
    ) -> [SpeakerReviewItem] {
        guard let selected, selected.callID == callID else { return waiting }
        return [selected] + waiting.filter { $0.clusterID != selected.clusterID }
    }
}

/// The order a person is offered in when a voice has to be named.
///
/// Naming a remote voice means matching transcript samples against people, and the people who were
/// on that call are the candidates. A picker that lists everyone ever met, in name order, buries a
/// three-person answer in forty-seven and gives the user no way to tell which three matter. The
/// call's own people come first, and the rest stay reachable underneath for the case where the
/// voice belongs to someone who was not on the call at all.
public enum SpeakerReviewCandidates {
    public static func ordered(
        participants: [Participant],
        onCall: [Participant]
    ) -> [Participant] {
        let onCallIDs = Set(onCall.map(\.id))
        // Anyone on the call is offered once, in the call's own order, and removed from the tail
        // even if the two lists were built from different reads of the database.
        return onCall + participants.filter { !onCallIDs.contains($0.id) }
    }

    /// The same idea for the window that edits a finished call's participants.
    ///
    /// That window keeps the checked rows in place while it is open, so it leads with the people
    /// who were checked when it opened rather than with the live selection. A list that reordered
    /// as rows were clicked would move the next row out from under the pointer.
    public static func ordered(
        participants: [Participant],
        leading: Set<ParticipantID>
    ) -> [Participant] {
        guard !leading.isEmpty else { return participants }
        return participants.filter { leading.contains($0.id) }
            + participants.filter { !leading.contains($0.id) }
    }

    /// Whether this person was on the call, which is what the picker's note says.
    public static func wasOnCall(_ participant: Participant, onCall: [Participant]) -> Bool {
        onCall.contains { $0.id == participant.id }
    }

    /// The people a typed name could mean, best first.
    ///
    /// A library of a few hundred people cannot be read in a pop-up menu, so the picker is typed
    /// into instead. Filtering alone is not enough: what makes the first row the person a user
    /// meant is the order, so a name that starts with what was typed comes before one that merely
    /// contains it, and a word of a name counts as a start. Ties keep the order the caller chose,
    /// which is the people on the call first.
    public static func matching(_ participants: [Participant], query: String) -> [Participant] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return participants }
        let ranked = participants.enumerated().compactMap { index, participant in
            rank(participant, needle: needle).map { ($0, index, participant) }
        }
        return ranked
            .sorted { lhs, rhs in
                lhs.0 == rhs.0 ? lhs.1 < rhs.1 : lhs.0 < rhs.0
            }
            .map(\.2)
    }

    /// Whether the typed name is already somebody, which is what decides between choosing and
    /// adding.
    public static func exactMatch(_ participants: [Participant], query: String) -> Participant? {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return nil }
        return participants.first { $0.name.compare(needle, options: .participantSearch) == .orderedSame }
    }

    /// How well one person answers the search, or nil when they do not.
    private static func rank(_ participant: Participant, needle: String) -> Int? {
        let options: String.CompareOptions = .participantSearch
        if participant.name.range(of: needle, options: options)?.lowerBound
            == participant.name.startIndex
        {
            return 0
        }
        let words = participant.name.split(whereSeparator: { $0 == " " || $0 == "-" })
        if words.contains(where: { word in
            word.range(of: needle, options: options)?.lowerBound == word.startIndex
        }) {
            return 1
        }
        if participant.name.range(of: needle, options: options) != nil { return 2 }
        let otherFields = [participant.company, participant.email, participant.role]
            .compactMap { $0 }
        if otherFields.contains(where: { $0.range(of: needle, options: options) != nil }) {
            return 3
        }
        return nil
    }
}

extension String.CompareOptions {
    /// How a typed name is compared with a stored one: case does not matter, and neither does an
    /// accent, because nobody types the accent under time pressure.
    static let participantSearch: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
}

public struct PendingSpeakerCluster: Equatable, Sendable {
    public static let retentionSeconds: TimeInterval = 30 * 24 * 60 * 60

    public let callID: CallID
    public let speakerIndex: Int
    public let speakerLabel: String
    public let cluster: SpeakerCluster
    public let createdAt: Date

    public init(
        callID: CallID,
        speakerIndex: Int,
        speakerLabel: String,
        cluster: SpeakerCluster,
        createdAt: Date
    ) {
        self.callID = callID
        self.speakerIndex = speakerIndex
        self.speakerLabel = speakerLabel
        self.cluster = cluster
        self.createdAt = createdAt
    }

    public var expiresAt: Date {
        createdAt.addingTimeInterval(Self.retentionSeconds)
    }
}

public enum SpeakerMatchState: String, Codable, Equatable, Sendable {
    case automatic
    case suggested
    case unknown
    case confirmed
}

/// Where the voice-profile key is.
///
/// The key is a keychain item, and reading it can wait on a permission dialog that never expires.
/// An optional error could only say "not failed yet", which covered three different situations:
/// the read has not been tried, the read is parked on a dialog, and the read succeeded. The three
/// need different words on screen, because only the middle one is something the user can fix by
/// answering a dialog.
public enum VoiceIdentityState: Equatable, Sendable {
    /// The read has started and has not finished.
    case checking
    /// The read is taking longer than an ordinary keychain read ever does. macOS is almost
    /// certainly showing a permission dialog, which may be behind another window.
    case waitingForPermission
    /// The key was read and voice profiles are usable.
    case available
    /// The read failed. The reason is in the model's error string.
    case unavailable
}

/// What one run of the speaker repair did, in words a person can read.
///
/// The repair looks for calls where one name landed on several voices that do not sound alike,
/// which is what a transcription over-split leaves behind. It ran by itself at launch and said
/// nothing either way, so a call still showing one person on four voices looked identical whether
/// the repair had never run, had run and failed, or had run and decided those voices really are
/// that person. This is the answer to that question.
public struct SpeakerReconcileSummary: Equatable, Sendable {
    /// When the run finished.
    public let finishedAt: Date
    /// Calls where one person was named on more than one voice.
    public let callsExamined: Int
    /// Voices that were compared with the profile of the person named on them.
    public let voicesExamined: Int
    /// Voices returned to review because they did not sound like the person named on them.
    public let returnedToReview: Int
    /// The closest match to the person's own voice among the fragments that returned to review,
    /// for judging whether the threshold is set right.
    public let closestKeptSimilarity: Float?
    /// Set when the run could not complete, in place of the counts.
    public let failure: String?

    public init(
        finishedAt: Date,
        callsExamined: Int,
        voicesExamined: Int,
        returnedToReview: Int,
        closestKeptSimilarity: Float?,
        failure: String?
    ) {
        self.finishedAt = finishedAt
        self.callsExamined = callsExamined
        self.voicesExamined = voicesExamined
        self.returnedToReview = returnedToReview
        self.closestKeptSimilarity = closestKeptSimilarity
        self.failure = failure
    }

    public init(finishedAt: Date, report: SpeakerReconcileReport) {
        self.init(
            finishedAt: finishedAt,
            callsExamined: report.groups,
            voicesExamined: report.fragments,
            returnedToReview: report.reopened.count,
            closestKeptSimilarity: report.highestRejectedSimilarity,
            failure: nil
        )
    }

    public init(finishedAt: Date, failure: String) {
        self.init(
            finishedAt: finishedAt,
            callsExamined: 0,
            voicesExamined: 0,
            returnedToReview: 0,
            closestKeptSimilarity: nil,
            failure: failure
        )
    }
}

public struct SpeakerMatch: Equatable, Sendable {
    public let clusterID: SpeakerClusterID
    public let participantID: ParticipantID?
    public let state: SpeakerMatchState
    /// How close the fragment came to the person it was matched to.
    ///
    /// Recorded so a call can be explained after the fact: a fragment accepted at 0.83 and one
    /// accepted at 0.99 are the same row otherwise, and a reviewer asking why a voice was named the
    /// way it was has nothing to read. It decides nothing -- the policy made that decision already.
    /// Nil when there was no profile to compare against.
    public let similarity: Float?

    public init(
        clusterID: SpeakerClusterID,
        participantID: ParticipantID?,
        state: SpeakerMatchState,
        similarity: Float? = nil
    ) {
        self.clusterID = clusterID
        self.participantID = participantID
        self.state = state
        self.similarity = similarity
    }
}

public struct SpeakerReviewItem: Equatable, Identifiable, Sendable {
    public let clusterID: SpeakerClusterID
    public let callID: CallID
    public let speakerIndex: Int
    public let speakerLabel: String
    public let speechDurationMilliseconds: Int
    public let suggestedParticipantID: ParticipantID?
    public let state: SpeakerMatchState
    public let createdAt: Date

    public var id: SpeakerClusterID { clusterID }

    public init(
        clusterID: SpeakerClusterID,
        callID: CallID,
        speakerIndex: Int,
        speakerLabel: String,
        speechDurationMilliseconds: Int,
        suggestedParticipantID: ParticipantID?,
        state: SpeakerMatchState,
        createdAt: Date
    ) {
        self.clusterID = clusterID
        self.callID = callID
        self.speakerIndex = speakerIndex
        self.speakerLabel = speakerLabel
        self.speechDurationMilliseconds = speechDurationMilliseconds
        self.suggestedParticipantID = suggestedParticipantID
        self.state = state
        self.createdAt = createdAt
    }
}

/// How many voices a call's transcript holds, and how many of them carry a name.
///
/// The review window read this number off the list of voices still waiting to be named, which
/// answers a different question: a call separated into fourteen voices with one left to name drew
/// "Voices detected 1", and the field beside it offered to separate the call into one voice. The
/// transcript is the record of what was separated, so the count is read from it instead.
public struct SpeakerVoiceCount: Equatable, Sendable {
    public let named: Int
    public let total: Int

    public init(named: Int, total: Int) {
        self.named = named
        self.total = total
    }

    /// Counts the voices a transcript holds by the speaker number its segments carry.
    ///
    /// A segment with no number is not a detected voice: the renderer falls back to its own tag for
    /// those, and counting them would report a voice nobody separated. A named segment with no
    /// number is a voice all the same -- the local microphone track is one -- so it counts.
    public static func counting(_ segments: [TranscriptSegment]) -> SpeakerVoiceCount {
        var indexes = Set<Int>()
        var namedIndexes = Set<Int>()
        var namedWithoutIndex = Set<String>()
        for segment in segments {
            if let index = segment.speakerIndex {
                indexes.insert(index)
                if segment.speakerName != nil { namedIndexes.insert(index) }
            } else if let name = segment.speakerName {
                namedWithoutIndex.insert(name)
            }
        }
        return SpeakerVoiceCount(
            named: namedIndexes.count + namedWithoutIndex.count,
            total: indexes.count + namedWithoutIndex.count
        )
    }
}

public enum SpeakerReviewRequestAction: String, Equatable, Sendable {
    case confirm
    case keepUnknown
    /// Sends a decided speaker back to review so a wrong name can be corrected.
    case reopen
    /// Moves one run of a call's lines onto a person, whatever voice they were detected as.
    ///
    /// Queued rather than written directly for the same reason a confirmation is: the app owns the
    /// transcript, and a caller outside it has to go through the path that keeps a revision to
    /// roll back to.
    case assignLines
    /// Puts a moved run of lines back under the voice's own name.
    case releaseLines
}

public struct SpeakerReviewRequest: Equatable, Identifiable, Sendable {
    public let id: UUID
    /// The voice the request names, for the actions that name a voice.
    public let clusterID: SpeakerClusterID?
    /// The call the request names, for the actions that name a run of lines.
    public let callID: CallID?
    public let participantID: ParticipantID?
    public let action: SpeakerReviewRequestAction
    /// The lines the request is about, for the two actions that name a range rather than a voice.
    public let lineRange: ClosedRange<Int>?

    public init(
        id: UUID,
        clusterID: SpeakerClusterID? = nil,
        callID: CallID? = nil,
        participantID: ParticipantID?,
        action: SpeakerReviewRequestAction,
        lineRange: ClosedRange<Int>? = nil
    ) {
        self.id = id
        self.clusterID = clusterID
        self.callID = callID
        self.participantID = participantID
        self.action = action
        self.lineRange = lineRange
    }
}

/// One run of lines in a saved transcript that belongs to someone other than the voice that was
/// detected for them.
///
/// Speaker detection works on whole recordings and returns whole voices, and a real call defeats
/// it: two people sharing one headset come back as one voice, and one voice comes back as a mix of
/// the people who were in the room. The review window can only offer one name per detected voice,
/// so the mixed voice had no way to be made right. This records the correction for the lines
/// themselves: the voice keeps whatever name it is given, and these lines are written as the
/// person who actually said them.
///
/// The range is the excerpt the user assigned, and every detected line inside it is moved. It is
/// stored apart from the transcripts so a later repair of the whole library cannot quietly undo it.
public struct SpeakerLineOverride: Equatable, Sendable, Identifiable {
    public let callID: CallID
    public let startMs: Int
    public let endMs: Int
    public let participantID: ParticipantID
    public let speakerName: String

    public var id: String { "\(startMs)-\(endMs)" }

    public init(
        callID: CallID,
        startMs: Int,
        endMs: Int,
        participantID: ParticipantID,
        speakerName: String
    ) {
        self.callID = callID
        self.startMs = startMs
        self.endMs = endMs
        self.participantID = participantID
        self.speakerName = speakerName
    }

    /// Whether this correction covers a line of the transcript.
    ///
    /// A line is moved when it sits wholly inside the range that was assigned. An excerpt is built
    /// by joining the lines of one voice, so the lines it holds are exactly the ones inside it, and
    /// a line that only touches the edge of the range belongs to the turn before or after it.
    public func covers(startMs lineStart: Int, endMs lineEnd: Int) -> Bool {
        lineStart >= startMs && lineEnd <= endMs
    }
}

public struct VoiceProfileSummary: Equatable, Sendable {
    public let participantID: ParticipantID
    public let confirmedSampleCount: Int
    public let recoverableSampleCount: Int
    public let lastConfirmedAt: Date?

    public init(
        participantID: ParticipantID,
        confirmedSampleCount: Int,
        recoverableSampleCount: Int,
        lastConfirmedAt: Date?
    ) {
        self.participantID = participantID
        self.confirmedSampleCount = confirmedSampleCount
        self.recoverableSampleCount = recoverableSampleCount
        self.lastConfirmedAt = lastConfirmedAt
    }
}

public struct SpeakerMatchPolicy: Equatable, Sendable {
    public let acceptanceSimilarity: Float
    public let reviewSimilarity: Float
    public let acceptanceMargin: Float
    public let minimumSpeechMilliseconds: Int
    public let minimumConfirmedSamples: Int
    /// Two fragments of one recording may share a person only when the fragments themselves
    /// sound like one voice. Without this guard the closest profile claims every fragment it
    /// reviews, so one person is written onto several unrelated speakers.
    public let splitVoiceSimilarity: Float

    public init(
        acceptanceSimilarity: Float,
        reviewSimilarity: Float,
        acceptanceMargin: Float,
        minimumSpeechMilliseconds: Int,
        minimumConfirmedSamples: Int,
        splitVoiceSimilarity: Float = 0.75
    ) {
        self.acceptanceSimilarity = acceptanceSimilarity
        self.reviewSimilarity = reviewSimilarity
        self.acceptanceMargin = acceptanceMargin
        self.minimumSpeechMilliseconds = minimumSpeechMilliseconds
        self.minimumConfirmedSamples = minimumConfirmedSamples
        self.splitVoiceSimilarity = splitVoiceSimilarity
    }

    public static let `default` = SpeakerMatchPolicy(
        acceptanceSimilarity: 0.82,
        reviewSimilarity: 0.68,
        acceptanceMargin: 0.08,
        minimumSpeechMilliseconds: 8_000,
        minimumConfirmedSamples: 2
    )
}
