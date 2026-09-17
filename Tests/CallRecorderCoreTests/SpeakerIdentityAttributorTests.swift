import CallRecorderCore
import Foundation
import Testing
@testable import CallRecorderApp

@Suite("Speaker identity attributor")
struct SpeakerIdentityAttributorTests {
    @Test("safe global match resolves the diarized speaker index")
    func resolvesAutomaticIdentity() async throws {
        let harness = try await Harness()

        let identities = try await harness.attributor.resolve(
            callID: harness.candidateCallID,
            diarization: harness.diarization
        )

        #expect(identities == [0: harness.participant])
        #expect(try await harness.speakers.confirmedSampleCount(for: harness.participant.id) == 1)
        #expect(try await harness.store.participants(for: harness.candidateCallID) == [harness.participant])
    }

    @Test("identity failure stops the speaker stage without pretending it succeeded")
    func reportsIdentityFailure() async throws {
        let harness = try await Harness(useWrongAttributionKey: true)

        await #expect(throws: VoiceprintCipherError.authenticationFailed) {
            try await harness.attributor.resolve(
                callID: harness.candidateCallID, diarization: harness.diarization
            )
        }
    }

    private struct Harness {
        let store: CallStore
        let speakers: SpeakerStore
        let participant: Participant
        let candidateCallID: CallID
        let attributor: SpeakerIdentityAttributor
        let diarization: DiarizationResult

        init(useWrongAttributionKey: Bool = false) async throws {
            let directory = FileManager.default.temporaryDirectory
                .appending(path: "speaker-attributor-\(UUID().uuidString)", directoryHint: .isDirectory)
            store = try CallStore(path: directory.appending(path: "calls.db").path)
            try await store.migrate()
            participant = try await store.upsertParticipant(name: "Dana")
            let profileCallID = CallID(rawValue: UUID())
            candidateCallID = CallID(rawValue: UUID())
            try await store.createCall(.started(id: profileCallID, at: Date()))
            try await store.createCall(.started(id: candidateCallID, at: Date()))
            let goodCipher = try VoiceprintCipher(keyData: Data(0..<32))
            speakers = SpeakerStore(store: store, cipher: goodCipher)
            var embedding = Array(repeating: Float.zero, count: 256)
            embedding[0] = 1
            let confirmed = PendingSpeakerCluster(
                callID: profileCallID,
                speakerIndex: 0,
                speakerLabel: "SPEAKER_00",
                cluster: SpeakerCluster(
                    id: SpeakerClusterID(rawValue: UUID()),
                    modelVersion: "model-v1",
                    embedding: embedding,
                    speechDurationMilliseconds: 10_000
                ),
                createdAt: Date()
            )
            try await speakers.savePending(confirmed)
            try await speakers.confirm(
                clusterID: confirmed.cluster.id,
                participantID: participant.id,
                policy: Self.policy
            )
            let attributionStore = useWrongAttributionKey
                ? SpeakerStore(
                    store: store,
                    cipher: try VoiceprintCipher(keyData: Data(repeating: 42, count: 32))
                )
                : speakers
            attributor = SpeakerIdentityAttributor(
                store: store,
                speakerStore: attributionStore,
                participants: [participant],
                policy: Self.policy
            )
            diarization = DiarizationResult(
                modelVersion: "model-v1",
                turns: [
                    DiarizationTurn(start: 0, end: 10, speakerLabel: "SPEAKER_00"),
                ],
                clusters: [
                    DiarizedSpeakerCluster(
                        speakerLabel: "SPEAKER_00",
                        embedding: embedding,
                        speechDurationSeconds: 10
                    ),
                ]
            )
        }

        private static let policy = SpeakerMatchPolicy(
            acceptanceSimilarity: 0.80,
            reviewSimilarity: 0.65,
            acceptanceMargin: 0.08,
            minimumSpeechMilliseconds: 8_000,
            minimumConfirmedSamples: 1
        )
    }
}

@Suite("Speaker review candidates")
struct SpeakerReviewCandidateTests {
    private func person(_ name: String) -> Participant {
        Participant(id: ParticipantID(rawValue: UUID()), name: name)
    }

    @Test("the call's own people come first and are not offered twice")
    func callPeopleLeadTheList() {
        let ada = person("Ada")
        let bob = person("Bob")
        let zoe = person("Zoe")
        let everyone = [ada, bob, zoe]

        // The call had Bob and Zoe, and the stored people list is in name order as the database
        // returns it. Bob and Zoe lead, in the call's own order rather than in name order, and Ada
        // follows for the case where the voice is someone who was not on the call.
        let ordered = SpeakerReviewCandidates.ordered(participants: everyone, onCall: [zoe, bob])

        #expect(ordered.map(\.name) == ["Zoe", "Bob", "Ada"])
        #expect(Set(ordered.map(\.id)).count == ordered.count)
    }

    @Test("a call with nobody recorded still offers everyone")
    func emptyCallFallsBackToEveryone() {
        let everyone = [person("Ada"), person("Bob")]

        let ordered = SpeakerReviewCandidates.ordered(participants: everyone, onCall: [])

        #expect(ordered.map(\.name) == ["Ada", "Bob"])
    }

    @Test("the note says only for the people who were there")
    func membershipMatchesTheCall() {
        let ada = person("Ada")
        let bob = person("Bob")

        #expect(SpeakerReviewCandidates.wasOnCall(ada, onCall: [ada]))
        #expect(SpeakerReviewCandidates.wasOnCall(bob, onCall: [ada]) == false)
    }

    @Test("checked people lead the participant list and order within each group is kept")
    func checkedPeopleLeadTheParticipantList() {
        let ada = person("Ada")
        let bob = person("Bob")
        let zoe = person("Zoe")
        let everyone = [ada, bob, zoe]

        let ordered = SpeakerReviewCandidates.ordered(
            participants: everyone,
            leading: [bob.id, zoe.id]
        )

        // The checked people come first in the order the list already had them, so a row only ever
        // moves when the window opens, never while it is being used.
        #expect(ordered.map(\.name) == ["Bob", "Zoe", "Ada"])
    }

    @Test("an empty selection leaves the list in its own order")
    func emptySelectionLeavesTheOrderAlone() {
        let everyone = [person("Ada"), person("Bob")]

        let ordered = SpeakerReviewCandidates.ordered(participants: everyone, leading: [])

        #expect(ordered.map(\.name) == ["Ada", "Bob"])
    }
}

@Suite("Speaker reconcile summary")
struct SpeakerReconcileSummaryTests {
    @Test("a completed run carries its counts and the closest kept match")
    func completedRunKeepsItsCounts() {
        let summary = SpeakerReconcileSummary(
            finishedAt: Date(timeIntervalSince1970: 1_800_000_000),
            report: SpeakerReconcileReport(
                groups: 4,
                fragments: 11,
                reopened: [],
                highestRejectedSimilarity: 0.42
            )
        )

        #expect(summary.callsExamined == 4)
        #expect(summary.voicesExamined == 11)
        #expect(summary.returnedToReview == 0)
        #expect(summary.closestKeptSimilarity == 0.42)
        #expect(summary.failure == nil)
    }

    @Test("a run that found nothing is not the same as one that failed")
    func quietRunIsDistinguishableFromFailure() {
        // A run with no calls to examine still completed, which is what tells a reader that the
        // repair is working and has nothing to do rather than that it never ran.
        let quiet = SpeakerReconcileSummary(
            finishedAt: Date(timeIntervalSince1970: 1_800_000_000),
            report: SpeakerReconcileReport(
                groups: 0,
                fragments: 0,
                reopened: [],
                highestRejectedSimilarity: nil
            )
        )
        let broken = SpeakerReconcileSummary(
            finishedAt: Date(timeIntervalSince1970: 1_800_000_000),
            failure: "keychain locked"
        )

        #expect(quiet.failure == nil)
        #expect(quiet.callsExamined == 0)
        #expect(broken.failure == "keychain locked")
        #expect(broken.callsExamined == 0)
    }
}
