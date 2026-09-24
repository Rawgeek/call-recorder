import CallRecorderCore
import Foundation
import Testing

/// The picture a user names voices from.
///
/// The one thing these tests are for: the bars have to agree with the words. A bar that covers a
/// pause nobody spoke in, or a row that vanishes with a fragment, is a picture the user cannot
/// trust while they are deciding who is speaking.
struct SpeakerTimelineTests {
    private func turn(_ startMs: Int, _ endMs: Int, voice: Int?) -> TranscriptSegment {
        TranscriptSegment(
            startMs: startMs,
            endMs: endMs,
            text: "turn at \(startMs)",
            speakerIndex: voice,
            source: .system
        )
    }

    private func review(voice: Int) -> SpeakerReviewItem {
        SpeakerReviewItem(
            clusterID: SpeakerClusterID(rawValue: UUID()),
            callID: CallID(rawValue: UUID()),
            speakerIndex: voice,
            speakerLabel: "SPEAKER_\(voice)",
            speechDurationMilliseconds: 10_000,
            suggestedParticipantID: nil,
            state: .unknown,
            createdAt: Date()
        )
    }

    @Test("turns far apart are two bars")
    func turnsApartAreTwoBars() {
        let timeline = SpeakerTimeline.build(segments: [
            turn(1_000, 2_000, voice: 0),
            turn(6_000, 7_000, voice: 0),
        ])

        #expect(timeline.lanes.count == 1)
        #expect(
            timeline.lanes[0].runs
                == [
                    SpeakerTimeline.Run(startMs: 1_000, endMs: 2_000),
                    SpeakerTimeline.Run(startMs: 6_000, endMs: 7_000),
                ]
        )
        #expect(timeline.lanes[0].speakingMilliseconds == 2_000)
    }

    @Test("a short pause inside a turn is a pause, not an end")
    func aShortPauseJoinsOneTurn() {
        let timeline = SpeakerTimeline.build(segments: [
            turn(1_000, 2_000, voice: 0),
            turn(2_200, 3_000, voice: 0),
        ])

        #expect(timeline.lanes[0].runs.count == 1)
        #expect(timeline.lanes[0].runs[0].startMs == 1_000)
        #expect(timeline.lanes[0].runs[0].endMs == 3_000)
    }

    @Test("a pause another voice speaks in ends the turn")
    func anotherVoiceInThePauseEndsTheTurn() {
        // The same 200 ms pause as the test above, with one word from somebody else inside it.
        let timeline = SpeakerTimeline.build(segments: [
            turn(1_000, 2_000, voice: 0),
            turn(2_100, 2_150, voice: 1),
            turn(2_200, 3_000, voice: 0),
        ])

        #expect(timeline.lane(for: 0)?.runs.count == 2)
        // The interruption is 50 ms, which is not speech, so the second voice keeps its longest
        // fragment and stays on the picture rather than disappearing from it.
        #expect(timeline.lane(for: 1)?.runs.count == 1)
    }

    @Test("a fragment too short to be speech is dropped")
    func aFragmentIsDropped() {
        let timeline = SpeakerTimeline.build(segments: [
            turn(1_000, 1_100, voice: 0),
            turn(5_000, 6_000, voice: 0),
        ])

        #expect(timeline.lanes[0].runs.count == 1)
        #expect(timeline.lanes[0].runs[0].startMs == 5_000)
    }

    @Test("a voice heard only in fragments keeps its longest")
    func aVoiceOfFragmentsKeepsItsLongest() {
        let timeline = SpeakerTimeline.build(segments: [
            turn(1_000, 1_080, voice: 0),
            turn(2_000, 2_100, voice: 0),
            turn(9_000, 9_140, voice: 0),
        ])

        let runs = timeline.lane(for: 0)?.runs ?? []
        #expect(runs.count == 1)
        #expect(runs[0].startMs == 9_000)
        #expect(runs[0].endMs == 9_140)
    }

    @Test("rows are ordered by the voice that spoke first")
    func rowsAreOrderedByFirstArrival() {
        let timeline = SpeakerTimeline.build(segments: [
            turn(5_000, 6_000, voice: 1),
            turn(1_000, 2_000, voice: 4),
            turn(9_000, 9_500, voice: 1),
        ])

        #expect(timeline.lanes.map(\.speakerIndex) == [4, 1])
    }

    @Test("the picture covers the recording, not only the last word")
    func thePictureCoversTheRecording() {
        let segments = [turn(1_000, 2_000, voice: 0)]

        #expect(SpeakerTimeline.build(segments: segments).durationMs == 2_000)
        #expect(SpeakerTimeline.build(segments: segments, durationMs: 300_000).durationMs == 300_000)
        // A recording shorter than its own last turn is the turn's length: the bars have to fit.
        #expect(SpeakerTimeline.build(segments: segments, durationMs: 500).durationMs == 2_000)
    }

    @Test("the user's own microphone track is not one of the voices")
    func theMicrophoneTrackIsNotAVoice() {
        let timeline = SpeakerTimeline.build(segments: [
            turn(1_000, 2_000, voice: nil),
            turn(3_000, 4_000, voice: nil),
        ])

        #expect(timeline.isEmpty)
        #expect(timeline.durationMs == 0)
    }

    @Test("a row carries the voice that is waiting to be named")
    func aRowCarriesTheWaitingVoice() {
        let waiting = review(voice: 2)
        let timeline = SpeakerTimeline.build(
            segments: [turn(1_000, 2_000, voice: 2), turn(3_000, 4_000, voice: 5)],
            reviews: [waiting]
        )

        #expect(timeline.lane(for: 2)?.clusterID == waiting.clusterID)
        #expect(timeline.lane(for: 5)?.clusterID == nil)
        #expect(timeline.lane(for: waiting.clusterID)?.speakerIndex == 2)
    }

    @Test("a turn is found by the millisecond it covers")
    func aTurnIsFoundByItsMilliseconds() {
        let timeline = SpeakerTimeline.build(segments: [turn(1_000, 2_000, voice: 0)])

        let lane = timeline.lane(for: 0)
        #expect(lane?.holds(1_000) == true)
        #expect(lane?.holds(1_999) == true)
        #expect(lane?.holds(2_000) == false)
        #expect(lane?.holds(999) == false)
    }

    @Test("a row is labelled with the person a named voice belongs to")
    func aRowIsLabelledWithItsPerson() {
        let named = TranscriptSegment(
            startMs: 1_000,
            endMs: 2_000,
            text: "we can ship on Friday",
            speakerIndex: 3,
            source: .system,
            speakerName: "Dana Holt"
        )
        let timeline = SpeakerTimeline.build(segments: [
            named,
            turn(3_000, 4_000, voice: 4),
        ])

        #expect(timeline.lane(for: 3)?.label == "Dana Holt")
        // The other voice has no name yet, and a row that cannot be read is not a row.
        #expect(timeline.lane(for: 4)?.label == "Speaker 4")
    }
}
