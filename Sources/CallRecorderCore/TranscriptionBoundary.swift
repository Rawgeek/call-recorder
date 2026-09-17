import Foundation

public enum TranscriptAudioSource: String, Codable, Equatable, Sendable {
    case system
    case microphone
}

public struct TranscriptSegment: Codable, Equatable, Sendable {
    public let startMs: Int
    public let endMs: Int
    public let text: String
    public let speakerIndex: Int?
    public let source: TranscriptAudioSource?
    public let participantID: ParticipantID?
    public let speakerName: String?

    public init(
        startMs: Int,
        endMs: Int,
        text: String,
        speakerIndex: Int? = nil,
        source: TranscriptAudioSource? = nil,
        participantID: ParticipantID? = nil,
        speakerName: String? = nil
    ) {
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
        self.speakerIndex = speakerIndex
        self.source = source
        self.participantID = participantID
        self.speakerName = speakerName
    }
}

public enum SourceTranscriptMerger {
    public static func attributeSystem(
        _ transcript: WhisperTranscript,
        identities: [Int: Participant]
    ) -> WhisperTranscript {
        WhisperTranscript(
            language: transcript.language,
            segments: transcript.segments.map { segment in
                guard
                    let speakerIndex = segment.speakerIndex,
                    let participant = identities[speakerIndex]
                else { return segment }
                return TranscriptSegment(
                    startMs: segment.startMs,
                    endMs: segment.endMs,
                    text: segment.text,
                    speakerIndex: speakerIndex,
                    source: segment.source ?? .system,
                    participantID: participant.id,
                    speakerName: participant.name
                )
            }
        )
    }

    public static func merge(
        microphone: WhisperTranscript?,
        system: WhisperTranscript?,
        localParticipant: Participant?
    ) -> WhisperTranscript {
        let systemSegments = system?.segments.map { segment in
            TranscriptSegment(
                startMs: segment.startMs,
                endMs: segment.endMs,
                text: segment.text,
                speakerIndex: segment.speakerIndex,
                source: .system,
                participantID: segment.participantID,
                speakerName: segment.speakerName
            )
        } ?? []
        let localAnonymousIndex = (systemSegments.compactMap(\.speakerIndex).max() ?? -1) + 1
        let microphoneSegments = microphone?.segments.map { segment in
            TranscriptSegment(
                startMs: segment.startMs,
                endMs: segment.endMs,
                text: segment.text,
                speakerIndex: localParticipant == nil ? localAnonymousIndex : nil,
                source: .microphone,
                participantID: localParticipant?.id,
                speakerName: localParticipant?.name
            )
        } ?? []
        let segments = (systemSegments + microphoneSegments).sorted {
            if $0.startMs != $1.startMs { return $0.startMs < $1.startMs }
            if $0.endMs != $1.endMs { return $0.endMs < $1.endMs }
            return ($0.source?.rawValue ?? "") < ($1.source?.rawValue ?? "")
        }
        return WhisperTranscript(
            language: system?.language ?? microphone?.language ?? "unknown",
            segments: segments
        )
    }
}

public struct WhisperTranscript: Codable, Equatable, Sendable {
    public let language: String
    public let segments: [TranscriptSegment]

    public init(language: String, segments: [TranscriptSegment]) {
        self.language = language
        self.segments = segments
    }

    public var text: String {
        segments.map(\.text).joined(separator: "\n")
    }

    /// Rewrites the spellings the glossary says were misheard, in every segment.
    ///
    /// This runs on the text the model produced and before anything is written, so the saved
    /// transcript, the search index built from it, and every later reading of the call all agree
    /// on the spelling the user chose. Segment timing and speaker labels are untouched.
    public func applyingGlossary(
        _ matcher: GlossaryCorrector.Matcher
    ) -> (transcript: WhisperTranscript, corrections: Int) {
        guard !matcher.isEmpty else { return (self, 0) }
        var correctedSegments: [TranscriptSegment] = []
        correctedSegments.reserveCapacity(segments.count)
        var total = 0
        for segment in segments {
            let outcome = matcher.correct(segment.text)
            total += outcome.replacementCount
            guard outcome.didChange else {
                correctedSegments.append(segment)
                continue
            }
            correctedSegments.append(
                TranscriptSegment(
                    startMs: segment.startMs,
                    endMs: segment.endMs,
                    text: outcome.text,
                    speakerIndex: segment.speakerIndex,
                    source: segment.source,
                    participantID: segment.participantID,
                    speakerName: segment.speakerName
                )
            )
        }
        return (WhisperTranscript(language: language, segments: correctedSegments), total)
    }

    /// Convenience for a single transcript. Prefer passing a prepared matcher when correcting
    /// more than one, because preparing a glossary costs more than using it.
    public func applyingGlossary(
        terms: [GlossaryTerm]
    ) -> (transcript: WhisperTranscript, corrections: Int) {
        applyingGlossary(GlossaryCorrector.matcher(for: terms))
    }
}

public enum WhisperTranscriptError: Error {
    case invalidSegment
}

public enum WhisperTranscriptParser {
    public static func parse(_ data: Data) throws -> WhisperTranscript {
        let output = try JSONDecoder().decode(WhisperOutput.self, from: data)
        let segments = try output.transcription.compactMap { segment -> TranscriptSegment? in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            guard segment.offsets.from >= 0, segment.offsets.to >= segment.offsets.from else {
                throw WhisperTranscriptError.invalidSegment
            }
            return TranscriptSegment(
                startMs: segment.offsets.from,
                endMs: segment.offsets.to,
                text: text
            )
        }
        return WhisperTranscript(language: output.result.language, segments: segments)
    }
}

public enum WhisperCommand {
    public static func arguments(
        model: URL,
        audio: URL,
        outputBase: URL,
        prompt: String,
        vadModel: URL? = nil
    ) -> [String] {
        var arguments = [
            "--model", model.path,
            "--file", audio.path,
            "--language", "auto",
            "--output-json",
            "--output-file", outputBase.path,
        ]
        if let vadModel {
            arguments.append(contentsOf: [
                "--vad",
                "--vad-model", vadModel.path,
                "--vad-max-speech-duration-s", "300",
                "--max-context", "0",
                "--no-fallback",
                "--temperature", "0",
            ])
        }
        if !prompt.isEmpty {
            arguments.append(contentsOf: ["--prompt", prompt])
        }
        arguments.append("--no-prints")
        return arguments
    }
}

public enum TranscriptQualityValidator {
    /// Rejects transcripts dominated by a repeated phrase, a long identical run,
    /// or a long run of single tokens. Ignores empty/non-speech markers.
    public static func isRepetitive(_ transcript: WhisperTranscript) -> Bool {
        let phrases = transcript.segments
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter {
                !$0.isEmpty
                    && !($0.hasPrefix("[") && $0.hasSuffix("]"))
            }
        guard phrases.count >= 20 else { return false }
        let normalized = phrases.map { $0.lowercased() }
        var counts: [String: Int] = [:]
        for phrase in normalized {
            counts[phrase, default: 0] += 1
        }
        if let (_, count) = counts.max(by: { $0.value < $1.value }),
            count >= 20, Double(count) / Double(normalized.count) > 0.20 {
            return true
        }
        var identicalRun = 1
        var singleTokenRun = 0
        var previous: String?
        for phrase in normalized {
            if phrase == previous {
                identicalRun += 1
                if identicalRun > 10 { return true }
            } else {
                identicalRun = 1
            }
            if phrase.split(separator: " ").count == 1 {
                singleTokenRun += 1
                if singleTokenRun > 10 { return true }
            } else {
                singleTokenRun = 0
            }
            previous = phrase
        }
        return false
    }
}

private struct WhisperOutput: Decodable {
    let result: Result
    let transcription: [Segment]

    struct Result: Decodable {
        let language: String
    }

    struct Segment: Decodable {
        let offsets: Offsets
        let text: String
    }

    struct Offsets: Decodable {
        let from: Int
        let to: Int
    }
}
