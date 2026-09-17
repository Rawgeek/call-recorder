import CallRecorderCore
import Foundation

struct CallPipeline: Sendable {
    let store: CallStore
    let finalizer: MediaFinalizer

    func start(callID: CallID, startedAt: Date) async throws {
        try await store.migrate()
        try await store.createCall(.started(id: callID, at: startedAt))
    }

    func finalize(
        callID: CallID,
        segments: [CaptureSegment],
        destination: URL,
        endedAt: Date
    ) async throws -> URL {
        let audio = try await finalizer.finalize(segments: segments, destination: destination)
        try await store.finalizeAndQueue(
            id: callID,
            endedAt: endedAt,
            audioPath: audio.path
        )
        return audio
    }

    func transcribe(
        callID: CallID,
        audio: URL,
        modelID: String,
        modelFile: URL,
        participantIDs: [ParticipantID],
        localParticipantID: ParticipantID? = nil,
        glossary: [GlossaryTerm],
        directory: URL,
        queueIndexing: Bool = true,
        using transcriber: Transcriber
    ) async throws -> TranscriptRecord {
        let allParticipants = try await store.listParticipants()
        // The two source files are still on disk, so this is the moment the answer about the other
        // side can be read. The cleanup removes them once the transcript and index are verified.
        try await store.setSystemAudio(SystemAudioCheck.state(in: directory), for: callID)
        let localParticipant = localParticipantID.flatMap { localID in
            allParticipants.first { $0.id == localID }
        }
        let selectedIDs = participantIDs + [localParticipant?.id].compactMap { $0 }
        try await store.setParticipants(Array(Set(selectedIDs)), for: callID)
        let selectedParticipants = try await store.participants(for: callID)
        let glossaryUsage = try await store.glossaryUsageCounts()
        let transcript = try await transcriber.transcribe(
            callID: callID,
            audio: audio,
            modelID: modelID,
            modelFile: modelFile,
            participants: selectedParticipants,
            glossary: glossary,
            glossaryUsage: glossaryUsage,
            directory: directory,
            localParticipant: localParticipant
        )
        try await store.saveTranscript(transcript, queueIndexing: queueIndexing)
        return transcript
    }

    /// Uses the saved text checkpoint. Retrying this stage never runs Whisper again.
    func recognizeSpeakers(
        callID: CallID,
        audioDirectory: URL,
        using diarizer: Diarizer?,
        speakerStore: SpeakerStore?,
        revisionManager: TranscriptRevisionManager,
        policy: SpeakerMatchPolicy = .default,
        cancellation: ProcessCancellation? = nil
    ) async throws {
        guard let record = try await store.transcript(for: callID) else {
            throw SpeakerReviewError.transcriptUnavailable
        }
        let document = try JSONDecoder().decode(
            NormalizedTranscript.self, from: Data(contentsOf: URL(filePath: record.jsonPath))
        )
        let remote = document.segments.filter { $0.source != .microphone }
        guard !remote.isEmpty else { return }
        guard let diarizer else { throw DiarizerError.runtimeUnavailable }
        guard let speakerStore else { throw SpeakerReviewError.identityUnavailable }
        let source = audioDirectory.appending(
            path: remote.contains(where: { $0.source == .system }) ? "system.m4a" : "call.m4a"
        )
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw BackgroundProcessingError.audioUnavailable
        }
        let result = try await Task.detached {
            try diarizer.run(audio: source, ffmpeg: finalizer.ffmpeg, cancellation: cancellation)
        }.value
        guard !result.turns.isEmpty, !result.clusters.isEmpty else {
            throw DiarizerError.noSpeakersDetected
        }
        let identities = try await SpeakerIdentityAttributor(
            store: store, speakerStore: speakerStore,
            participants: try await store.listParticipants(), policy: policy
        ).resolve(callID: callID, diarization: result)
        let labelled = SegmentMerger.merge(whisperSegments: remote, diarization: result.turns)
        guard labelled.contains(where: { $0.speakerIndex != nil }) else {
            throw DiarizerError.noSpeakersDetected
        }
        let attributed = SourceTranscriptMerger.attributeSystem(
            WhisperTranscript(language: document.language, segments: labelled), identities: identities
        )
        let segments = (attributed.segments + document.segments.filter { $0.source == .microphone })
            .sorted { $0.startMs < $1.startMs }
        let participants = try await store.participants(for: callID)
        let updated = NormalizedTranscript(
            callId: document.callId, language: document.language, model: document.model,
            participants: participants.map {
                ParticipantMetadata(id: $0.id.rawValue.uuidString, name: $0.name)
            },
            glossary: document.glossary, segments: segments
        )
        let transcript = WhisperTranscript(language: document.language, segments: segments)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let revision = try revisionManager.replace(
            callID: callID,
            markdownURL: URL(filePath: record.markdownPath), jsonURL: URL(filePath: record.jsonPath),
            renderedMarkdown: TranscriptRenderer.markdown(
                transcript: transcript, participants: participants
            ),
            normalizedJSON: try encoder.encode(updated)
        )
        do {
            try await store.saveTranscript(
                TranscriptRecord(
                    callID: callID, language: record.language, model: record.model, text: transcript.text,
                    markdownPath: record.markdownPath, jsonPath: record.jsonPath
                ), queueIndexing: false)
        } catch {
            try revisionManager.restore(revision)
            throw error
        }
    }
}
