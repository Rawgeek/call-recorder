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
        _ transcript: SpeechTranscript,
        identities: [Int: Participant]
    ) -> SpeechTranscript {
        SpeechTranscript(
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
        microphone: SpeechTranscript?,
        system: SpeechTranscript?,
        localParticipant: Participant?
    ) -> SpeechTranscript {
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
        return SpeechTranscript(
            language: system?.language ?? microphone?.language ?? "unknown",
            segments: segments
        )
    }
}

public struct SpeechTranscript: Codable, Equatable, Sendable {
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
    ) -> (transcript: SpeechTranscript, corrections: Int) {
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
        return (SpeechTranscript(language: language, segments: correctedSegments), total)
    }

    /// Convenience for a single transcript. Prefer passing a prepared matcher when correcting
    /// more than one, because preparing a glossary costs more than using it.
    public func applyingGlossary(
        terms: [GlossaryTerm]
    ) -> (transcript: SpeechTranscript, corrections: Int) {
        let exact = applyingGlossary(GlossaryCorrector.matcher(for: terms))
        let invented = exact.transcript.applyingSuggestedGlossary(terms: terms)
        return (invented.transcript, exact.corrections + invented.corrections)
    }

    /// Rewrites the spellings the model invented for terms the glossary declares.
    ///
    /// The declared aliases above only reach a spelling the user already wrote down. A term the user
    /// added to the glossary but never aliased arrives from the decoder as what it sounded like --
    /// "салют" for Salla, "биспер" for Whisper, "карт-ровер" for CartRover -- and the file keeps it.
    /// This pass reads the whole call for what its words are and how often each comes back, then
    /// writes the corrections segment by segment, so timing and speaker labels are untouched.
    public func applyingSuggestedGlossary(
        terms: [GlossaryTerm]
    ) -> (
        transcript: SpeechTranscript,
        corrections: Int,
        suggestions: [GlossaryCorrector.Suggestion]
    ) {
        guard !terms.isEmpty else { return (self, 0, []) }
        let suggestions = GlossaryCorrector.suggestedAliases(in: text, terms: terms)
        guard !suggestions.isEmpty else { return (self, 0, []) }
        // Longest first, so a longer invented spelling is replaced before a shorter one that starts
        // the same way can cut into it.
        let ordered = suggestions.sorted { $0.found.count > $1.found.count }
        var correctedSegments: [TranscriptSegment] = []
        correctedSegments.reserveCapacity(segments.count)
        var total = 0
        for segment in segments {
            var output = segment.text
            var replaced = 0
            for suggestion in ordered {
                let occurrences = GlossaryCorrector.words(in: output)
                    .filter { $0.lowercased() == suggestion.found.lowercased() }
                    .count
                guard occurrences > 0 else { continue }
                output = GlossaryCorrector.replacing(
                    suggestion.found,
                    with: suggestion.preferred,
                    in: output
                )
                replaced += occurrences
            }
            guard replaced > 0 else {
                correctedSegments.append(segment)
                continue
            }
            total += replaced
            correctedSegments.append(
                TranscriptSegment(
                    startMs: segment.startMs,
                    endMs: segment.endMs,
                    text: output,
                    speakerIndex: segment.speakerIndex,
                    source: segment.source,
                    participantID: segment.participantID,
                    speakerName: segment.speakerName
                )
            )
        }
        return (
            SpeechTranscript(language: language, segments: correctedSegments),
            total,
            suggestions
        )
    }
}

public enum TranscriptQualityValidator {
    /// Rejects transcripts dominated by a repeated phrase, a long identical run,
    /// or a long run of single tokens. Ignores empty/non-speech markers.
    public static func isRepetitive(_ transcript: SpeechTranscript) -> Bool {
        let phrases = transcript.segments
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter {
                !$0.isEmpty
                    && !($0.hasPrefix("[") && $0.hasSuffix("]"))
            }
        // A phrase loop inside one line is asked about before the cross-segment floor below: one
        // stuck line is a fault whether the recording holds three lines or three thousand, and the
        // 2026-09-18 call has one line that repeats "межми грешен" three times. The share is half
        // the line, stricter than the cleaning pass uses, because this answer throws the whole
        // recording away while the cleaning pass only shortens the line.
        for phrase in phrases {
            let words = phrase.split(separator: " ").map(String.init)
            if TranscriptArtifacts.repeatedPhrase(in: words, minimumShare: 0.5) != nil {
                return true
            }
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
