import Foundation
import Testing
@testable import CallRecorderCore

@Suite("Speaker matcher")
struct SpeakerMatcherTests {
    @Test("one learned person can match several fragments of the same voice")
    func recognizesSplitVoice() {
        let person = ParticipantID(rawValue: UUID())
        let matches = SpeakerMatcher.match(
            clusters: [cluster([1, 0]), cluster([0.99, 0.01])],
            profiles: [profile([1, 0], id: person)], policy: policy
        )
        #expect(matches.map(\.participantID) == [person, person])
        #expect(matches.allSatisfy { $0.state == .automatic })
    }

    @Test("one learned person keeps the closest fragment and asks for review on the rest")
    func refusesUnrelatedFragment() {
        let person = ParticipantID(rawValue: UUID())
        let matches = SpeakerMatcher.match(
            // The learned profile mixes two voices, so both voices sit close to the
            // average. Only one of them may take the name without review.
            clusters: [cluster([1, 0]), cluster([0.7, 0.71])],
            profiles: [
                profile(samples: [[1, 0], [0.6, 0.8]], id: person)
            ], policy: policy
        )

        #expect(matches[1].participantID == person)
        #expect(matches[1].state == .automatic)
        #expect(matches[0].participantID == person)
        #expect(matches[0].state == .suggested)
    }

    @Test("a second fragment of one voice still names the person")
    func keepsSecondFragmentOfOneVoice() {
        let person = ParticipantID(rawValue: UUID())
        let matches = SpeakerMatcher.match(
            clusters: [cluster([1, 0]), cluster([0.86, 0.51])],
            profiles: [profile([1, 0], id: person)], policy: policy
        )

        #expect(matches.allSatisfy { $0.participantID == person })
        #expect(matches.allSatisfy { $0.state == .automatic })
    }

    @Test("a fragment too far from every profile stays unknown")
    func keepsUnrelatedFragmentUnknown() {
        let matches = SpeakerMatcher.match(
            clusters: [cluster([1, 0]), cluster([0, 1])],
            profiles: [profile([1, 0])], policy: policy
        )

        #expect(matches[0].participantID != nil)
        #expect(matches[1].participantID == nil)
        #expect(matches[1].state == .unknown)
    }

    @Test("close best and second-best candidates require review")
    func rejectsBestCandidateWithoutMargin() {
        let matches = SpeakerMatcher.match(
            clusters: [cluster([1, 0])],
            profiles: [profile([0.81, 0.19]), profile([0.80, 0.20])],
            policy: policy
        )

        #expect(matches[0].state == .suggested)
        #expect(matches[0].participantID != nil)
    }

    @Test("global search can reject every profile")
    func searchesAllProfilesAndCanReturnUnknown() {
        let profiles = (0..<40).map { index in
            var vector = Array(repeating: Float.zero, count: 64)
            vector[index] = 1
            return profile(vector)
        }
        var unknown = Array(repeating: Float.zero, count: 64)
        unknown[63] = 1

        let matches = SpeakerMatcher.match(
            clusters: [cluster(unknown)],
            profiles: profiles,
            policy: policy
        )

        #expect(matches[0].state == .unknown)
        #expect(matches[0].participantID == nil)
    }

    @Test("distinct voices still match distinct people")
    func recognizesDistinctVoices() {
        let adi = ParticipantID(rawValue: UUID())
        let dana = ParticipantID(rawValue: UUID())
        let matches = SpeakerMatcher.match(
            clusters: [cluster([1, 0]), cluster([0, 1])],
            profiles: [profile([1, 0], id: adi), profile([0, 1], id: dana)],
            policy: policy
        )

        #expect(matches.allSatisfy { $0.state == .automatic })
        #expect(Set(matches.compactMap(\.participantID)) == Set([adi, dana]))
    }

    @Test("incompatible model versions are never compared")
    func isolatesModelVersions() {
        let matches = SpeakerMatcher.match(
            clusters: [cluster([1, 0], model: "model-v2")],
            profiles: [profile([1, 0], model: "model-v1")],
            policy: policy
        )

        #expect(matches[0].state == .unknown)
        #expect(matches[0].participantID == nil)
    }

    private var policy: SpeakerMatchPolicy {
        SpeakerMatchPolicy(
            acceptanceSimilarity: 0.80,
            reviewSimilarity: 0.65,
            acceptanceMargin: 0.08,
            minimumSpeechMilliseconds: 8_000,
            minimumConfirmedSamples: 1
        )
    }

    private func cluster(
        _ embedding: [Float],
        model: String = "model-v1"
    ) -> SpeakerCluster {
        SpeakerCluster(
            id: SpeakerClusterID(rawValue: UUID()),
            modelVersion: model,
            embedding: embedding,
            speechDurationMilliseconds: 10_000
        )
    }

    private func profile(
        _ embedding: [Float],
        id: ParticipantID = ParticipantID(rawValue: UUID()),
        model: String = "model-v1"
    ) -> SpeakerProfile {
        SpeakerProfile(participantID: id, modelVersion: model, samples: [embedding])
    }

    private func profile(
        samples: [[Float]],
        id: ParticipantID = ParticipantID(rawValue: UUID()),
        model: String = "model-v1"
    ) -> SpeakerProfile {
        SpeakerProfile(participantID: id, modelVersion: model, samples: samples)
    }
}
