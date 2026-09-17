import Foundation
import Libsql
import Testing
@testable import CallRecorderCore

@Suite("Speaker store")
struct SpeakerStoreTests {
    @Test("confirmation is encrypted, idempotent, and preserves foreign keys")
    func confirmsOnceWithoutPlaintext() async throws {
        let harness = try await Harness()
        let participant = try await harness.store.upsertParticipant(name: "Dana")
        let pending = harness.pending(createdAt: Date())
        try await harness.speakers.savePending(pending)

        try await harness.speakers.confirm(
            clusterID: pending.cluster.id,
            participantID: participant.id
        )
        try await harness.speakers.confirm(
            clusterID: pending.cluster.id,
            participantID: participant.id
        )

        #expect(try await harness.speakers.confirmedSampleCount(for: participant.id) == 1)
        let profiles = try await harness.speakers.profiles(modelVersion: pending.cluster.modelVersion)
        #expect(profiles == [
            SpeakerProfile(
                participantID: participant.id,
                modelVersion: pending.cluster.modelVersion,
                samples: [pending.cluster.embedding]
            ),
        ])
        #expect(try await harness.store.integrityReport().isHealthy)
        let connection = try Database(harness.databaseURL.path).connect()
        let blobs = try connection.query(
            "SELECT encrypted_embedding FROM participant_voice_samples"
        ).map { try $0.getData(0) }
        #expect(blobs.count == 1)
        for value in pending.cluster.embedding {
            #expect(blobs[0].range(of: littleEndianData(value)) == nil)
        }
    }

    @Test("unreviewed clusters survive expiry until the speaker is resolved")
    func retainsExpiredPendingUntilReviewed() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let harness = try await Harness()
        let old = harness.pending(
            id: SpeakerClusterID(rawValue: UUID()),
            createdAt: now.addingTimeInterval(-31 * 24 * 60 * 60),
            speakerIndex: 0
        )
        try await harness.speakers.savePending(old)

        #expect(try await harness.speakers.purgeExpiredPending(at: now) == 0)
        #expect(try await harness.speakers.pendingClusters(for: harness.callID, at: now).map(\.cluster.id) == [old.cluster.id])
        #expect(try await harness.speakers.unresolvedReviews(at: now).map(\.clusterID) == [old.cluster.id])

        try await harness.speakers.keepUnknown(clusterID: old.cluster.id, at: now)
        #expect(try await harness.speakers.purgeExpiredPending(at: now) == 1)
        #expect(try await harness.speakers.pendingClusters(for: harness.callID, at: now).isEmpty)
    }

    @Test("expired unresolved clusters remain visible and fresh diarization renews retention")
    func renewsPendingClusterRetention() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let harness = try await Harness()
        let expired = harness.pending(createdAt: now.addingTimeInterval(-31 * 24 * 60 * 60))
        let storedID = try await harness.speakers.savePending(expired)

        #expect(try await harness.speakers.pendingClusters(for: harness.callID, at: now).map(\.cluster.id) == [storedID])
        #expect(try await harness.speakers.unresolvedReviews(at: now).map(\.clusterID) == [storedID])
        #expect(try await harness.store.recentCalls(limit: 1, at: now).first?.unresolvedSpeakerCount == 1)

        let refreshed = harness.pending(
            id: SpeakerClusterID(rawValue: UUID()),
            createdAt: now
        )
        #expect(try await harness.speakers.savePending(refreshed) == storedID)
        let pending = try #require(
            try await harness.speakers.pendingClusters(for: harness.callID, at: now).first
        )
        #expect(pending.cluster.id == storedID)
        #expect(pending.createdAt == now)
        #expect(try await harness.store.recentCalls(limit: 1, at: now).first?.unresolvedSpeakerCount == 1)
    }

    @Test("automatic matches link calls without enrolling samples")
    func automaticMatchDoesNotEnroll() async throws {
        let harness = try await Harness()
        let participant = try await harness.store.upsertParticipant(name: "Adi")
        let confirmed = harness.pending(createdAt: Date())
        try await harness.speakers.savePending(confirmed)
        try await harness.speakers.confirm(
            clusterID: confirmed.cluster.id,
            participantID: participant.id,
            policy: testPolicy
        )
        let candidateCallID = CallID(rawValue: UUID())
        try await harness.store.createCall(.started(id: candidateCallID, at: Date()))
        let candidate = harness.pending(
            id: SpeakerClusterID(rawValue: UUID()),
            callID: candidateCallID,
            createdAt: Date()
        )

        let matches = try await harness.speakers.identify(
            [candidate],
            policy: testPolicy
        )

        #expect(matches == [
            SpeakerMatch(
                clusterID: candidate.cluster.id,
                participantID: participant.id,
                state: .automatic
            ),
        ])
        #expect(try await harness.speakers.confirmedSampleCount(for: participant.id) == 1)
        #expect(try await harness.store.participants(for: candidateCallID).map(\.id) == [participant.id])
    }

    @Test("confirmation rematches unresolved voice as a suggestion")
    func confirmationRematchesUnresolvedVoiceAsSuggestion() async throws {
        let now = Date()
        let harness = try await Harness()
        let participant = try await harness.store.upsertParticipant(name: "Dana")
        let seed = harness.pending(createdAt: now)
        try await harness.speakers.savePending(seed)

        let candidateCallID = CallID(rawValue: UUID())
        try await harness.store.createCall(.started(id: candidateCallID, at: now))
        let candidate = harness.pending(
            id: SpeakerClusterID(rawValue: UUID()),
            callID: candidateCallID,
            createdAt: now
        )
        try await harness.speakers.savePending(candidate)

        let initialReview = try #require(
            try await harness.speakers.unresolvedReviews()
                .first { $0.clusterID == candidate.cluster.id }
        )
        #expect(initialReview.state == .unknown)
        #expect(initialReview.suggestedParticipantID == nil)

        try await harness.speakers.confirm(
            clusterID: seed.cluster.id,
            participantID: participant.id,
            policy: .default
        )

        let rematchedReview = try #require(
            try await harness.speakers.unresolvedReviews()
                .first { $0.clusterID == candidate.cluster.id }
        )
        #expect(rematchedReview.state == .suggested)
        #expect(rematchedReview.suggestedParticipantID == participant.id)
        let readyToAutoName = SpeakerMatchPolicy(
            acceptanceSimilarity: 0.82, reviewSimilarity: 0.68, acceptanceMargin: 0.08,
            minimumSpeechMilliseconds: 8_000, minimumConfirmedSamples: 1
        )
        _ = try await harness.speakers.rematchUnresolvedReviews(policy: readyToAutoName)
        #expect(try await harness.speakers.unresolvedReviews().contains {
            $0.clusterID == candidate.cluster.id && $0.state == .suggested
        })
    }

    @Test("a voice is not suggested to a name that is not on the call")
    func suggestionStaysInsideTheCall() async throws {
        // The library holds a call whose line reads Emma, Evan, Sam and whose speaker was
        // still offered as Simon, who is not on it. Every profile used to be offered to every
        // call, so a voice that matched nobody present was named as whoever it sounded most like
        // out of the whole roster.
        let now = Date()
        let harness = try await Harness()
        let present = try await harness.store.upsertParticipant(name: "Present")
        let absent = try await harness.store.upsertParticipant(name: "Absent")
        let seed = harness.pending(createdAt: now)
        try await harness.speakers.savePending(seed)
        // Absent has a learned voice, Present has none yet.
        try await harness.speakers.confirm(
            clusterID: seed.cluster.id,
            participantID: absent.id,
            policy: testPolicy
        )

        let callID = CallID(rawValue: UUID())
        try await harness.store.createCall(.started(id: callID, at: now))
        // The call names one person, and that person is not the one with a voice profile.
        try await harness.store.setParticipants([present.id], for: callID)
        let voice = harness.pending(
            id: SpeakerClusterID(rawValue: UUID()),
            callID: callID,
            createdAt: now
        )
        try await harness.speakers.savePending(voice)

        let matches = try await harness.speakers.rematchUnresolvedReviews(policy: testPolicy)

        let forVoice = matches.first { $0.clusterID == voice.cluster.id }
        #expect(forVoice?.participantID == nil)
        #expect(forVoice?.state == .unknown)
    }

    @Test("a call that names nobody still matches the whole roster")
    func suggestionStillReachesWhenTheCallIsUnnamed() async throws {
        // Nothing to narrow to, so the old behaviour is the right one: a call recorded before any
        // participant was added can still be recognised from the voices it holds.
        let now = Date()
        let harness = try await Harness()
        let known = try await harness.store.upsertParticipant(name: "Known")
        let seed = harness.pending(createdAt: now)
        try await harness.speakers.savePending(seed)
        try await harness.speakers.confirm(
            clusterID: seed.cluster.id,
            participantID: known.id,
            policy: testPolicy
        )

        let callID = CallID(rawValue: UUID())
        try await harness.store.createCall(.started(id: callID, at: now))
        let voice = harness.pending(
            id: SpeakerClusterID(rawValue: UUID()),
            callID: callID,
            createdAt: now
        )
        try await harness.speakers.savePending(voice)

        let matches = try await harness.speakers.rematchUnresolvedReviews(policy: testPolicy)

        #expect(matches.first { $0.clusterID == voice.cluster.id }?.participantID == known.id)
    }

    @Test("reviewed unknown speakers no longer count as unresolved")
    func dismissesUnknownReview() async throws {
        let harness = try await Harness()
        let pending = harness.pending(createdAt: Date())
        try await harness.speakers.savePending(pending)

        #expect(try await harness.speakers.unresolvedReviews().map(\.clusterID) == [pending.cluster.id])
        #expect(try #require(try await harness.store.recentCalls(limit: 1).first).unresolvedSpeakerCount == 1)

        try await harness.speakers.keepUnknown(clusterID: pending.cluster.id)

        #expect(try await harness.speakers.unresolvedReviews().isEmpty)
        #expect(try #require(try await harness.store.recentCalls(limit: 1).first).unresolvedSpeakerCount == 0)
    }

    @Test("reset voice profile remains recoverable for twenty-four hours")
    func resetsAndRestoresVoiceProfile() async throws {
        let harness = try await Harness()
        let participant = try await harness.store.upsertParticipant(name: "Dana")
        let pending = harness.pending(createdAt: Date())
        try await harness.speakers.savePending(pending)
        try await harness.speakers.confirm(
            clusterID: pending.cluster.id,
            participantID: participant.id,
            policy: testPolicy
        )

        #expect(try await harness.speakers.resetProfile(participantID: participant.id) == 1)
        #expect(try await harness.speakers.confirmedSampleCount(for: participant.id) == 0)
        #expect(try await harness.speakers.profileSummaries().first?.recoverableSampleCount == 1)

        #expect(try await harness.speakers.restoreProfile(participantID: participant.id) == 1)
        #expect(try await harness.speakers.confirmedSampleCount(for: participant.id) == 1)
    }

    @Test("expired voice profile recovery cannot be shown or restored")
    func rejectsExpiredProfileRecovery() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let harness = try await Harness()
        let participant = try await harness.store.upsertParticipant(name: "Dana")
        let pending = harness.pending(createdAt: now.addingTimeInterval(-26 * 60 * 60))
        try await harness.speakers.savePending(pending)
        try await harness.speakers.confirm(
            clusterID: pending.cluster.id,
            participantID: participant.id,
            policy: testPolicy
        )
        _ = try await harness.speakers.resetProfile(
            participantID: participant.id,
            at: now.addingTimeInterval(-25 * 60 * 60)
        )

        let summary = try #require(
            try await harness.speakers.profileSummaries(at: now)
                .first { $0.participantID == participant.id }
        )
        #expect(summary.recoverableSampleCount == 0)
        #expect(try await harness.speakers.restoreProfile(participantID: participant.id, at: now) == 0)
        #expect(try await harness.speakers.confirmedSampleCount(for: participant.id) == 0)
    }

    @Test("lowercase participant identifiers still confirm speakers")
    func confirmsLowercaseParticipantIdentifiers() async throws {
        let harness = try await Harness()
        let legacyID = UUID().uuidString.lowercased()
        let connection = try Database(harness.databaseURL.path).connect()
        _ = try connection.execute(
            "INSERT INTO participants (id, name, normalized_name) VALUES (?, ?, ?)",
            [legacyID, "Dana Holt", "dana hart"]
        )
        _ = try connection.execute(
            "INSERT INTO call_participants (call_id, participant_id) VALUES (?, ?)",
            [harness.callID.rawValue.uuidString, legacyID]
        )
        let participantID = ParticipantID(rawValue: UUID(uuidString: legacyID) ?? UUID())
        let pending = harness.pending(createdAt: Date())
        try await harness.speakers.savePending(pending)

        try await harness.speakers.confirm(
            clusterID: pending.cluster.id,
            participantID: participantID
        )

        #expect(try await harness.speakers.confirmedSampleCount(for: participantID) == 1)
        #expect(try await harness.store.participants(for: harness.callID).map(\.id) == [participantID])
        let profiles = try await harness.store.voiceProfileSummaries()
        #expect(profiles.first { $0.participantID == participantID }?.confirmedSampleCount == 1)
        #expect(try await harness.store.integrityReport().isHealthy)
    }

    @Test("a decided speaker can be reopened and corrected")
    func reopensAndCorrectsDecidedSpeaker() async throws {
        let harness = try await Harness()
        let wrong = try await harness.store.upsertParticipant(name: "Wrong")
        let right = try await harness.store.upsertParticipant(name: "Right")
        let pending = harness.pending(createdAt: Date())
        try await harness.speakers.savePending(pending)
        try await harness.speakers.confirm(
            clusterID: pending.cluster.id,
            participantID: wrong.id
        )

        let decided = try #require(try await harness.speakers.review(clusterID: pending.cluster.id))
        #expect(decided.state == .confirmed)
        #expect(decided.suggestedParticipantID == wrong.id)
        #expect(try await harness.speakers.unresolvedReviews().isEmpty)

        try await harness.speakers.reopen(decided)

        #expect(try await harness.speakers.confirmedSampleCount(for: wrong.id) == 0)
        #expect(try await harness.speakers.unresolvedReviews().map(\.clusterID) == [pending.cluster.id])

        try await harness.speakers.confirm(
            clusterID: pending.cluster.id,
            participantID: right.id
        )

        #expect(try await harness.speakers.confirmedSampleCount(for: right.id) == 1)
        #expect(try await harness.speakers.confirmedSampleCount(for: wrong.id) == 0)
        #expect(try await harness.store.participants(for: harness.callID).map(\.id) == [right.id])
    }

    @Test("fragments that do not sound like the named person return to review")
    func reconcilesSharedSpeakerNames() async throws {
        let harness = try await Harness()
        let participant = try await harness.store.upsertParticipant(name: "Simon")
        let first = harness.pending(createdAt: Date(), embedding: [1, 0, 0, 0], speakerIndex: 0)
        let second = harness.pending(createdAt: Date(), embedding: [0.99, 0.05, 0, 0], speakerIndex: 1)
        let other = harness.pending(createdAt: Date(), embedding: [0, 1, 0, 0], speakerIndex: 2)
        for pending in [first, second, other] {
            try await harness.speakers.savePending(pending)
            try await harness.speakers.confirm(
                clusterID: pending.cluster.id,
                participantID: participant.id
            )
        }

        let report = try await harness.speakers.reconcileSharedSpeakers()

        // The two fragments of one voice keep the name, so only the third fragment reopens.
        #expect(report.reopened.map(\.clusterID) == [other.cluster.id])
        #expect(report.groups == 1)
        #expect(report.fragments == 3)
        #expect(try await harness.speakers.confirmedSampleCount(for: participant.id) == 2)
        let reopenedReview = try #require(
            try await harness.speakers.review(clusterID: other.cluster.id)
        )
        #expect(reopenedReview.state == .suggested)
        #expect(
            try await harness.speakers.review(clusterID: first.cluster.id)?.state == .confirmed
        )
        #expect(try await harness.speakers.unresolvedReviews().map(\.clusterID) == [other.cluster.id])
    }

    @Test("a decided speaker reopens when the person is stored under another casing")
    func reopensAcrossStoredCase() async throws {
        let harness = try await Harness()
        // Some rows were written by a tool that lowercases the identifier while this app writes and
        // looks up its own in upper case. The foreign key compares the two byte for byte, so the
        // reopen wrote a value the table rejected and the repair stopped on the first fragment.
        let storedID = UUID().uuidString.lowercased()
        let connection = try Database(harness.databaseURL.path).connect()
        _ = try connection.execute(
            "INSERT INTO participants (id, name, normalized_name) VALUES (?, ?, ?)",
            [storedID, "Dana", "dana"]
        )
        let participantID = ParticipantID(rawValue: UUID(uuidString: storedID) ?? UUID())
        let pending = harness.pending(createdAt: Date(), embedding: [1, 0, 0, 0], speakerIndex: 0)
        try await harness.speakers.savePending(pending)
        try await harness.speakers.confirm(clusterID: pending.cluster.id, participantID: participantID)
        let decided = try #require(try await harness.speakers.review(clusterID: pending.cluster.id))
        #expect(decided.state == .confirmed)

        try await harness.speakers.reopen(decided)

        let reopened = try #require(try await harness.speakers.review(clusterID: pending.cluster.id))
        #expect(reopened.state == .suggested)
        let stored = try connection.query(
            "SELECT participant_id FROM speaker_assignments WHERE cluster_id = ?",
            [pending.cluster.id.rawValue.uuidString]
        ).map { try $0.getString(0) }
        // The suggestion is kept, and it is kept in the casing the person is stored under.
        #expect(stored == [storedID])
        #expect(try await harness.store.integrityReport().isHealthy)
    }

    private var testPolicy: SpeakerMatchPolicy {
        SpeakerMatchPolicy(
            acceptanceSimilarity: 0.80,
            reviewSimilarity: 0.65,
            acceptanceMargin: 0.08,
            minimumSpeechMilliseconds: 8_000,
            minimumConfirmedSamples: 1
        )
    }

    private func littleEndianData(_ value: Float) -> Data {
        var bits = value.bitPattern.littleEndian
        return withUnsafeBytes(of: &bits) { Data($0) }
    }

    private struct Harness {
        let databaseURL: URL
        let store: CallStore
        let speakers: SpeakerStore
        let callID: CallID

        init() async throws {
            let directory = FileManager.default.temporaryDirectory
                .appending(path: "speaker-store-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            databaseURL = directory.appending(path: "calls.db")
            store = try CallStore(path: databaseURL.path)
            try await store.migrate()
            speakers = SpeakerStore(
                store: store,
                cipher: try VoiceprintCipher(keyData: Data(0..<32))
            )
            callID = CallID(rawValue: UUID())
            try await store.createCall(.started(id: callID, at: Date()))
        }

        func pending(
            id: SpeakerClusterID = SpeakerClusterID(rawValue: UUID()),
            callID: CallID? = nil,
            createdAt: Date,
            embedding: [Float] = [0.25, -0.5, 0.75, 1],
            speakerIndex: Int = 0
        ) -> PendingSpeakerCluster {
            PendingSpeakerCluster(
                callID: callID ?? self.callID,
                speakerIndex: speakerIndex,
                speakerLabel: "SPEAKER_\(String(format: "%02d", speakerIndex))",
                cluster: SpeakerCluster(
                    id: id,
                    modelVersion: "model-v1",
                    embedding: embedding,
                    speechDurationMilliseconds: 10_000
                ),
                createdAt: createdAt
            )
        }
    }
}
