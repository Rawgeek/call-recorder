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

    private func review(
        voice: Int,
        cluster: SpeakerClusterID,
        participantID: ParticipantID?,
        state: SpeakerMatchState
    ) -> SpeakerReviewItem {
        SpeakerReviewItem(
            clusterID: cluster,
            callID: CallID(rawValue: UUID()),
            speakerIndex: voice,
            speakerLabel: "SPEAKER_\(voice)",
            speechDurationMilliseconds: 10_000,
            suggestedParticipantID: participantID,
            state: state,
            createdAt: Date()
        )
    }

    @Test("every voice of a call has a row, and the row knows which voice it is")
    func everyVoiceHasARow() {
        let segments = (0...11).map { index in
            turn(index * 1_000, index * 1_000 + 800, voice: index)
        }
        let clusters: [SpeakerClusterID] = (0...11).map { _ in
            SpeakerClusterID(rawValue: UUID())
        }
        let reviews = (0...11).map { index in
            review(voice: index, cluster: clusters[index], participantID: nil, state: .unknown)
        }

        let timeline = SpeakerTimeline.build(segments: segments, reviews: reviews)

        // Twelve voices, twelve rows: the picture used to draw the first eight and leave the rest
        // off it, which is how Speaker 17 and Speaker 3 were missing from a call that held them.
        #expect(timeline.lanes.count == 12)
        let indices: [Int] = timeline.lanes.map(\.speakerIndex)
        #expect(indices == Array(0...11))
        // A row without a cluster behind it is a row nobody can act on.
        let clustersOnPicture: [SpeakerClusterID?] = timeline.lanes.map(\.clusterID)
        #expect(clustersOnPicture.compactMap { $0 }.count == 12)
        #expect(clustersOnPicture == clusters.map { cluster in Optional(cluster) })
    }

    @Test("a row for a voice that was already named keeps the cluster, so the name can change")
    func aNamedVoiceKeepsItsCluster() {
        let cluster = SpeakerClusterID(rawValue: UUID())
        let timeline = SpeakerTimeline.build(
            segments: [
                TranscriptSegment(
                    startMs: 1_000,
                    endMs: 2_000,
                    text: "Privet",
                    speakerIndex: 4,
                    source: .system,
                    speakerName: "Arcady"
                )
            ],
            reviews: [
                review(
                    voice: 4,
                    cluster: cluster,
                    participantID: ParticipantID(rawValue: UUID()),
                    state: .confirmed
                )
            ]
        )

        #expect(timeline.lanes.count == 1)
        #expect(timeline.lanes[0].label == "Arcady")
        #expect(timeline.lanes[0].clusterID == cluster)
    }

    @Test("a sample plays the voice's own turns and passes over the rest")
    func aSampleSkipsWhatIsNotTheVoice() {
        let lane = SpeakerTimeline.Lane(
            speakerIndex: 0,
            runs: [
                SpeakerTimeline.Run(startMs: 5_000, endMs: 8_000),
                SpeakerTimeline.Run(startMs: 20_000, endMs: 24_000),
            ]
        )
        let pass = SpeakerTimeline.ListeningPass(lane: lane, startMs: 2_000, endMs: 30_000)

        // Before the first turn: the pause is skipped, not listened to.
        #expect(pass.step(at: 2_000) == .jump(toMs: 5_000))
        // Inside a turn: it plays.
        #expect(pass.step(at: 6_000) == .playOn)
        // Between the turns: the minute in between belongs to whoever spoke in it.
        #expect(pass.step(at: 9_000) == .jump(toMs: 20_000))
        // Past the last turn: the sample ends rather than running on into the rest of the call.
        #expect(pass.step(at: 25_000) == .finished)
        // And its own end ends it too.
        #expect(pass.step(at: 30_000) == .finished)
    }

    @Test("a sample that ends inside a turn stops at its own end")
    func aSampleStopsAtItsEnd() {
        let lane = SpeakerTimeline.Lane(
            speakerIndex: 0,
            runs: [SpeakerTimeline.Run(startMs: 1_000, endMs: 90_000)]
        )
        // Twenty-five seconds of a minute and a half turn: the sample is the excerpt on the card,
        // not everything the voice said afterwards.
        let pass = SpeakerTimeline.ListeningPass(lane: lane, startMs: 1_000, endMs: 25_000)

        #expect(pass.step(at: 24_000) == .playOn)
        #expect(pass.step(at: 25_000) == .finished)
    }

    @Test("a sample with no turns to go by plays through")
    func aSampleWithoutRunsPlaysThrough() {
        let pass = SpeakerTimeline.ListeningPass(runs: [], startMs: 0, endMs: 5_000)

        #expect(pass.step(at: 1_000) == .playOn)
        #expect(pass.step(at: 5_000) == .finished)
    }

    @Test("clicking a voice that has no card puts its card at the top")
    func aClickedVoiceGetsItsCard() {
        let callID = CallID(rawValue: UUID())
        let waiting = item(callID: callID, voice: 3, state: .unknown)
        let clicked = item(callID: callID, voice: 12, state: .confirmed)

        // The cards the call shows are its waiting voices...
        let before = SpeakerReviewList.cards(waiting: [waiting], selected: nil, callID: callID)
        #expect(before.map(\.speakerIndex) == [3])
        // ...and the one that was clicked, in front of them, where the picture is.
        let after = SpeakerReviewList.cards(
            waiting: [waiting],
            selected: clicked,
            callID: callID
        )
        #expect(after.map(\.speakerIndex) == [12, 3])
        #expect(after.map(\.clusterID) == [clicked.clusterID, waiting.clusterID])
    }

    @Test("a clicked voice that is already waiting moves to the top, and is listed once")
    func aClickedWaitingVoiceMovesToTheTop() {
        let callID = CallID(rawValue: UUID())
        let first = item(callID: callID, voice: 3, state: .unknown)
        let clicked = item(callID: callID, voice: 7, state: .unknown)

        let cards = SpeakerReviewList.cards(
            waiting: [first, clicked],
            selected: clicked,
            callID: callID
        )

        // The voice that was clicked leads, and the card it already had is not drawn twice: the
        // voice the user asked for is the one under the picture they clicked on.
        #expect(cards.map(\.speakerIndex) == [7, 3])
        #expect(cards.map(\.clusterID) == [clicked.clusterID, first.clusterID])
    }

    @Test("a click that belongs to another call is not listed here")
    func aClickFromAnotherCallIsNotListed() {
        let callID = CallID(rawValue: UUID())
        let waiting = item(callID: callID, voice: 3, state: .unknown)
        let otherCall = item(callID: CallID(rawValue: UUID()), voice: 7, state: .confirmed)

        let cards = SpeakerReviewList.cards(
            waiting: [waiting],
            selected: otherCall,
            callID: callID
        )

        #expect(cards.map(\.clusterID) == [waiting.clusterID])
    }

    private func item(
        callID: CallID,
        voice: Int,
        state: SpeakerMatchState
    ) -> SpeakerReviewItem {
        SpeakerReviewItem(
            clusterID: SpeakerClusterID(rawValue: UUID()),
            callID: callID,
            speakerIndex: voice,
            speakerLabel: "SPEAKER_\(voice)",
            speechDurationMilliseconds: 10_000,
            suggestedParticipantID: state == .confirmed ? ParticipantID(rawValue: UUID()) : nil,
            state: state,
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
        // The other voice has no name yet, and a row that cannot be read is not a row. It is
        // numbered the way the transcript numbers it: the fifth voice of the call is Speaker 5.
        #expect(timeline.lane(for: 4)?.label == "Speaker 5")
    }

    @Test("a voice is numbered the way the transcript numbers it, not the way its label reads")
    func aVoiceIsNumberedLikeTheTranscript() {
        // The separation names its own clusters and renumbers them by when each voice first spoke,
        // so the twelfth voice of a call can carry the label SPEAKER_13. The stored label is not
        // what the transcript writes and not what the picture draws: a card opened from a row said
        // "Speaker 13" over a row that said "Speaker 11" on 2026-09-24.
        let review = SpeakerReviewItem(
            clusterID: SpeakerClusterID(rawValue: UUID()),
            callID: CallID(rawValue: UUID()),
            speakerIndex: 11,
            speakerLabel: "SPEAKER_13",
            speechDurationMilliseconds: 23_660,
            suggestedParticipantID: nil,
            state: .unknown,
            createdAt: Date()
        )
        let timeline = SpeakerTimeline.build(
            segments: [turn(1_000, 2_000, voice: 11)],
            reviews: [review]
        )

        #expect(SpeakerVoiceName.numbered(11) == "Speaker 12")
        #expect(timeline.lane(for: 11)?.label == "Speaker 12")
    }

    @Test("a voice waiting to be named is drawn by its number, not by a name off its own lines")
    func aWaitingVoiceIsNotDrawnWithAName() {
        // On 2026-09-24 the row of the 21-minute voice of the 2026-09-23 14:16 call read
        // "Alexey Ponomaryov" while the card under it read "Speaker 1", and the row was the one on
        // screen when the user asked for that voice to be named after himself. Five of the voice's
        // lines had been moved onto Alexey Ponomaryov by hand, and the row had taken the name off
        // them: a line can be moved without the voice being named, so the lines cannot name a
        // voice the store still holds as a question.
        let cluster = SpeakerClusterID(rawValue: UUID())
        let timeline = SpeakerTimeline.build(
            segments: [
                turn(1_000, 2_000, voice: 6),
                TranscriptSegment(
                    startMs: 3_000,
                    endMs: 4_000,
                    text: "a line moved onto somebody else",
                    speakerIndex: 6,
                    source: .system,
                    speakerName: "Alexey Ponomaryov"
                ),
            ],
            reviews: [
                review(
                    voice: 6,
                    cluster: cluster,
                    participantID: ParticipantID(rawValue: UUID()),
                    state: .suggested
                )
            ]
        )

        // The seventh voice of the call is Speaker 7, and the card under the row says the same.
        #expect(timeline.lane(for: 6)?.label == "Speaker 7")
        // The row still knows which voice it is, so it can still be clicked and named.
        #expect(timeline.lane(for: 6)?.clusterID == cluster)
    }

    @Test("the microphone track is a row of its own, named after the person recording")
    func thePersonRecordingGetsARow() {
        // The picture drew the voices the separation found and dropped the microphone track, so the
        // user's own words had no row at all. On 2026-09-24 he read his own speech out of the
        // remote voice whose bars run under it and asked for that voice to be named after him. The
        // microphone track carries no voice number: it is the person recording, and it is the one
        // row that says which words of the call are theirs.
        let cluster = SpeakerClusterID(rawValue: UUID())
        let timeline = SpeakerTimeline.build(
            segments: [
                TranscriptSegment(
                    startMs: 1_000,
                    endMs: 9_000,
                    text: "my own words",
                    speakerIndex: nil,
                    source: .microphone,
                    participantID: ParticipantID(rawValue: UUID()),
                    speakerName: "Stas"
                ),
                turn(2_000, 4_000, voice: 0),
            ],
            reviews: [
                review(voice: 0, cluster: cluster, participantID: nil, state: .unknown)
            ]
        )

        let local = timeline.lane(for: SpeakerTimeline.localSpeakerIndex)
        #expect(local?.label == "Stas")
        #expect(local?.runs == [
            SpeakerTimeline.Run(startMs: 1_000, endMs: 9_000)
        ])
        // Naming it is not a question: the person recording is the one person the app knows.
        #expect(local?.clusterID == nil)
        #expect(timeline.lanes.count == 2)
        // A line with neither a voice number nor a name is not a voice, and still gets no row.
        #expect(
            SpeakerTimeline.build(segments: [
                TranscriptSegment(
                    startMs: 0,
                    endMs: 1_000,
                    text: "nobody",
                    speakerIndex: nil,
                    source: .microphone
                )
            ]).lanes.isEmpty
        )
    }

    @Test("a line moved by hand does not make its voice count as named")
    func aMovedLineDoesNotNameItsVoice() {
        // The header of the 2026-09-23 14:16 call read "11 of 11 named" while the button beside it
        // read "1 to name". Five of the waiting voice's lines had been moved onto a person by hand,
        // and the count read the name off the lines: the store is the record of what was named, and
        // a voice it still holds as a question is one the user has not answered yet.
        let segments = [
            TranscriptSegment(
                startMs: 1_000,
                endMs: 2_000,
                text: "a line moved onto somebody else",
                speakerIndex: 0,
                source: .system,
                speakerName: "Alexey Ponomaryov"
            ),
            TranscriptSegment(
                startMs: 3_000,
                endMs: 4_000,
                text: "a voice that was really named",
                speakerIndex: 1,
                source: .system,
                speakerName: "Arcady"
            ),
            TranscriptSegment(
                startMs: 5_000,
                endMs: 6_000,
                text: "my own words",
                speakerIndex: nil,
                source: .microphone,
                speakerName: "Stas"
            ),
        ]

        let counts = SpeakerVoiceCount.counting(segments, waiting: [0])

        // The waiting voice and the two named ones, and the person recording counts as named.
        #expect(counts.total == 3)
        #expect(counts.named == 2)
        // A call with no voice waiting reads the transcript the way it did before.
        #expect(SpeakerVoiceCount.counting(segments).named == 3)
    }

    @Test("the window loads samples for every voice it draws, not only the waiting ones")
    func theWindowIsReadyForEveryVoiceItDraws() {
        let callID = CallID(rawValue: UUID())
        let waiting = item(callID: callID, voice: 3, state: .unknown)
        let named = item(callID: callID, voice: 12, state: .automatic)
        let everyVoice = [waiting, named]

        // A named voice has no card until it is clicked, and the card it gets reads its samples out
        // of the evidence loaded for it: a window that loaded only the waiting voices drew "Loading
        // samples…" under a clicked name and never loaded it.
        #expect(
            SpeakerReviewList.windowVoices(waiting: [waiting], everyVoice: everyVoice)
                .map(\.clusterID) == [waiting.clusterID, named.clusterID]
        )
        // A store that cannot be read leaves the waiting voices as the voices to draw.
        #expect(
            SpeakerReviewList.windowVoices(waiting: [waiting], everyVoice: nil)
                .map(\.clusterID) == [waiting.clusterID]
        )
        #expect(
            SpeakerReviewList.windowVoices(waiting: [waiting], everyVoice: [])
                .map(\.clusterID) == [waiting.clusterID]
        )
    }
}
