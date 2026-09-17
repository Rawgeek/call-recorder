import CallRecorderCore
import Foundation
import Testing
@testable import CallRecorderApp

@Suite("Speaker review playback")
struct SpeakerReviewPlaybackTests {
    private let callID = CallID(rawValue: UUID())

    private func segment(
        _ text: String,
        start: Int,
        end: Int,
        speaker: Int?,
        source: TranscriptAudioSource?
    ) -> TranscriptSegment {
        TranscriptSegment(
            startMs: start,
            endMs: end,
            text: text,
            speakerIndex: speaker,
            source: source
        )
    }

    @Test("samples never play intervening speakers and keep continuous context")
    func excerptCombinesMatchingSpeakerSegments() {
        // Given
        let segments = [
            segment("Hello first", start: 0, end: 1_000, speaker: 0, source: .system),
            segment("Local microphone must never identify the remote voice", start: 100, end: 900, speaker: 0, source: .microphone),
            segment("Second speaker", start: 1_200, end: 2_000, speaker: 1, source: .system),
            segment("Speaker zero continues with more words", start: 2_100, end: 3_000, speaker: 0, source: .system),
            segment("Another speaker", start: 3_100, end: 4_000, speaker: 1, source: .system),
            segment("Final identifying phrase", start: 4_100, end: 5_000, speaker: 0, source: .system),
            segment("Fourth phrase is outside the limit", start: 5_100, end: 6_000, speaker: 0, source: .system),
        ]

        // When
        let excerpts = SpeakerReviewPlayback.excerpts(
            from: segments,
            speakerIndex: 0
        )

        // Then
        #expect(excerpts.count == 3)
        #expect(excerpts[0].text == "Hello first")
        #expect(excerpts[0].endMs == 1_000)
        #expect(excerpts[1].startMs == 2_100)
        #expect(excerpts[2].text == "Final identifying phrase Fourth phrase is outside the limit")
    }

    @Test("the opening turn is kept even when it is the shortest")
    func openingTurnSurvivesTheLengthRanking() {
        // Given a long call where the greeting is short and four later turns are longer.
        let segments = [
            segment("Hi Sam, it's Dana.", start: 0, end: 2_000, speaker: 0, source: .system),
            segment(String(repeating: "long turn one ", count: 12), start: 10_000, end: 40_000, speaker: 0, source: .system),
            segment(String(repeating: "long turn two ", count: 11), start: 60_000, end: 90_000, speaker: 0, source: .system),
            segment(String(repeating: "long turn three ", count: 10), start: 120_000, end: 150_000, speaker: 0, source: .system),
            segment(String(repeating: "long turn four ", count: 9), start: 180_000, end: 210_000, speaker: 0, source: .system),
        ]

        // When
        let excerpts = SpeakerReviewPlayback.excerpts(from: segments, speakerIndex: 0, limit: 3)

        // Then the three longest turns plus the greeting, in call order.
        #expect(excerpts.count == 4)
        #expect(excerpts.first?.text == "Hi Sam, it's Dana.")
        #expect(excerpts.first?.startMs == 0)
    }

    @Test("excerpt is nil when the speaker has no segments")
    func excerptIsNilWithoutMatchingSegments() {
        // Given
        let segments = [
            segment("Only speaker", start: 0, end: 1_000, speaker: 7, source: .system)
        ]

        // When
        let excerpts = SpeakerReviewPlayback.excerpts(from: segments, speakerIndex: 0)

        // Then
        #expect(excerpts.isEmpty)
    }

    @Test("transcript evidence remains available after source audio is cleaned")
    func transcriptEvidenceSurvivesAudioCleanup() {
        let review = SpeakerReviewItem(
            clusterID: SpeakerClusterID(rawValue: UUID()),
            callID: callID,
            speakerIndex: 1,
            speakerLabel: "Speaker 2",
            speechDurationMilliseconds: 9_000,
            suggestedParticipantID: nil,
            state: .unknown,
            createdAt: Date()
        )
        let transcript = NormalizedTranscript(
            callId: callID.rawValue.uuidString,
            language: "en",
            model: "test",
            participants: [],
            glossary: [],
            segments: [
                segment("Wrong speaker", start: 0, end: 1_000, speaker: 0, source: .system),
                segment(
                    "This is enough context to identify the speaker.",
                    start: 1_000,
                    end: 3_000,
                    speaker: 1,
                    source: .system
                ),
            ]
        )

        let evidence = SpeakerReviewPlayback.evidence(
            for: review,
            transcript: transcript,
            callDirectory: URL(filePath: "/missing/call"),
            recoverableArtifacts: [],
            fileExists: { _ in false }
        )

        #expect(evidence.excerpts.first?.text == "This is enough context to identify the speaker.")
        #expect(evidence.excerpts.first?.startMs == 1_000)
        #expect(evidence.excerpts.first?.endMs == 3_000)
        #expect(evidence.audioURL == nil)
    }

    @Test("source-specific audio is preferred, then call.m4a, then the Recently Deleted payload")
    func audioResolutionPreferenceOrder() throws {
        // Given
        let root = FileManager.default.temporaryDirectory
            .appending(path: "speaker-review-audio-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let callDirectory = root.appending(path: "call", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: callDirectory, withIntermediateDirectories: true)
        let sourceSpecific = callDirectory.appending(path: "system.m4a")
        let callAudio = callDirectory.appending(path: "call.m4a")
        let recoveryDirectory = root.appending(path: "recovery", directoryHint: .isDirectory)
        let payloadDirectory = recoveryDirectory.appending(path: "payload", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: payloadDirectory, withIntermediateDirectories: true)
        let payloadSource = payloadDirectory.appending(path: "system.m4a")
        let payloadCallAudio = payloadDirectory.appending(path: "call.m4a")
        try Data([1]).write(to: sourceSpecific)
        try Data([2]).write(to: callAudio)
        try Data([3]).write(to: payloadSource)
        try Data([4]).write(to: payloadCallAudio)
        let artifact = RecoverableArtifact(
            callID: callID,
            kind: .discardedRecording,
            originalDirectory: callDirectory,
            recoveryDirectory: recoveryDirectory,
            deletedAt: Date(),
            purgeAfter: Date().addingTimeInterval(60)
        )

        // When: all candidates exist, the source-specific file wins.
        var resolved = SpeakerReviewPlayback.resolveAudio(
            review: SpeakerReviewItem(
                clusterID: SpeakerClusterID(rawValue: UUID()),
                callID: callID,
                speakerIndex: 0,
                speakerLabel: "Speaker 1",
                speechDurationMilliseconds: 1_000,
                suggestedParticipantID: nil,
                state: .unknown,
                createdAt: Date()
            ),
            callDirectory: callDirectory,
            recoverableArtifacts: [artifact],
            fileExists: { FileManager.default.fileExists(atPath: $0.path) }
        )
        #expect(resolved == sourceSpecific)

        // When: the source-specific file is missing, call.m4a wins.
        try FileManager.default.removeItem(at: sourceSpecific)
        resolved = SpeakerReviewPlayback.resolveAudio(
            review: review,
            callDirectory: callDirectory,
            recoverableArtifacts: [artifact],
            fileExists: { FileManager.default.fileExists(atPath: $0.path) }
        )
        #expect(resolved == callAudio)

        // When: both working-directory files are missing, the payload source file wins.
        try FileManager.default.removeItem(at: callAudio)
        resolved = SpeakerReviewPlayback.resolveAudio(
            review: review,
            callDirectory: callDirectory,
            recoverableArtifacts: [artifact],
            fileExists: { FileManager.default.fileExists(atPath: $0.path) }
        )
        #expect(resolved == payloadSource)

        // When: only the payload call.m4a remains, it wins.
        try FileManager.default.removeItem(at: payloadSource)
        resolved = SpeakerReviewPlayback.resolveAudio(
            review: review,
            callDirectory: callDirectory,
            recoverableArtifacts: [artifact],
            fileExists: { FileManager.default.fileExists(atPath: $0.path) }
        )
        #expect(resolved == payloadCallAudio)

        // When: everything is gone, the sample is explicitly unavailable.
        try FileManager.default.removeItem(at: payloadCallAudio)
        resolved = SpeakerReviewPlayback.resolveAudio(
            review: review,
            callDirectory: callDirectory,
            recoverableArtifacts: [artifact],
            fileExists: { FileManager.default.fileExists(atPath: $0.path) }
        )
        #expect(resolved == nil)
    }

    @Test("an unrelated call's payload is never used")
    func unrelatedPayloadIsIgnored() throws {
        // Given
        let root = FileManager.default.temporaryDirectory
            .appending(path: "speaker-review-other-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let callDirectory = root.appending(path: "call", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: callDirectory, withIntermediateDirectories: true)
        let otherCall = CallID(rawValue: UUID())
        let unrelatedPayload = root
            .appending(path: "recovery", directoryHint: .isDirectory)
            .appending(path: "payload", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: unrelatedPayload, withIntermediateDirectories: true)
        try Data([9]).write(to: unrelatedPayload.appending(path: "call.m4a"))
        let artifact = RecoverableArtifact(
            callID: otherCall,
            kind: .discardedRecording,
            originalDirectory: callDirectory,
            recoveryDirectory: root.appending(path: "recovery", directoryHint: .isDirectory),
            deletedAt: Date(),
            purgeAfter: Date().addingTimeInterval(60)
        )

        // When
        let resolved = SpeakerReviewPlayback.resolveAudio(
            review: review,
            callDirectory: callDirectory,
            recoverableArtifacts: [artifact],
            fileExists: { FileManager.default.fileExists(atPath: $0.path) }
        )

        // Then
        #expect(resolved == nil)
    }

    @Test("excerpt range stays within a source's boundaries and stops at the excerpt end")
    func excerptRangeStopsAtExcerptEnd() {
        // Given
        let excerpt = SpeakerReviewPlayback.Excerpt(text: "sample", startMs: 1_000, endMs: 2_000)

        // When
        let range = excerpt.playbackRange(duration: 60)

        // Then
        #expect(range.start == 1.0)
        #expect(range.stop == 2.0)
    }

    @Test("playback range clamps to the audio duration")
    func excerptRangeClampsToDuration() {
        // Given
        let excerpt = SpeakerReviewPlayback.Excerpt(text: "sample", startMs: 5_000, endMs: 12_000)

        // When
        let range = excerpt.playbackRange(duration: 6)

        // Then
        #expect(range.start == 5.0)
        #expect(range.stop == 6.0)
    }

    private var review: SpeakerReviewItem {
        SpeakerReviewItem(
            clusterID: SpeakerClusterID(rawValue: UUID()),
            callID: callID,
            speakerIndex: 0,
            speakerLabel: "Speaker 1",
            speechDurationMilliseconds: 1_000,
            suggestedParticipantID: nil,
            state: .unknown,
            createdAt: Date()
        )
    }
}
