import AVFoundation
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

    @Test("the mix is preferred, then the system track, then the microphone, then the payload")
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

        // When: all candidates exist, the mix wins. It is the only file that holds both sides of
        // the call, and the local participant's row on the timeline is drawn from the microphone
        // half: playing the system track alone left that row silent (2026-10-12).
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
        #expect(resolved == callAudio)

        // When: the mix is missing, the system track wins: it is the side the review is drawn from.
        try FileManager.default.removeItem(at: callAudio)
        resolved = SpeakerReviewPlayback.resolveAudio(
            review: review,
            callDirectory: callDirectory,
            recoverableArtifacts: [artifact],
            fileExists: { FileManager.default.fileExists(atPath: $0.path) }
        )
        #expect(resolved == sourceSpecific)

        // When: a call has only its microphone half left, that is what plays.
        try FileManager.default.removeItem(at: sourceSpecific)
        let microphoneOnly = callDirectory.appending(path: "microphone.m4a")
        try Data([5]).write(to: microphoneOnly)
        resolved = SpeakerReviewPlayback.resolveAudio(
            review: review,
            callDirectory: callDirectory,
            recoverableArtifacts: [artifact],
            fileExists: { FileManager.default.fileExists(atPath: $0.path) }
        )
        #expect(resolved == microphoneOnly)

        // When: the call's own directory holds nothing, the payload's mix wins.
        try FileManager.default.removeItem(at: microphoneOnly)
        resolved = SpeakerReviewPlayback.resolveAudio(
            review: review,
            callDirectory: callDirectory,
            recoverableArtifacts: [artifact],
            fileExists: { FileManager.default.fileExists(atPath: $0.path) }
        )
        #expect(resolved == payloadCallAudio)

        // When: only the payload's system track remains, it wins.
        try FileManager.default.removeItem(at: payloadCallAudio)
        resolved = SpeakerReviewPlayback.resolveAudio(
            review: review,
            callDirectory: callDirectory,
            recoverableArtifacts: [artifact],
            fileExists: { FileManager.default.fileExists(atPath: $0.path) }
        )
        #expect(resolved == payloadSource)

        // When: everything is gone, the sample is explicitly unavailable.
        try FileManager.default.removeItem(at: payloadSource)
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

    @Test("selecting a call without audio clears the previous recording and its state")
    @MainActor
    func callWithoutAudioUnloadsThePreviousOne() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "call-playback-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let callA = root.appending(path: "a.wav")
        let callC = root.appending(path: "c.wav")
        try writeTone(to: callA, seconds: 0.25)
        try writeTone(to: callC, seconds: 0.5)
        let playback = CallPlayback()

        playback.load(callA)
        let durationA = playback.durationMs
        playback.seek(toMs: 120)
        playback.load(nil)

        #expect(durationA > 0)
        #expect(playback.url == nil)
        #expect(playback.durationMs == 0)
        #expect(playback.positionMs == 0)
        #expect(!playback.isPlaying)
        #expect(playback.failure == nil)

        playback.load(callA)
        playback.seek(toMs: 200)
        playback.load(callC)

        #expect(playback.url == callC)
        #expect(playback.durationMs >= 450)
        #expect(playback.positionMs == 0)
        #expect(playback.failure == nil)
    }

    @Test("selecting a call without audio clears a previous playback error")
    @MainActor
    func callWithoutAudioClearsFailure() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "call-playback-error-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let broken = root.appending(path: "broken.wav")
        try Data("not audio".utf8).write(to: broken)
        let playback = CallPlayback()

        playback.load(broken)
        #expect(playback.failure != nil)
        playback.load(nil)

        #expect(playback.url == nil)
        #expect(playback.failure == nil)
        #expect(playback.durationMs == 0)
    }

    @Test("moving to another call loads that call's recording, whatever the view order")
    @MainActor
    func callChangeLoadsTheSelectedCallsRecording() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "call-selection-ordering-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let withAudio = CallID(rawValue: UUID())
        let withoutAudio = CallID(rawValue: UUID())
        let otherAudio = CallID(rawValue: UUID())
        let audioA = root.appending(path: "a.wav")
        let audioC = root.appending(path: "c.wav")
        try writeTone(to: audioA, seconds: 0.25)
        try writeTone(to: audioC, seconds: 0.5)
        let urls: [CallID: URL] = [withAudio: audioA, otherAudio: audioC]
        let playback = CallPlayback()

        playback.load(SpeakerSelectionAudio.url(for: withAudio, audioURLs: urls))
        #expect(playback.url == audioA)
        playback.seek(toMs: 120)

        // A call without audio must take the old recording off the player.
        playback.load(SpeakerSelectionAudio.url(for: withoutAudio, audioURLs: urls))
        #expect(playback.url == nil)
        #expect(playback.durationMs == 0)
        #expect(playback.positionMs == 0)
        #expect(playback.failure == nil)

        // A call with audio must load its own recording, not the one left behind nor nothing.
        playback.load(SpeakerSelectionAudio.url(for: otherAudio, audioURLs: urls))
        #expect(playback.url == audioC)
        #expect(playback.durationMs >= 450)
        #expect(playback.positionMs == 0)
        #expect(playback.failure == nil)
    }

    private func writeTone(to url: URL, seconds: Double) throws {
        let sampleRate = 8_000.0
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: .pcmFormatInt16,
            interleaved: false
        )
        let frames = AVAudioFrameCount(sampleRate * seconds)
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)
        )
        buffer.frameLength = frames
        if let samples = buffer.int16ChannelData?[0] {
            for index in 0..<Int(frames) {
                samples[index] = Int16((sin(Double(index) * 0.08) * 1_000).rounded())
            }
        }
        try file.write(from: buffer)
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
