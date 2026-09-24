import CallRecorderCore
import Foundation
import Testing
@testable import CallRecorderApp

@Suite("A call with one side")
struct OneSidedCallTests {
    @Test("a system track that held no sound is not separated again and again")
    func skipsSeparationOnASilentOtherSide() async throws {
        // Given: a call whose other side was never captured. Its system track is the shell
        // SystemAudioCheck calls missing, and the only words it left behind are one fragment.
        let fixture = try await OneSidedCall()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        // When: the separation is asked for with no diarizer and no voice store at all.
        // Then: it returns without them, because there is nothing on the other side to separate.
        try await fixture.pipeline.recognizeSpeakers(
            callID: fixture.callID,
            audioDirectory: fixture.directory,
            using: nil,
            speakerStore: nil,
            revisionManager: TranscriptRevisionManager(root: fixture.root)
        )
    }

    @Test("a system track that held sound is still separated")
    func separatesARealOtherSide() async throws {
        // Given: the same call with a system track big enough to have carried speech.
        let fixture = try await OneSidedCall(systemBytes: 200_000)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        // When / Then: the separation is asked for, so the missing diarizer is what stops it.
        await #expect(throws: DiarizerError.runtimeUnavailable) {
            try await fixture.pipeline.recognizeSpeakers(
                callID: fixture.callID,
                audioDirectory: fixture.directory,
                using: nil,
                speakerStore: nil,
                revisionManager: TranscriptRevisionManager(root: fixture.root)
            )
        }
    }

    @Test("a fragment of noise is not a remote word waiting for a voice")
    func fragmentDoesNotAskForSpeakerDetection() {
        // The 2026-09-22 13:44 call: nine microphone lines and one period from the other side.
        #expect(document(remote: TranscriptSegment(
            startMs: 104_400, endMs: 104_900, text: ".", source: .system
        )).needsSpeakerDetection == false)
        // A line that could hold a turn of its own is a voice that has not been found yet.
        #expect(document(remote: TranscriptSegment(
            startMs: 4_000, endMs: 14_000,
            text: "Hello, can you hear me? I can hear you clearly now.", source: .system
        )).needsSpeakerDetection == true)
    }

    @Test("a separation that answers no voice leaves the call with the words it has")
    func anEmptySeparationIsAnAnswer() async throws {
        // Given: a call whose other side is a real system track, a voice store that opens, and a
        // separation that answers with no voice at all -- which is what the 2026-09-24 11:13 call
        // got from the count-aware separation on seventeen seconds of near silence. Failing that
        // call for the answer left a transcribed call unfinishable, which is the fault the
        // missing-track rule already took out of one path.
        let fixture = try await OneSidedCall(systemBytes: 200_000, usesStubAudioTools: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let script = fixture.root.appending(path: "empty-diarizer.py")
        try """
        import json
        print(json.dumps({"model": "model-v1", "segments": [], "speakers": []}))
        """.write(to: script, atomically: true, encoding: .utf8)

        // When / Then: the separation is asked for, answers nothing, and the call is left as it is.
        try await fixture.pipeline.recognizeSpeakers(
            callID: fixture.callID,
            audioDirectory: fixture.directory,
            using: Diarizer(
                python: URL(filePath: "/usr/bin/python3"),
                script: script,
                ffmpeg: fixture.stubFFmpeg
            ),
            speakerStore: fixture.speakerStore,
            revisionManager: TranscriptRevisionManager(root: fixture.root)
        )
    }

    private func document(remote: TranscriptSegment) -> NormalizedTranscript {
        NormalizedTranscript(
            callId: UUID().uuidString,
            language: "en",
            model: "test",
            participants: [],
            glossary: [],
            segments: [
                TranscriptSegment(
                    startMs: 4_000, endMs: 16_000, text: "When is she coming?", source: .microphone
                ),
                remote,
            ]
        )
    }
}

/// A call of two minutes whose other side is a system track of the size the caller asks for.
private struct OneSidedCall {
    let root: URL
    let directory: URL
    let callID: CallID
    let store: CallStore
    let pipeline: CallPipeline
    let speakerStore: SpeakerStore
    /// A stand-in for ffmpeg that writes the file it is asked for: the two source tracks here are
    /// bytes, not recordings, so the real tool has nothing to decode.
    let stubFFmpeg: URL

    init(systemBytes: Int = 1_024, usesStubAudioTools: Bool = false) async throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "one-sided-call-\(UUID().uuidString)", directoryHint: .isDirectory)
        directory = root.appending(path: "2026-09-22T13-44-12", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // The two source files are what SystemAudioCheck measures: two megabytes of microphone
        // against a system track of the size the caller asks for.
        try Data(count: 2_000_000).write(to: directory.appending(path: "microphone.m4a"))
        try Data(count: systemBytes).write(to: directory.appending(path: "system.m4a"))
        callID = CallID(rawValue: UUID())
        store = try CallStore(path: root.appending(path: "calls.db").path)
        try await store.migrate()
        speakerStore = SpeakerStore(
            store: store,
            cipher: try VoiceprintCipher(keyData: Data(0..<32))
        )
        stubFFmpeg = root.appending(path: "ffmpeg")
        if usesStubAudioTools {
            try "#!/bin/sh\nfor last in \"$@\"; do :; done\n: > \"$last\"\n"
                .write(to: stubFFmpeg, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: stubFFmpeg.path
            )
        }
        try await store.createCall(.started(id: callID, at: Date(timeIntervalSince1970: 1_800_000_000)))
        try await store.updateCall(
            id: callID,
            endedAt: Date(timeIntervalSince1970: 1_800_000_130),
            audioPath: directory.appending(path: "call.m4a").path,
            status: .metadata
        )
        let json = directory.appending(path: "transcript.json")
        try JSONEncoder().encode(NormalizedTranscript(
            callId: callID.rawValue.uuidString,
            language: "en",
            model: "test",
            participants: [],
            glossary: [],
            segments: [
                TranscriptSegment(
                    startMs: 4_000, endMs: 74_600,
                    text: "Let's go together.", source: .microphone
                ),
                TranscriptSegment(startMs: 104_400, endMs: 104_900, text: ".", source: .system),
            ]
        )).write(to: json)
        let markdown = directory.appending(path: "transcript.md")
        try Data("transcript".utf8).write(to: markdown)
        try await store.saveTranscript(
            TranscriptRecord(
                callID: callID,
                language: "en",
                model: "test",
                text: "test",
                markdownPath: markdown.path,
                jsonPath: json.path
            ),
            queueIndexing: false
        )
        pipeline = CallPipeline(
            store: store,
            finalizer: MediaFinalizer(
                // The separation converts the source track with the finalizer's ffmpeg, so the
                // stand-in is the one the pipeline has to hold for the stub to be used.
                ffmpeg: usesStubAudioTools
                    ? stubFFmpeg
                    : URL(filePath: "/opt/homebrew/bin/ffmpeg"),
                ffprobe: URL(filePath: "/opt/homebrew/bin/ffprobe")
            )
        )
    }
}
