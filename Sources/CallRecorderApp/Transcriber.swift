import CallRecorderCore
import Foundation
import OSLog

enum TranscriberError: LocalizedError {
    case outputAlreadyExists
    case missingWhisperOutput
    case vadModelUnavailable
    case repetitiveTranscript

    var errorDescription: String? {
        switch self {
        case .outputAlreadyExists:
            "Transcript files already exist for this recording."
        case .missingWhisperOutput:
            "Whisper did not create a transcript."
        case .vadModelUnavailable:
            "The Silero VAD model is not installed. Download it in Settings, Models, Components."
        case .repetitiveTranscript:
            "The transcript looks repetitive and was not saved."
        }
    }
}

struct Transcriber: Sendable {
    let ffmpeg: URL
    let whisperCLI: URL
    let vadModel: URL?
    /// Set when this run may be stopped from the surface. Nil for a run nobody can stop.
    let cancellation: ProcessCancellation?

    init(
        ffmpeg: URL,
        whisperCLI: URL,
        vadModel: URL? = nil,
        cancellation: ProcessCancellation? = nil
    ) {
        self.ffmpeg = ffmpeg
        self.whisperCLI = whisperCLI
        self.vadModel = vadModel
        self.cancellation = cancellation
    }

    /// The silence filter, at the revision the app last verified.
    ///
    /// The model is a download now, so the file is found the way any other downloaded model is:
    /// the manifest names the revision, and the bytes are checked before whisper.cpp is handed the
    /// path. A development checkout can still fall back to the copy in Resources, which is what a
    /// test run uses.
    ///
    /// - Parameter applicationDirectory: The folder models are installed into, or nil to look only
    ///   in the package.
    static func resolvedVADModel(applicationDirectory: URL? = nil) throws -> URL {
        if let applicationDirectory, let installed = installedVADModel(applicationDirectory: applicationDirectory) {
            return installed
        }
        // Development candidate: the executable lives in .build/<triple>/<config>,
        // so walking up four components from it reaches the package root. Computed
        // at runtime so the packaged binary never embeds the workspace path.
        let developmentRoot = Bundle.main.executableURL?
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        // A test run and a command-line pass run from the package, which is where the copy this
        // checkout carries is. The same two places the indexer looks in, for the same reason.
        let configuredRoot = ProcessInfo.processInfo.environment["CALL_RECORDER_SOURCE_ROOT"]
            .map { URL(filePath: $0, directoryHint: .isDirectory) }
        let sourceRoots = [configuredRoot, URL(filePath: FileManager.default.currentDirectoryPath)]
            .compactMap { $0 }
        let candidates: [URL?] = [
            Bundle.main.url(forResource: "ggml-silero-v6.2.0", withExtension: "bin"),
            developmentRoot?.appending(path: "Resources/ggml-silero-v6.2.0.bin"),
        ] + sourceRoots.map { $0.appending(path: "Resources/ggml-silero-v6.2.0.bin") }
        for candidate in candidates.compactMap({ $0 })
            where FileManager.default.fileExists(atPath: candidate.path) {
            if
                try ModelFileVerifier.verify(
                    fileAt: candidate,
                    expectedBytes: SupportingModel.sileroVADBytes,
                    sha256: SupportingModel.sileroVADSHA256
                )
            {
                return candidate
            }
        }
        throw TranscriberError.vadModelUnavailable
    }

    /// The installed copy, when the manifest names one and its bytes still match.
    static func installedVADModel(applicationDirectory: URL) -> URL? {
        guard
            let model = SupportingModel.catalog.first(where: { $0.id == SupportingModel.sileroVADID }),
            let file = model.files.first
        else { return nil }
        let manifest = SupportingModelManifest.load(
            from: SupportingModelManifest.defaultURL(in: applicationDirectory)
        )
        guard let record = manifest.record(for: model.id) else { return nil }
        let candidate = model
            .directory(in: applicationDirectory, revision: record.revision)
            .appending(path: file.path)
        guard
            (try? ModelFileVerifier.verify(
                fileAt: candidate,
                expectedBytes: file.bytes,
                sha256: file.sha256
            )) == true
        else { return nil }
        return candidate
    }

    func transcribe(
        callID: CallID,
        audio: URL,
        modelID: String,
        modelFile: URL,
        participants: [Participant],
        glossary: [GlossaryTerm],
        glossaryUsage: [String: Int] = [:],
        directory: URL,
        localParticipant: Participant? = nil
    ) async throws -> TranscriptRecord {
        try await Task.detached {
            try transcribeSynchronously(
                callID: callID, audio: audio, modelID: modelID, modelFile: modelFile,
                participants: participants, glossary: glossary, glossaryUsage: glossaryUsage,
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
        modelFile: URL,
        participants: [Participant],
        glossary: [GlossaryTerm],
        glossaryUsage: [String: Int],
        directory: URL,
        localParticipant: Participant?,
        cancellation: ProcessCancellation?
    ) throws -> TranscriptRecord {
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

        var transcript: WhisperTranscript
        let systemURL = directory.appending(path: "system.m4a")
        let microphoneURL = directory.appending(path: "microphone.m4a")
        let hasSystem = FileManager.default.fileExists(atPath: systemURL.path)
        let hasMicrophone = FileManager.default.fileExists(atPath: microphoneURL.path)
        if hasSystem || hasMicrophone {
            let system = try hasSystem
                ? transcribeSource(
                    audio: systemURL,
                    label: "system",
                    token: token,
                    modelFile: modelFile,
                    participants: allParticipants,
                    glossary: glossary,
                    glossaryUsage: glossaryUsage,
                    directory: directory,
                    sourceChunkDurationSeconds: 300,
                    cancellation: cancellation
                )
                : nil
            let microphone = try hasMicrophone
                ? transcribeSource(
                    audio: microphoneURL,
                    label: "microphone",
                    token: token,
                    modelFile: modelFile,
                    participants: allParticipants,
                    glossary: glossary,
                    glossaryUsage: glossaryUsage,
                    directory: directory,
                    sourceChunkDurationSeconds: 300,
                    cancellation: cancellation
                )
                : nil
            transcript = SourceTranscriptMerger.merge(
                microphone: microphone,
                system: system,
                localParticipant: localParticipant
            )
        } else {
            transcript = try transcribeSource(
                audio: audio,
                label: "mixed",
                token: token,
                modelFile: modelFile,
                participants: allParticipants,
                glossary: glossary,
                glossaryUsage: glossaryUsage,
                directory: directory,
                sourceChunkDurationSeconds: 300,
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

        // Take out what the model wrote but nobody said, before judging whether the rest is usable.
        //
        // Both halves of this matter. A prompt echo and a bracketed marker are not speech, and
        // leaving them in costs the search index a chunk and every later reading of the call a
        // line. And the repetition guard below rejects a whole recording, so a call that the model
        // filled with a loop used to be thrown away even though the conversation in it was intact.
        // Removing the artefacts first is what lets the guard judge the speech that is left.
        let artifacts = TranscriptArtifacts.filter(segments: transcript.segments)
        if artifacts.outcome.didChange {
            transcript = WhisperTranscript(
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
        // The chunks overlap and the microphone hears the speakers, so a sentence can arrive at the
        // model more than once. Both copies were transcribed, and both were kept, which is how one
        // call in the library came to hold 473 repeated runs. Removing them here means the file
        // that is saved, the text the search index is built from, and every later reading of the
        // call are the same words once.
        let duplicates = TranscriptDeduplicator.deduplicate(segments: transcript.segments)
        if duplicates.didChange {
            transcript = WhisperTranscript(
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
                participants: allParticipants
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

    private func transcribeSource(
        audio: URL,
        label: String,
        token: String,
        modelFile: URL,
        participants: [Participant],
        glossary: [GlossaryTerm],
        glossaryUsage: [String: Int] = [:],
        directory: URL,
        sourceChunkDurationSeconds: Int,
        cancellation: ProcessCancellation? = nil
    ) throws -> WhisperTranscript {
        let waveURL = directory.appending(path: ".transcribing-\(label)-\(token).wav")
        defer {
            try? FileManager.default.removeItem(at: waveURL)
        }
        _ = try ProcessRunner.runChecked(
            executable: ffmpeg,
            arguments: [
                "-v", "error", "-y", "-i", audio.path,
                "-vn", "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", waveURL.path,
            ],
            cancellation: cancellation
        )
        let vadModel = try self.vadModel ?? Self.resolvedVADModel()
        let chunkDirectory = directory.appending(
            path: ".transcribing-\(label)-\(token)-chunks",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: chunkDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: chunkDirectory) }
        _ = try ProcessRunner.runChecked(
            executable: ffmpeg,
            arguments: [
                "-v", "error", "-y", "-i", waveURL.path,
                "-f", "segment",
                "-segment_time", "\(sourceChunkDurationSeconds)",
                "-c", "copy",
                chunkDirectory.appending(path: "chunk-%03d.wav").path,
            ],
            cancellation: cancellation
        )
        let chunkURLs = try FileManager.default.contentsOfDirectory(
            at: chunkDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "wav" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !chunkURLs.isEmpty else { throw TranscriberError.missingWhisperOutput }
        var chunks: [WhisperTranscript] = []
        for (index, chunkURL) in chunkURLs.enumerated() {
            // Asked once per chunk, so a stop does not start the next one only to end it.
            try cancellation?.checkCancelled()
            let chunkBase = chunkURL.deletingPathExtension()
            let chunkJSON = URL(filePath: chunkBase.path + ".json")
            _ = try ProcessRunner.runChecked(
                executable: whisperCLI,
                arguments: WhisperCommand.arguments(
                    model: modelFile,
                    audio: chunkURL,
                    outputBase: chunkBase,
                    prompt: PromptBuilder.whisperContext(
                        participants: participants,
                        glossary: glossary,
                        usageCounts: glossaryUsage
                    ),
                    vadModel: vadModel
                ),
                cancellation: cancellation
            )
            guard FileManager.default.fileExists(atPath: chunkJSON.path) else {
                throw TranscriberError.missingWhisperOutput
            }
            var raw = try WhisperTranscriptParser.parse(Data(contentsOf: chunkJSON))
            let offset = index * sourceChunkDurationSeconds * 1000
            raw = WhisperTranscript(
                language: raw.language,
                segments: raw.segments.map {
                    TranscriptSegment(
                        startMs: $0.startMs + offset,
                        endMs: $0.endMs + offset,
                        text: $0.text
                    )
                }
            )
            guard !TranscriptQualityValidator.isRepetitive(raw) else {
                throw TranscriberError.repetitiveTranscript
            }
            chunks.append(raw)
        }
        let combined = WhisperTranscript(
            language: chunks.first?.language ?? "unknown",
            segments: chunks.flatMap(\.segments)
        )
        return combined
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
        let remote = segments.filter { $0.source != .microphone }
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
