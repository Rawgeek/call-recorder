import Foundation

/// The number of voices to ask the count-aware detector for, and when to let it decide.
///
/// A detector that counts voices on its own counts one too many on the calls this app records: a
/// thirty-four minute standup with fourteen remote voices came back as sixteen, and the two extra
/// voices had to be named with a name the transcript already used somewhere else. The count is a
/// fact the app holds — the people on the call, less the person recording — and the detector that
/// takes a count answers exactly that number when it is given one. Measured on the same recording:
/// fourteen voices in eighty-six seconds, against sixteen in a hundred and forty-four.
///
/// The count is only as good as the list it comes from, and the two mistakes are not equal. A count
/// that is too high splits one person into two voices, which Review Speakers shows plainly and one
/// click fixes. A count that is too low writes two people into one voice, which leaves the
/// transcript wrong. The rule therefore asks for the count only when the recording held enough
/// speech for that many people to have spoken at all. The count has been the exception since the
/// detector switch: the separation counts the voices it hears unless the setting asks for the
/// count-aware detector, and the count is what that detector is asked for.
public enum DiarizationSpeakerCount {
    /// How much recorded speech each expected voice must have room for.
    ///
    /// Fourteen voices in a two-minute call is a list naming people who never spoke. Fifteen seconds
    /// a voice keeps the count off short calls and off calls that only a few people joined.
    public static let secondsPerExpectedVoice: Double = 15

    /// The fewest remote voices worth separating.
    public static let minimumVoices = 2

    /// The count to give the detector, or nil to let the detector decide.
    ///
    /// - Parameters:
    ///   - participants: The people on the call, as the app has them.
    ///   - localParticipant: The person recording, when the app knows which one that is.
    ///   - recordingSeconds: How long the recording runs.
    ///   - usesParticipantCount: Whether the setting that allows the count is on.
    public static func expected(
        participants: [ParticipantID],
        localParticipant: ParticipantID?,
        recordingSeconds: Double,
        usesParticipantCount: Bool
    ) -> Int? {
        guard usesParticipantCount else { return nil }
        let remote = participants.filter { $0 != localParticipant }
        guard remote.count >= minimumVoices else { return nil }
        guard recordingSeconds >= Double(remote.count) * secondsPerExpectedVoice else { return nil }
        return remote.count
    }
}
