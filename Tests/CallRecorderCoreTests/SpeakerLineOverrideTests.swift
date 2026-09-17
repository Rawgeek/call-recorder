import Foundation
import Testing
@testable import CallRecorderApp
@testable import CallRecorderCore

/// Moving the lines of one excerpt onto the person who actually said them.
///
/// Speaker detection returns whole voices, and a real call defeats it: two people sharing a
/// headset arrive as one voice, and one voice arrives as a mix of the people in the room. The
/// review window can only offer one name per voice, so before this the mixed voice had no way to
/// be made right. These check what a correction covers, what it leaves alone, and that it survives
/// the voice being named afterwards.
@Suite("Speaker line corrections")
struct SpeakerLineOverrideTests {
    private let call = CallID(rawValue: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!)
    private let adam = ParticipantID(rawValue: UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000001")!)
    private let simon = ParticipantID(rawValue: UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!)

    private func override(
        _ startMs: Int,
        _ endMs: Int,
        _ participantID: ParticipantID = ParticipantID(rawValue: UUID()),
        name: String = "Adam"
    ) -> SpeakerLineOverride {
        SpeakerLineOverride(
            callID: call,
            startMs: startMs,
            endMs: endMs,
            participantID: participantID,
            speakerName: name
        )
    }

    private func segment(
        _ startMs: Int,
        _ endMs: Int,
        speakerIndex: Int = 6,
        name: String? = nil
    ) -> TranscriptSegment {
        TranscriptSegment(
            startMs: startMs,
            endMs: endMs,
            text: "line at \(startMs)",
            speakerIndex: speakerIndex,
            source: .system,
            participantID: nil,
            speakerName: name
        )
    }

    @Test("the lines inside the assigned excerpt take the person's name")
    func coveredLinesAreRenamed() {
        let moved = CallStore.applying(
            overrides: [override(16_000, 30_000, adam)],
            to: [segment(1_000, 5_000), segment(16_500, 18_000), segment(20_000, 29_500)]
        )
        #expect(moved[0].speakerName == nil)
        #expect(moved[1].speakerName == "Adam")
        #expect(moved[2].speakerName == "Adam")
        #expect(moved[1].participantID == adam)
    }

    @Test("a line that only touches the edge of the excerpt is left alone")
    func touchingLinesAreNotCovered() {
        // The end of the previous turn and the start of the next one both meet the excerpt's ends.
        // Taking either would move words the user did not assign, which is worse than the mix the
        // correction exists to fix.
        let moved = CallStore.applying(
            overrides: [override(16_000, 30_000, adam)],
            to: [segment(15_000, 16_000), segment(16_000, 30_000), segment(30_000, 31_000)]
        )
        #expect(moved[0].speakerName == nil)
        #expect(moved[2].speakerName == nil)
        #expect(moved[1].speakerName == "Adam")
    }

    @Test("what the user said into their own microphone is never moved")
    func localAudioKeepsTheUser() {
        // The microphone track is the person at this Mac, who is known without any detection. A
        // correction that renamed it would put someone else's name on the user's own words.
        let own = TranscriptSegment(
            startMs: 16_500,
            endMs: 18_000,
            text: "mine",
            speakerIndex: 6,
            source: .microphone,
            participantID: nil,
            speakerName: "Sam"
        )
        let moved = CallStore.applying(
            overrides: [override(16_000, 30_000, adam)],
            to: [own]
        )
        #expect(moved[0].speakerName == "Sam")
    }

    @Test("naming the voice afterwards does not undo the correction")
    func namingTheVoiceKeepsTheCorrection() {
        // The order the app applies them in: the whole voice is named first, then the assigned
        // lines are written on top. A mixed voice named as the person it mostly is would otherwise
        // rename every line the user had already assigned, at the next launch and every one after.
        let named = [segment(1_000, 5_000, name: "Simon"), segment(16_500, 18_000, name: "Simon")]
        let settled = CallStore.applying(overrides: [override(16_000, 30_000, adam)], to: named)
        #expect(settled[0].speakerName == "Simon")
        #expect(settled[1].speakerName == "Adam")
    }

    @Test("two corrections on one voice both land")
    func severalPeopleOnOneVoice() {
        // One voice, three people: the case that was reported. Each assignment covers its own run.
        let moved = CallStore.applying(
            overrides: [override(1_000, 5_000, simon, name: "Simon"), override(16_000, 30_000, adam)],
            to: [segment(1_000, 5_000), segment(9_000, 12_000), segment(16_500, 18_000)]
        )
        #expect(moved[0].speakerName == "Simon")
        #expect(moved[1].speakerName == nil)
        #expect(moved[2].speakerName == "Adam")
    }

    @Test("no corrections leaves every line as it was")
    func emptyLeavesLinesAlone() {
        let lines = [segment(1_000, 5_000, name: "Simon")]
        let same = CallStore.applying(overrides: [], to: lines)
        #expect(same == lines)
    }

    @Test("a card finds the correction for the excerpt it is showing")
    func excerptFindsItsOwnCorrection() {
        // An excerpt is the range the user assigned, so the two line up exactly. A correction that
        // merely overlaps belongs to a different run of lines, and offering it here would offer to
        // undo somebody else's answer from the wrong card.
        let excerpt = SpeakerReviewPlayback.Excerpt(text: "x", startMs: 16_000, endMs: 30_000)
        let mine = override(16_000, 30_000, adam)
        let other = override(30_000, 40_000, simon, name: "Simon")
        #expect(SpeakerReviewPlayback.override(for: excerpt, in: [other, mine])?.participantID == adam)
        #expect(SpeakerReviewPlayback.override(for: excerpt, in: [other]) == nil)
        #expect(SpeakerReviewPlayback.override(for: excerpt, in: []) == nil)
    }
}
