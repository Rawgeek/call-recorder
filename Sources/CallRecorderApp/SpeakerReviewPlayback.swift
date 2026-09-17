import CallRecorderCore
import Foundation

enum SpeakerReviewPlayback {
    struct Evidence: Equatable {
        let excerpts: [Excerpt]
        let audioURL: URL?
        /// The lines already moved off this voice, so the card can show where they went instead of
        /// offering to move them again.
        var overrides: [SpeakerLineOverride] = []
    }

    struct Excerpt: Equatable {
        let text: String
        let startMs: Int
        let endMs: Int

        /// The excerpt's identity while it is on screen: the range of lines it holds.
        var id: String { "\(startMs)-\(endMs)" }
    }

    struct PlaybackRange: Equatable {
        let start: Double
        let stop: Double
    }

    static func excerpts(
        from segments: [TranscriptSegment],
        speakerIndex: Int,
        limit: Int = 8
    ) -> [Excerpt] {
        var samples: [Excerpt] = []
        var canJoin = false
        for segment in segments.filter({ $0.source != .microphone }).sorted(by: { $0.startMs < $1.startMs }) {
            guard segment.speakerIndex == speakerIndex, segment.endMs > segment.startMs,
                !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                canJoin = false
                continue
            }
            if canJoin, let previous = samples.last,
                segment.startMs >= previous.endMs, segment.startMs - previous.endMs <= 1_000,
                segment.endMs - previous.startMs <= 45_000
            {
                samples[samples.count - 1] = Excerpt(
                    text: previous.text + " " + segment.text, startMs: previous.startMs, endMs: segment.endMs
                )
            } else {
                samples.append(Excerpt(text: segment.text, startMs: segment.startMs, endMs: segment.endMs))
            }
            canJoin = true
        }
        // Prefer useful speech over greetings; each sample is one continuous turn.
        var selected = Array(samples.sorted { $0.text.count > $1.text.count }.prefix(max(0, limit)))
        // The opening exchange is where people greet each other and often say their own name, so
        // it is the single most useful excerpt for naming a voice. Keep it even when it is short.
        if let opening = samples.first,
            !selected.isEmpty,
            !selected.contains(where: { $0.startMs == opening.startMs })
        {
            selected.append(opening)
        }
        return selected.sorted { $0.startMs < $1.startMs }
    }

    /// The correction that covers an excerpt, if one does.
    ///
    /// An excerpt is the range the user assigned, so the two line up exactly and the answer is the
    /// correction with the same two ends. A correction that merely overlaps stays out of this: it
    /// belongs to a different run of lines, and showing it here would offer to undo somebody
    /// else's answer from the wrong card.
    static func override(
        for excerpt: Excerpt,
        in overrides: [SpeakerLineOverride]
    ) -> SpeakerLineOverride? {
        overrides.first { $0.startMs == excerpt.startMs && $0.endMs == excerpt.endMs }
    }

    static func resolveAudio(
        review: SpeakerReviewItem,
        callDirectory: URL,
        recoverableArtifacts: [RecoverableArtifact],
        fileExists: (URL) -> Bool
    ) -> URL? {
        let payloadDirectory =
            recoverableArtifacts
            .first(where: { $0.callID == review.callID })?
            .payloadDirectory
        let candidates = [
            callDirectory.appending(path: "system.m4a"),
            callDirectory.appending(path: "call.m4a"),
            payloadDirectory?.appending(path: "system.m4a"),
            payloadDirectory?.appending(path: "call.m4a"),
        ].compactMap { $0 }
        return candidates.first(where: fileExists)
    }

    static func evidence(
        for review: SpeakerReviewItem,
        transcript: NormalizedTranscript,
        callDirectory: URL,
        recoverableArtifacts: [RecoverableArtifact],
        fileExists: (URL) -> Bool
    ) -> Evidence {
        Evidence(
            excerpts: excerpts(
                from: transcript.segments,
                speakerIndex: review.speakerIndex
            ),
            audioURL: resolveAudio(
                review: review,
                callDirectory: callDirectory,
                recoverableArtifacts: recoverableArtifacts,
                fileExists: fileExists
            )
        )
    }
}

extension SpeakerReviewPlayback.Excerpt {
    func playbackRange(duration: Double) -> SpeakerReviewPlayback.PlaybackRange {
        let start = min(max(Double(startMs) / 1_000, 0), duration)
        let stop = min(max(Double(endMs) / 1_000, start), duration)
        return SpeakerReviewPlayback.PlaybackRange(start: start, stop: stop)
    }
}
