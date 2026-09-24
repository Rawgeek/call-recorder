import CallRecorderCore
import Foundation
import OSLog

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
        endedAt: Date,
        keepsAudio: Bool
    ) async throws -> URL {
        let tracks = try await finalizer.finalizeTracks(
            segments: segments,
            destination: destination
        )
        // The path the call is played from, and the one the rest of the app reads a call's audio by.
        //
        // A call whose audio is kept points at the mixed file, and the pipeline writes that file
        // once the transcript exists: mixing is a second encode of the whole call, and no stage of
        // the pipeline reads it — the transcriber reads the two sides apart. A call whose audio is
        // removed after the transcript points at a side that is on disk right now, so nothing waits
        // for a file that the next stage moves to Recently Deleted.
        let audio =
            keepsAudio
            ? destination.appending(path: "call.m4a")
            : (tracks.system ?? tracks.microphone ?? destination.appending(path: "system.m4a"))
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
        modelFile: URL?,
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
        localParticipantID: ParticipantID? = nil,
        usesParticipantCount: Bool = true,
        speakerCountOverride: Int? = nil,
        timestamps: Bool = false,
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
        // A system track that was written and held no sound is not a side to separate, and it can
        // still leave a fragment of noise behind: the 2026-09-22 13:44 call holds one period at 104
        // seconds. A separation over it finds a single voice whose centroid comes back empty, which
        // ended the pass on that call six times and left a transcribed call that could never be
        // finished. A fragment too short to hold a turn of its own carries no voice to name, and the
        // call already carries the one voice that spoke.
        if SystemAudioCheck.state(in: audioDirectory) == .missing,
            !remote.contains(where: SegmentMerger.runsLongEnoughForATurn) {
            return
        }
        guard let diarizer else { throw DiarizerError.runtimeUnavailable }
        guard let speakerStore else { throw SpeakerReviewError.identityUnavailable }
        let source = audioDirectory.appending(
            path: remote.contains(where: { $0.source == .system }) ? "system.m4a" : "call.m4a"
        )
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw BackgroundProcessingError.audioUnavailable
        }
        // A count chosen for this call wins over one the list suggests, and the list is only used
        // when the recording held room for that many voices. See DiarizationSpeakerCount. A count
        // is answered exactly, by the slower of the two separations, so a call with no count is
        // separated by the detector that counts the voices it hears.
        let speakers: Int?
        if let speakerCountOverride {
            speakers = speakerCountOverride
        } else {
            let people = try await store.participants(for: callID)
            speakers = DiarizationSpeakerCount.expected(
                participants: people.map(\.id),
                localParticipant: localParticipantID,
                recordingSeconds: Self.recordingSeconds(of: document),
                usesParticipantCount: usesParticipantCount
            )
        }
        let detected = try await Task.detached {
            try diarizer.run(
                audio: source,
                ffmpeg: finalizer.ffmpeg,
                numberOfSpeakers: speakers,
                cancellation: cancellation
            )
        }.value
        // A separation that answers no voice is an answer, not a fault. The words of the call are
        // already transcribed, and a track that holds almost no speech has no voice to name: the
        // 2026-09-24 11:13 call is seventeen seconds of a system track holding one short sound,
        // which the count-aware separation answered with no voice at all, and this stage failed the
        // call for that answer. A separation that breaks still throws, because a script that failed
        // and a script that found nothing are different answers.
        guard !detected.turns.isEmpty, !detected.clusters.isEmpty else {
            Logger(subsystem: "local.callrecorder.app", category: "speaker-identity")
                .notice("no voice found on \(callID.rawValue.uuidString, privacy: .public)")
            return
        }
        // A voice the pipeline could not embed comes back with its turns and no centroid. It keeps
        // its place in the transcript and can be named by hand. The count is logged because a
        // missing centroid is otherwise invisible: the voice is simply never matched to a person,
        // and the 2026-09-22 13:44 call was stuck at this stage over exactly one such voice.
        let voicesWithoutCentroid = Set(detected.turns.map(\.speakerLabel))
            .subtracting(detected.clusters.map(\.speakerLabel))
        if !voicesWithoutCentroid.isEmpty {
            Logger(subsystem: "local.callrecorder.app", category: "speaker-identity")
                .notice(
                    """
                    \(voicesWithoutCentroid.count, privacy: .public) voice(s) came back with no \
                    centroid and can only be named by hand
                    """
                )
        }
        // A voice can come back in pieces: the 2026-09-18 17:47 call has one speaker separated into
        // two clusters of a hundred and fifty seconds each next to a cluster of twelve minutes of
        // somebody else. Joining the pieces before anything is named is what stops the review window
        // offering two people where there is one, and the transcript drawing two names for one voice.
        let joined = DiarizationVoiceMerge.mergingSplitVoices(detected, policy: policy)
        if joined.mergedClusters > 0 {
            Logger(subsystem: "local.callrecorder.app", category: "speaker-identity")
                .notice(
                    """
                    joined \(joined.mergedClusters, privacy: .public) voice fragments that sound like one person
                    """
                )
        }
        let result = joined.result
        let identities = try await SpeakerIdentityAttributor(
            store: store, speakerStore: speakerStore,
            participants: try await store.listParticipants(), policy: policy
        ).resolve(callID: callID, diarization: result)
        // Label the segments with the turn-continuity rules, and say what they changed. The counts
        // are the evidence a later reading of a bad call needs: a merge that reports 257 label
        // changes in 277 turns is one whose input was the problem, and one that reports a low number
        // after the same input is the fix working.
        let merged = SegmentMerger.merging(whisperSegments: remote, diarization: result.turns)
        Logger(subsystem: "local.callrecorder.app", category: "speaker-identity")
            .notice(
                """
                speaker merge: \(merged.labelChanges, privacy: .public) label changes, \
                \(merged.snappedSegments, privacy: .public) short fragments held to the voice \
                before them, \(merged.absorbedRuns, privacy: .public) short runs absorbed
                """
            )
        let labelled = merged.segments
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
                transcript: transcript, participants: participants, timestamps: timestamps
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

    /// How long the recording runs, read from the text it produced.
    ///
    /// The last segment ends where the speech ended, which is the measure the speaker count needs: a
    /// call that ran for ten minutes of silence holds no more voices than the minute somebody spoke
    /// in. The audio is not read again to answer this.
    static func recordingSeconds(of document: NormalizedTranscript) -> Double {
        Double(document.segments.map(\.endMs).max() ?? 0) / 1000
    }
}
