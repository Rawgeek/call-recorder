import CallRecorderCore
import Foundation
import Testing

@Suite("How many voices to ask the detector for")
struct DiarizationSpeakerCountTests {
    private func makePeople(_ count: Int) -> [ParticipantID] {
        (0..<count).map { _ in ParticipantID(rawValue: UUID()) }
    }

    @Test("a standup asks for the people on the call, less the one recording")
    func countsTheRemotePeople() {
        let people = makePeople(15)

        let expected = DiarizationSpeakerCount.expected(
            participants: people,
            localParticipant: people[0],
            recordingSeconds: 2_065,
            usesParticipantCount: true
        )

        #expect(expected == 14)
    }

    @Test("a three-person call asks for the one person on the other side")
    func countsTheOtherSide() {
        let people = makePeople(3)

        #expect(
            DiarizationSpeakerCount.expected(
                participants: people,
                localParticipant: people[2],
                recordingSeconds: 877,
                usesParticipantCount: true
            ) == 2
        )
    }

    @Test("a call too short for that many voices is left to the detector")
    func leavesShortCallsAlone() {
        // Fourteen remote voices need three and a half minutes of speech between them.
        let people = makePeople(15)

        #expect(
            DiarizationSpeakerCount.expected(
                participants: people,
                localParticipant: people[0],
                recordingSeconds: 60,
                usesParticipantCount: true
            ) == nil
        )
    }

    @Test("the floor is measured against the voices, not against the call")
    func floorScalesWithTheCount() {
        let people = makePeople(5)
        let needed = 4 * DiarizationSpeakerCount.secondsPerExpectedVoice

        #expect(
            DiarizationSpeakerCount.expected(
                participants: people,
                localParticipant: people[0],
                recordingSeconds: needed,
                usesParticipantCount: true
            ) == 4
        )
        #expect(
            DiarizationSpeakerCount.expected(
                participants: people,
                localParticipant: people[0],
                recordingSeconds: needed - 1,
                usesParticipantCount: true
            ) == nil
        )
    }

    @Test("the setting turns the count off")
    func settingTurnsItOff() {
        let people = makePeople(15)

        #expect(
            DiarizationSpeakerCount.expected(
                participants: people,
                localParticipant: people[0],
                recordingSeconds: 2_065,
                usesParticipantCount: false
            ) == nil
        )
    }

    @Test("a call with one other person is not worth separating")
    func oneVoiceIsNotWorthSeparating() {
        let people = makePeople(2)

        #expect(
            DiarizationSpeakerCount.expected(
                participants: people,
                localParticipant: people[0],
                recordingSeconds: 600,
                usesParticipantCount: true
            ) == nil
        )
    }

    @Test("a recorder who is not on the list is still counted with the people on it")
    func countsEveryListedPersonWhenNobodyIsMarked() {
        let people = makePeople(4)

        #expect(
            DiarizationSpeakerCount.expected(
                participants: people,
                localParticipant: nil,
                recordingSeconds: 900,
                usesParticipantCount: true
            ) == 4
        )
    }
}
