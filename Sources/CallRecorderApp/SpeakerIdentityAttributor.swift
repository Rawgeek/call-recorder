import CallRecorderCore
import Foundation

struct SpeakerIdentityAttributor: Sendable {
    let store: CallStore
    let speakerStore: SpeakerStore
    let participants: [Participant]
    let policy: SpeakerMatchPolicy

    func resolve(
        callID: CallID,
        diarization: DiarizationResult
    ) async throws -> [Int: Participant] {
        guard
            let modelVersion = diarization.modelVersion,
            !diarization.clusters.isEmpty
        else { return [:] }
        var speakerIndexes: [String: Int] = [:]
        for turn in diarization.turns where speakerIndexes[turn.speakerLabel] == nil {
            speakerIndexes[turn.speakerLabel] = speakerIndexes.count
        }
        for cluster in diarization.clusters where speakerIndexes[cluster.speakerLabel] == nil {
            speakerIndexes[cluster.speakerLabel] = speakerIndexes.count
        }
        let pending = diarization.clusters.compactMap { cluster -> PendingSpeakerCluster? in
            guard let speakerIndex = speakerIndexes[cluster.speakerLabel] else { return nil }
            return PendingSpeakerCluster(
                callID: callID,
                speakerIndex: speakerIndex,
                speakerLabel: cluster.speakerLabel,
                cluster: SpeakerCluster(
                    id: SpeakerClusterID(rawValue: UUID()),
                    modelVersion: modelVersion,
                    embedding: cluster.embedding,
                    speechDurationMilliseconds: Int(
                        max(0, cluster.speechDurationSeconds * 1_000).rounded()
                    )
                ),
                createdAt: Date()
            )
        }
        let matches = try await speakerStore.identify(pending, policy: policy)
        let participantsByID = Dictionary(uniqueKeysWithValues: participants.map { ($0.id, $0) })
        var identities: [Int: Participant] = [:]
        for (cluster, match) in zip(pending, matches) {
            guard
                match.state == .automatic || match.state == .confirmed,
                let participantID = match.participantID,
                let participant = participantsByID[participantID]
            else { continue }
            identities[cluster.speakerIndex] = participant
        }
        return identities
    }
}
