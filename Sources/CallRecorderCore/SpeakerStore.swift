import Foundation

struct EncryptedPendingSpeakerCluster: Sendable {
    let callID: CallID
    let speakerIndex: Int
    let speakerLabel: String
    let clusterID: SpeakerClusterID
    let modelVersion: String
    let encryptedEmbedding: Data
    let speechDurationMilliseconds: Int
    let createdAt: Date
    let expiresAt: Date
}

struct EncryptedVoiceSample: Sendable {
    let participantID: ParticipantID
    let modelVersion: String
    let encryptedEmbedding: Data
}


public struct SpeakerReconcileReport: Equatable, Sendable {
    public let groups: Int
    public let fragments: Int
    public let reopened: [SpeakerReviewItem]
    /// The closest match to the person's own voice among the fragments that returned to review,
    /// for diagnosing the threshold.
    public let highestRejectedSimilarity: Float?

    public init(
        groups: Int,
        fragments: Int,
        reopened: [SpeakerReviewItem],
        highestRejectedSimilarity: Float?
    ) {
        self.groups = groups
        self.fragments = fragments
        self.reopened = reopened
        self.highestRejectedSimilarity = highestRejectedSimilarity
    }
}

public struct SpeakerStore: Sendable {
    private let store: CallStore
    private let cipher: VoiceprintCipher

    public init(store: CallStore, cipher: VoiceprintCipher) {
        self.store = store
        self.cipher = cipher
    }

    public static func production(
        store: CallStore,
        keyLocation: VoiceprintKeyLocation = .keychain
    ) async throws -> SpeakerStore {
        let cipher = try VoiceprintKeyStore.loadOrCreate(
            hasEncryptedData: try await store.hasEncryptedSpeakerData(),
            in: keyLocation
        )
        return SpeakerStore(store: store, cipher: cipher)
    }

    @discardableResult
    public func savePending(_ pending: PendingSpeakerCluster) async throws -> SpeakerClusterID {
        let encrypted = try cipher.seal(
            pending.cluster.embedding,
            modelVersion: pending.cluster.modelVersion
        )
        return try await store.upsertPendingSpeakerCluster(
            EncryptedPendingSpeakerCluster(
                callID: pending.callID,
                speakerIndex: pending.speakerIndex,
                speakerLabel: pending.speakerLabel,
                clusterID: pending.cluster.id,
                modelVersion: pending.cluster.modelVersion,
                encryptedEmbedding: encrypted,
                speechDurationMilliseconds: pending.cluster.speechDurationMilliseconds,
                createdAt: pending.createdAt,
                expiresAt: pending.expiresAt
            )
        )
    }

    public func pendingClusters(
        for callID: CallID,
        at date: Date = Date()
    ) async throws -> [PendingSpeakerCluster] {
        try await store.encryptedPendingSpeakerClusters(for: callID, at: date).map { record in
            PendingSpeakerCluster(
                callID: record.callID,
                speakerIndex: record.speakerIndex,
                speakerLabel: record.speakerLabel,
                cluster: SpeakerCluster(
                    id: record.clusterID,
                    modelVersion: record.modelVersion,
                    embedding: try cipher.open(
                        record.encryptedEmbedding,
                        modelVersion: record.modelVersion
                    ),
                    speechDurationMilliseconds: record.speechDurationMilliseconds
                ),
                createdAt: record.createdAt
            )
        }
    }

    public func profiles(modelVersion: String) async throws -> [SpeakerProfile] {
        let samples = try await store.encryptedVoiceSamples(modelVersion: modelVersion)
        var byParticipant: [ParticipantID: [[Float]]] = [:]
        for sample in samples {
            byParticipant[sample.participantID, default: []].append(
                try cipher.open(sample.encryptedEmbedding, modelVersion: sample.modelVersion)
            )
        }
        return byParticipant.keys.sorted {
            $0.rawValue.uuidString < $1.rawValue.uuidString
        }.map { participantID in
            SpeakerProfile(
                participantID: participantID,
                modelVersion: modelVersion,
                samples: byParticipant[participantID] ?? []
            )
        }
    }

    public func identify(
        _ pendingClusters: [PendingSpeakerCluster],
        policy: SpeakerMatchPolicy = .default
    ) async throws -> [SpeakerMatch] {
        var storedClusters: [SpeakerCluster] = []
        for pending in pendingClusters {
            let storedID = try await savePending(pending)
            storedClusters.append(
                SpeakerCluster(
                    id: storedID,
                    modelVersion: pending.cluster.modelVersion,
                    embedding: pending.cluster.embedding,
                    speechDurationMilliseconds: pending.cluster.speechDurationMilliseconds
                )
            )
        }
        var matchesByCluster: [SpeakerClusterID: SpeakerMatch] = [:]
        // A pass of the speaker detector replaces what the pass before it found: the transcript is
        // relabelled from this pass alone, so a voice this pass did not produce must not stay on the
        // call. Left behind, it appears in the review window as a voice of a call whose transcript
        // never mentions it -- and, when the newer pass reused its number for a different person,
        // as a second voice under the same name.
        var keptByCall: [CallID: [SpeakerClusterID]] = [:]
        for (pending, stored) in zip(pendingClusters, storedClusters) {
            keptByCall[pending.callID, default: []].append(stored.id)
        }
        for (callID, kept) in keptByCall {
            try await store.retireSpeakerClusters(callID: callID, keeping: kept)
        }
        for modelVersion in Set(storedClusters.map(\.modelVersion)).sorted() {
            let compatibleClusters = storedClusters.filter { $0.modelVersion == modelVersion }
            let matches = SpeakerMatcher.match(
                clusters: compatibleClusters,
                profiles: try await profiles(modelVersion: modelVersion),
                policy: policy
            )
            try await store.saveSpeakerMatches(matches)
            for match in matches { matchesByCluster[match.clusterID] = match }
        }
        return storedClusters.compactMap { matchesByCluster[$0.id] }
    }

    public func confirm(
        clusterID: SpeakerClusterID,
        participantID: ParticipantID,
        policy: SpeakerMatchPolicy = .default
    ) async throws {
        try await store.confirmSpeaker(
            clusterID: clusterID,
            participantID: participantID,
            minimumSpeechMilliseconds: policy.minimumSpeechMilliseconds
        )
        try await rematchUnresolvedReviews(policy: policy)
    }

    @discardableResult
    public func rematchUnresolvedReviews(
        limit: Int = 100,
        at date: Date = Date(),
        policy: SpeakerMatchPolicy = .default
    ) async throws -> [SpeakerMatch] {
        let reviews = try await unresolvedReviews(limit: limit, at: date)
        let reviewsByCall = Dictionary(grouping: reviews, by: \.callID)
        var matches: [SpeakerMatch] = []

        for callID in reviewsByCall.keys.sorted(by: {
            $0.rawValue.uuidString < $1.rawValue.uuidString
        }) {
            let unresolvedClusterIDs = Set(
                reviewsByCall[callID, default: []].map(\.clusterID)
            )
            let pending = try await pendingClusters(for: callID, at: date)
                .filter { unresolvedClusterIDs.contains($0.cluster.id) }
                .sorted {
                    if $0.speakerIndex != $1.speakerIndex {
                        return $0.speakerIndex < $1.speakerIndex
                    }
                    return $0.cluster.id.rawValue.uuidString
                        < $1.cluster.id.rawValue.uuidString
                }
            let clustersByModel = Dictionary(grouping: pending, by: \.cluster.modelVersion)
            // Only the people on this call can be on this call.
            //
            // Every profile used to be offered to every call, so a voice that did not match
            // anybody present was still named as whoever it sounded most like out of the whole
            // roster. One recording named a person who was not on it: the suggestion came from a
            // different call in the library, and the participant line did not contain that name.
            // The suggestion was not close to anybody present, so the matcher reached past the
            // call for a name.
            //
            // A call with no participants keeps the old behaviour, because then there is nothing
            // to narrow to. A call that names people is the only case where the roster is known,
            // and it is also the case where a name from outside it is least likely to be right.
            let onCall = Set(try await store.participants(for: callID).map(\.id))
            for modelVersion in clustersByModel.keys.sorted() {
                let available = try await profiles(modelVersion: modelVersion)
                matches += SpeakerMatcher.match(
                    clusters: clustersByModel[modelVersion, default: []].map(\.cluster),
                    profiles: onCall.isEmpty
                        ? available
                        : available.filter { onCall.contains($0.participantID) },
                    policy: policy
                )
            }
        }
        // Existing transcripts need an explicit revision before a new identity can disappear from Review.
        let suggestions = matches.map { match in
            SpeakerMatch(clusterID: match.clusterID, participantID: match.participantID,
                         state: match.state == .automatic ? .suggested : match.state)
        }
        try await store.saveSpeakerMatches(suggestions)
        return suggestions
    }


    /// Repairs calls where one person was named on a fragment that does not sound like them.
    ///
    /// The fragment closest to the learned voice keeps the name, and so does a fragment whose own
    /// match to that voice reaches the bar at which the app offers the name: the repair holds no
    /// evidence against a fragment the app itself would have suggested. Every fragment below the
    /// bar returns to review, and it returns once. A fragment that is handed back and answered by
    /// a person keeps that answer, because a voiceprint does not move when the same comparison is
    /// run again -- which is what made one confirmed name come back at every launch.
    @discardableResult
    public func reconcileSharedSpeakers(
        at date: Date = Date(),
        policy: SpeakerMatchPolicy = .default
    ) async throws -> SpeakerReconcileReport {
        var groups = 0
        var fragments = 0
        var highestRejected: Float?
        var reopened: [SpeakerReviewItem] = []
        for group in try await store.sharedParticipantClusters() {
            groups += 1
            let clusters = try await pendingClusters(for: group.callID, at: date)
            let byID = Dictionary(uniqueKeysWithValues: clusters.map { ($0.cluster.id, $0.cluster) })
            let named = try await store.namedClusterIDs(
                callID: group.callID,
                participantID: group.participantID
            ).compactMap { byID[$0] }
            guard named.count > 1, let modelVersion = named.first?.modelVersion else { continue }
            let profiles = try await profiles(modelVersion: modelVersion)
            guard let profile = profiles.first(where: { $0.participantID == group.participantID })
            else { continue }
            let scored = named.compactMap { cluster -> (cluster: SpeakerCluster, score: Double)? in
                guard let score = SpeakerMatcher.similarity(of: cluster, to: profile) else { return nil }
                return (cluster, score)
            }.sorted { $0.score > $1.score }
            guard !scored.isEmpty else { continue }
            fragments += scored.count
            let answered = try await store.fragmentsAnsweredAfterRepair(
                callID: group.callID,
                participantID: group.participantID
            )
            for candidate in scored.dropFirst() {
                // The question here is whether the fragment sounds like the person at all. Whether
                // two fragments sound like one voice answers a different question, and it was the
                // wrong one to ask: a diarizer splits one voice across fragments that stay apart,
                // so the person's own two fragments were compared with each other and the name
                // they had just confirmed was handed back again.
                if candidate.score >= Double(policy.reviewSimilarity) { continue }
                if answered.contains(candidate.cluster.id) { continue }
                highestRejected = max(highestRejected ?? 0, Float(candidate.score))
                guard let stored = try await store.speakerReview(clusterID: candidate.cluster.id) else {
                    continue
                }
                try await store.reopenSpeakerReview(stored, at: date, byRepair: true)
                if let updated = try await store.speakerReview(clusterID: candidate.cluster.id) {
                    reopened.append(updated)
                }
            }
        }
        return SpeakerReconcileReport(
            groups: groups,
            fragments: fragments,
            reopened: reopened,
            highestRejectedSimilarity: highestRejected
        )
    }

    public func confirmedSampleCount(for participantID: ParticipantID) async throws -> Int {
        try await store.confirmedSpeakerSampleCount(for: participantID)
    }

    public func unresolvedReviews(
        limit: Int = 100,
        at date: Date = Date()
    ) async throws -> [SpeakerReviewItem] {
        try await store.unresolvedSpeakerReviews(limit: limit, at: date)
    }

    /// Every voice of one call, whatever was decided about it, in speaker order.
    ///
    /// The cards below the picture are the voices still waiting; the picture itself is every voice,
    /// so that a voice already named can be corrected from the same place it is seen.
    public func reviews(for callID: CallID) async throws -> [SpeakerReviewItem] {
        try await store.speakerReviews(for: callID)
    }

    public func keepUnknown(
        clusterID: SpeakerClusterID,
        at date: Date = Date()
    ) async throws {
        try await store.keepSpeakerUnknown(clusterID: clusterID, at: date)
    }

    public func reopen(_ review: SpeakerReviewItem, at date: Date = Date()) async throws {
        try await store.reopenSpeakerReview(review, at: date)
    }

    /// The stored review for one cluster whatever its state, for correcting a decided mapping.
    public func review(clusterID: SpeakerClusterID) async throws -> SpeakerReviewItem? {
        try await store.speakerReview(clusterID: clusterID)
    }

    public func profileSummaries(at date: Date = Date()) async throws -> [VoiceProfileSummary] {
        try await store.voiceProfileSummaries(at: date)
    }

    @discardableResult
    public func resetProfile(
        participantID: ParticipantID,
        at date: Date = Date()
    ) async throws -> Int {
        try await store.resetVoiceProfile(participantID: participantID, at: date)
    }

    @discardableResult
    public func restoreProfile(
        participantID: ParticipantID,
        at date: Date = Date()
    ) async throws -> Int {
        try await store.restoreVoiceProfile(participantID: participantID, at: date)
    }

    @discardableResult
    public func purgeExpiredProfileRecovery(at date: Date = Date()) async throws -> Int {
        try await store.purgeExpiredVoiceProfileRecovery(at: date)
    }

    @discardableResult
    public func purgeExpiredPending(at date: Date = Date()) async throws -> Int {
        try await store.purgeExpiredPendingSpeakerClusters(at: date)
    }
}
