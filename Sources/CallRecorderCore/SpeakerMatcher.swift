import Foundation

public enum SpeakerMatcher {
    public static func match(
        clusters: [SpeakerCluster],
        profiles: [SpeakerProfile],
        policy: SpeakerMatchPolicy = .default
    ) -> [SpeakerMatch] {
        guard !clusters.isEmpty else { return [] }
        let orderedProfiles = profiles.sorted {
            $0.participantID.rawValue.uuidString < $1.participantID.rawValue.uuidString
        }
        let profileVectors = orderedProfiles.map(profileVector)
        let scores = clusters.map { cluster in
            orderedProfiles.indices.map { index in
                guard
                    cluster.modelVersion == orderedProfiles[index].modelVersion,
                    let clusterVector = normalized(cluster.embedding),
                    let profileVector = profileVectors[index],
                    clusterVector.count == profileVector.count
                else { return -1.0 }
                return zip(clusterVector, profileVector).reduce(0) { $0 + $1.0 * $1.1 }
            }
        }
        let assignments = assign(scores: scores, clusters: clusters, policy: policy)
        return clusters.indices.map { clusterIndex in
            guard let profileIndex = assignments[clusterIndex] else {
                guard
                    let suggestion = bestProfile(scores[clusterIndex]),
                    scores[clusterIndex][suggestion] >= Double(policy.reviewSimilarity)
                else {
                    return SpeakerMatch(
                        clusterID: clusters[clusterIndex].id,
                        participantID: nil,
                        state: .unknown
                    )
                }
                // The fragment is close to the profile, but it does not sound like the
                // fragments that person already holds. Offer the name for review only.
                return SpeakerMatch(
                    clusterID: clusters[clusterIndex].id,
                    participantID: orderedProfiles[suggestion].participantID,
                    state: .suggested
                )
            }
            let similarity = scores[clusterIndex][profileIndex]
            let secondBest = scores[clusterIndex].indices
                .filter { $0 != profileIndex }
                .map { scores[clusterIndex][$0] }
                .max() ?? -1
            let profile = orderedProfiles[profileIndex]
            let automatic = similarity >= Double(policy.acceptanceSimilarity)
                && similarity - secondBest >= Double(policy.acceptanceMargin)
                && clusters[clusterIndex].speechDurationMilliseconds
                    >= policy.minimumSpeechMilliseconds
                && profile.samples.count >= policy.minimumConfirmedSamples
            return SpeakerMatch(
                clusterID: clusters[clusterIndex].id,
                participantID: profile.participantID,
                state: automatic ? .automatic : .suggested
            )
        }
    }

    /// Pairs fragments and people from the strongest similarity down. Every fragment keeps at
    /// most one person, and a person may take a second fragment only when that fragment sounds
    /// like each fragment the person already holds. Diarization splits one voice across
    /// fragments, so holding two fragments is valid; holding unrelated fragments is not.
    private static func assign(
        scores: [[Double]],
        clusters: [SpeakerCluster],
        policy: SpeakerMatchPolicy
    ) -> [Int: Int] {
        struct Candidate {
            let clusterIndex: Int
            let profileIndex: Int
            let similarity: Double
        }
        var candidates: [Candidate] = []
        for clusterIndex in scores.indices {
            for (profileIndex, similarity) in scores[clusterIndex].enumerated()
            where similarity >= Double(policy.reviewSimilarity) {
                candidates.append(
                    Candidate(
                        clusterIndex: clusterIndex,
                        profileIndex: profileIndex,
                        similarity: similarity
                    )
                )
            }
        }
        candidates.sort {
            if $0.similarity != $1.similarity { return $0.similarity > $1.similarity }
            if $0.clusterIndex != $1.clusterIndex { return $0.clusterIndex < $1.clusterIndex }
            return $0.profileIndex < $1.profileIndex
        }
        var assignments: [Int: Int] = [:]
        var heldClusters: [Int: [Int]] = [:]
        for candidate in candidates {
            guard assignments[candidate.clusterIndex] == nil else { continue }
            let held = heldClusters[candidate.profileIndex] ?? []
            let holdsOneVoice = held.allSatisfy {
                soundsLikeOneVoice(clusters[$0], clusters[candidate.clusterIndex], policy: policy)
            }
            guard holdsOneVoice else { continue }
            assignments[candidate.clusterIndex] = candidate.profileIndex
            heldClusters[candidate.profileIndex] = held + [candidate.clusterIndex]
        }
        return assignments
    }

    private static func bestProfile(_ scores: [Double]) -> Int? {
        scores.indices.filter { scores[$0] >= 0 }.max { scores[$0] < scores[$1] }
    }


    /// Cosine similarity between one fragment and a learned profile, or nil when the pair
    /// cannot be compared.
    public static func similarity(of cluster: SpeakerCluster, to profile: SpeakerProfile) -> Double? {
        guard
            cluster.modelVersion == profile.modelVersion,
            let clusterVector = normalized(cluster.embedding),
            let profileVector = profileVector(profile),
            clusterVector.count == profileVector.count
        else { return nil }
        return zip(clusterVector, profileVector).reduce(0) { $0 + $1.0 * $1.1 }
    }

    /// Cosine similarity between two fragments of one recording.
    public static func similarity(_ lhs: SpeakerCluster, _ rhs: SpeakerCluster) -> Double? {
        guard
            lhs.modelVersion == rhs.modelVersion,
            let left = normalized(lhs.embedding),
            let right = normalized(rhs.embedding),
            left.count == right.count
        else { return nil }
        return zip(left, right).reduce(0) { $0 + $1.0 * $1.1 }
    }

    private static func soundsLikeOneVoice(
        _ lhs: SpeakerCluster,
        _ rhs: SpeakerCluster,
        policy: SpeakerMatchPolicy
    ) -> Bool {
        guard let similarity = similarity(lhs, rhs) else { return false }
        return similarity >= Double(policy.splitVoiceSimilarity)
    }

    private static func profileVector(_ profile: SpeakerProfile) -> [Double]? {
        let samples = profile.samples.compactMap(normalized)
        guard let dimension = samples.first?.count, samples.allSatisfy({ $0.count == dimension }) else {
            return nil
        }
        var average = Array(repeating: 0.0, count: dimension)
        for sample in samples {
            for index in sample.indices { average[index] += sample[index] }
        }
        return normalized(average)
    }

    private static func normalized(_ values: [Float]) -> [Double]? {
        normalized(values.map(Double.init))
    }

    private static func normalized(_ values: [Double]) -> [Double]? {
        guard !values.isEmpty, values.allSatisfy(\.isFinite) else { return nil }
        let norm = sqrt(values.reduce(0) { $0 + $1 * $1 })
        guard norm.isFinite, norm > 0 else { return nil }
        return values.map { $0 / norm }
    }

}
