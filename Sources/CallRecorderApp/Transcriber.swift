import CallRecorderCore
import Foundation
import OSLog

enum TranscriberError: LocalizedError {
    case outputAlreadyExists
    case repetitiveTranscript
    case engineUnavailable

    var errorDescription: String? {
        switch self {
        case .outputAlreadyExists:
            "Transcript files already exist for this recording."
        case .repetitiveTranscript:
            "The transcript looks repetitive and was not saved."
        case .engineUnavailable:
            "The speech runtime or the model it reads with is not installed. "
                + "Install both in Settings, Models, Speech."
        }
    }
}

struct Transcriber: Sendable {
    /// The language to hold the decoder to, or "auto" to let it read the language as it goes.
    let language: String
    /// Whether the markdown this run writes prints the time each turn started.
    let includeTimestamps: Bool
    /// Set when this run may be stopped from the surface. Nil for a run nobody can stop.
    let cancellation: ProcessCancellation?
    /// The reader that turns a track into words. Kept across calls, so the same environment and
    /// model are used for every track of a call.
    let engine: (any SpeechReading)?

    init(
        language: String = "auto",
        includeTimestamps: Bool = false,
        cancellation: ProcessCancellation? = nil,
        engine: (any SpeechReading)? = nil
    ) {
        self.language = language
        self.includeTimestamps = includeTimestamps
        self.cancellation = cancellation
        self.engine = engine
    }

    func transcribe(
        callID: CallID,
        audio: URL,
        modelID: String,
        participants: [Participant],
        glossary: [GlossaryTerm],
        directory: URL,
        localParticipant: Participant? = nil
    ) async throws -> TranscriptRecord {
        try await Task.detached {
            try await transcribeSynchronously(
                callID: callID, audio: audio, modelID: modelID,
                participants: participants, glossary: glossary,
                directory: directory,
                localParticipant: localParticipant,
                cancellation: cancellation
            )
        }.value
    }

    private func transcribeSynchronously(
        callID: CallID,
        audio: URL,
        modelID: String,
        participants: [Participant],
        glossary: [GlossaryTerm],
        directory: URL,
        localParticipant: Participant?,
        cancellation: ProcessCancellation?
    ) async throws -> TranscriptRecord {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let markdownURL = directory.appending(path: "transcript.md")
        let jsonURL = directory.appending(path: "transcript.json")
        let markdownExists = FileManager.default.fileExists(atPath: markdownURL.path)
        let jsonExists = FileManager.default.fileExists(atPath: jsonURL.path)
        if markdownExists, jsonExists {
            let existing = try JSONDecoder().decode(
                NormalizedTranscript.self,
                from: Data(contentsOf: jsonURL)
            )
            guard existing.callId.caseInsensitiveCompare(callID.rawValue.uuidString) == .orderedSame else {
                throw TranscriberError.outputAlreadyExists
            }
            return TranscriptRecord(
                callID: callID,
                language: existing.language,
                model: existing.model,
                text: existing.segments.map(\.text).joined(separator: "\n"),
                markdownPath: markdownURL.path,
                jsonPath: jsonURL.path
            )
        }
        guard !markdownExists, !jsonExists else { throw TranscriberError.outputAlreadyExists }

        var allParticipants = participants
        for participant in [localParticipant].compactMap({ $0 })
        where !allParticipants.contains(where: { $0.id == participant.id }) {
            allParticipants.append(participant)
        }
        let token = UUID().uuidString
        let markdownPartial = directory.appending(path: ".transcript-\(token).partial.md")
        let jsonPartial = directory.appending(path: ".transcript-\(token).partial.json")
        defer {
            [markdownPartial, jsonPartial].forEach {
                try? FileManager.default.removeItem(at: $0)
            }
        }

        var transcript: SpeechTranscript
        // The names and terms worth spelling right, in the order the vocabulary pane ranks them.
        // The model takes them as a list rather than as a prompt, so a long call keeps the people
        // on it and the words the app was told about, and everything else is read from the audio.
        let hotwords = PromptBuilder.hotwords(
            participants: allParticipants,
            glossary: glossary
        )
        let systemURL = directory.appending(path: "system.m4a")
        let microphoneURL = directory.appending(path: "microphone.m4a")
        let hasSystem = FileManager.default.fileExists(atPath: systemURL.path)
        let hasMicrophone = FileManager.default.fileExists(atPath: microphoneURL.path)
        if hasSystem || hasMicrophone {
            let system = try hasSystem
                ? await readTrack(audio: systemURL, hotwords: hotwords, cancellation: cancellation)
                : nil
            let microphone = try hasMicrophone
                ? await readTrack(audio: microphoneURL, hotwords: hotwords, cancellation: cancellation)
                : nil
            transcript = SourceTranscriptMerger.merge(
                microphone: microphone,
                system: system,
                localParticipant: localParticipant
            )
        } else {
            transcript = try await readTrack(
                audio: audio,
                hotwords: hotwords,
                cancellation: cancellation
            )
        }

        // Rewrite the misspellings the glossary knows about before anything is written. The
        // saved file, the search index built from it, and every later reading of the call then
        // share one spelling, which is what makes a keyword search for a real name work.
        let outcome = transcript.applyingGlossary(terms: glossary)
        transcript = outcome.transcript
        if outcome.corrections > 0 {
            Logger(subsystem: "local.callrecorder.app", category: "transcription")
                .notice("glossary corrected \(outcome.corrections, privacy: .public) spellings")
        }

        // Then the spellings the model invented for a term the glossary declares but never aliased.
        // The declared pass can only reach a wrong spelling the user already wrote down; this one
        // reaches the ones the decoder made up, and says which it changed so the glossary pane can
        // be given the alias by hand if the reader disagrees with it.
        let invented = transcript.applyingSuggestedGlossary(terms: glossary)
        transcript = invented.transcript
        for suggestion in invented.suggestions {
            Logger(subsystem: "local.callrecorder.app", category: "transcription")
                .notice(
                    """
                    glossary read "\(suggestion.found, privacy: .public)" as "\(suggestion.preferred, privacy: .public)" (\(suggestion.count, privacy: .public)x in this call)
                    """
                )
        }

        // Put back the ticket numbers the decoder clipped or split in two. A work call is searched
        // by its keys, and "1867" or "182 86" cannot be searched for at all; the repair works only
        // against a key this same transcript writes out in full, so the file is the evidence.
        let tickets = TicketKeyRepair.repairing(segments: transcript.segments)
        if tickets.repairs > 0 {
            transcript = SpeechTranscript(language: transcript.language, segments: tickets.segments)
            Logger(subsystem: "local.callrecorder.app", category: "transcription")
                .notice("wrote back \(tickets.repairs, privacy: .public) ticket numbers in full")
        }

        // Take out what the model wrote but nobody said, before judging whether the rest is usable.
        //
        // Both halves of this matter. A prompt echo and a bracketed marker are not speech, and
        // leaving them in costs the search index a chunk and every later reading of the call a
        // line. And the repetition guard below rejects a whole recording, so a call that the model
        // filled with a loop used to be thrown away even though the conversation in it was intact.
        // Removing the artefacts first is what lets the guard judge the speech that is left.
        let artifacts = TranscriptArtifacts.filter(segments: transcript.segments)
        if artifacts.outcome.didChange {
            transcript = SpeechTranscript(
                language: transcript.language,
                segments: artifacts.segments
            )
            Logger(subsystem: "local.callrecorder.app", category: "transcription")
                .notice(
                    "removed \(artifacts.outcome.removedLines, privacy: .public) lines that were not speech"
                )
        }

        // Then the speech the recorder wrote down twice.
        //
        // The tracks overlap and the microphone hears the speakers, so a sentence can arrive at the
        // model more than once. Both copies were transcribed, and both were kept, which is how one
        // call in the library came to hold 473 repeated runs. Removing them here means the file
        // that is saved, the text the search index is built from, and every later reading of the
        // call are the same words once.
        let duplicates = TranscriptDeduplicator.deduplicate(segments: transcript.segments)
        if duplicates.didChange {
            transcript = SpeechTranscript(
                language: transcript.language,
                segments: duplicates.segments
            )
            Logger(subsystem: "local.callrecorder.app", category: "transcription")
                .notice(
                    "removed \(duplicates.removedWords, privacy: .public) repeated words in \(duplicates.removedRuns, privacy: .public) runs"
                )
        }

        guard !TranscriptQualityValidator.isRepetitive(transcript) else {
            throw TranscriberError.repetitiveTranscript
        }

        let document = NormalizedTranscript(
            callId: callID.rawValue.uuidString,
            language: transcript.language,
            model: modelID,
            participants: allParticipants.map {
                .init(id: $0.id.rawValue.uuidString, name: $0.name)
            },
            glossary: glossary.map {
                .init(id: $0.id.rawValue.uuidString, preferred: $0.preferred, aliases: $0.aliases)
            },
            segments: transcript.segments
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(document).write(to: jsonPartial)
        try Data(
            TranscriptRenderer.markdown(
                transcript: transcript,
                participants: allParticipants,
                timestamps: includeTimestamps
            ).utf8
        ).write(to: markdownPartial)

        try FileManager.default.moveItem(at: jsonPartial, to: jsonURL)
        do {
            try FileManager.default.moveItem(at: markdownPartial, to: markdownURL)
        } catch {
            try? FileManager.default.removeItem(at: jsonURL)
            throw error
        }
        return TranscriptRecord(
            callID: callID,
            language: transcript.language,
            model: modelID,
            text: transcript.text,
            markdownPath: markdownURL.path,
            jsonPath: jsonURL.path
        )
    }

    /// Reads one track with the speech model.
    ///
    /// A stop asked for before the read is honoured, and a reading that turns out to be a loop is
    /// refused before anything is written.
    private func readTrack(
        audio: URL,
        hotwords: [String],
        cancellation: ProcessCancellation?
    ) async throws -> SpeechTranscript {
        guard let engine else { throw TranscriberError.engineUnavailable }
        try cancellation?.checkCancelled()
        let transcript = try await engine.transcribe(
            audio: audio,
            language: language,
            hotwords: hotwords,
            cancellation: cancellation
        )
        try cancellation?.checkCancelled()
        guard !TranscriptQualityValidator.isRepetitive(transcript) else {
            throw TranscriberError.repetitiveTranscript
        }
        return transcript
    }
}

struct NormalizedTranscript: Codable, Sendable {
    let callId: String
    let language: String
    let model: String
    let participants: [ParticipantMetadata]
    let glossary: [GlossaryMetadata]
    let segments: [TranscriptSegment]

    var needsSpeakerDetection: Bool {
        // A fragment too short to hold a turn of its own is not a word waiting for a voice. A
        // separation passes such a fragment by and leaves it where it is, so counting it asked for
        // work that could only be given up: the 2026-09-22 13:44 call holds one, a period from a
        // system track that was written and held no sound, and it kept the call in the review list
        // after the separation had already reported that there was no voice to find.
        let remote = segments.filter {
            $0.source != .microphone && SegmentMerger.runsLongEnoughForATurn($0)
        }
        return !remote.isEmpty && remote.allSatisfy { $0.speakerIndex == nil }
    }
}

struct ParticipantMetadata: Codable, Sendable {
    let id: String
    let name: String
}

struct GlossaryMetadata: Codable, Sendable {
    let id: String
    let preferred: String
    let aliases: [String]
}
