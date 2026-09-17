import Foundation
import Testing
@testable import CallRecorderCore

struct TranscriptionBoundaryTests {
    @Test func whisperArgumentsIncludeVerifiedVadAndHardeningFlags() {
        // Given
        let prompt = "Participants: Alice; rm -rf / — Иван."
        let vadModel = URL(filePath: "/models/vad/ggml-silero-v6.2.0.bin")

        // When
        let arguments = WhisperCommand.arguments(
            model: URL(filePath: "/models/ggml-small.bin"),
            audio: URL(filePath: "/calls/input.wav"),
            outputBase: URL(filePath: "/calls/transcript.partial"),
            prompt: prompt,
            vadModel: vadModel
        )

        // Then
        #expect(arguments == [
            "--model", "/models/ggml-small.bin",
            "--file", "/calls/input.wav",
            "--language", "auto",
            "--output-json",
            "--output-file", "/calls/transcript.partial",
            "--vad",
            "--vad-model", "/models/vad/ggml-silero-v6.2.0.bin",
            "--vad-max-speech-duration-s", "300",
            "--max-context", "0",
            "--no-fallback",
            "--temperature", "0",
            "--prompt", prompt,
            "--no-prints",
        ])
    }

    @Test func parsesCurrentWhisperJSONAcrossLanguages() throws {
        // Given
        let json = """
            {
              "result": { "language": "ru" },
              "transcription": [
                {
                  "timestamps": { "from": "00:00:00,000", "to": "00:00:01,000" },
                  "offsets": { "from": 0, "to": 1000 },
                  "text": " Привет, Alice. "
                }
              ]
            }
            """

        // When
        let document = try WhisperTranscriptParser.parse(Data(json.utf8))

        // Then
        #expect(document.language == "ru")
        #expect(document.text == "Привет, Alice.")
        #expect(document.segments == [
            TranscriptSegment(startMs: 0, endMs: 1000, text: "Привет, Alice.")
        ])
    }
}

@Suite("Transcript quality")
struct TranscriptQualityValidatorTests {
    @Test func rejectsRepetitionButAcceptsNormalShortConversation() {
        func transcript(_ texts: [String]) -> WhisperTranscript {
            WhisperTranscript(
                language: "en",
                segments: texts.enumerated().map { index, text in
                    TranscriptSegment(
                        startMs: index * 1000,
                        endMs: index * 1000 + 500,
                        text: text
                    )
                }
            )
        }

        var repeated = Array(repeating: "Thank you.", count: 25)
        repeated += (0..<75).map { "Topic \($0)." }
        #expect(TranscriptQualityValidator.isRepetitive(transcript(repeated)))

        let identicalRun = Array(repeating: "Um", count: 12)
            + (0..<20).map { "Sentence \($0)." }
        #expect(TranscriptQualityValidator.isRepetitive(transcript(identicalRun)))

        let singleTokens = (0..<15).map { "token\($0)" }
            + (0..<20).map { "Full sentence \($0)." }
        #expect(TranscriptQualityValidator.isRepetitive(transcript(singleTokens)))

        let normal = [
            "yes", "ok", "ok", "right", "hmm", "go on", "no problem",
            "yes", "ok", "sure", "maybe", "I agree", "let me check",
            "all right", "ok", "thanks",
        ]
        #expect(!TranscriptQualityValidator.isRepetitive(transcript(normal)))
    }
}

@Suite("Source transcript merger")
struct SourceTranscriptMergerTests {
    @Test("local microphone is named and interleaved with system speakers")
    func labelsLocalMicrophone() throws {
        let sam = Participant(
            id: ParticipantID(rawValue: UUID()),
            name: "Sam"
        )
        let microphone = WhisperTranscript(
            language: "en",
            segments: [TranscriptSegment(startMs: 100, endMs: 300, text: "Hello")]
        )
        let system = WhisperTranscript(
            language: "en",
            segments: [
                TranscriptSegment(startMs: 400, endMs: 700, text: "Hi", speakerIndex: 0),
            ]
        )

        let merged = SourceTranscriptMerger.merge(
            microphone: microphone,
            system: system,
            localParticipant: sam
        )

        #expect(merged.segments.map(\.text) == ["Hello", "Hi"])
        #expect(merged.segments[0].source == .microphone)
        #expect(merged.segments[0].participantID == sam.id)
        #expect(merged.segments[0].speakerName == "Sam")
        #expect(merged.segments[1].source == .system)
        #expect(merged.segments[1].speakerIndex == 0)
    }

    @Test("old transcript segments decode without source metadata")
    func decodesLegacySegment() throws {
        let data = Data(#"{"startMs":0,"endMs":1000,"text":"Hello","speakerIndex":0}"#.utf8)

        let segment = try JSONDecoder().decode(TranscriptSegment.self, from: data)

        #expect(segment.source == nil)
        #expect(segment.participantID == nil)
        #expect(segment.speakerName == nil)
    }

    @Test("only safe identities replace anonymous system speakers")
    func attributesSafeSystemIdentity() {
        let dana = Participant(id: ParticipantID(rawValue: UUID()), name: "Dana")
        let transcript = WhisperTranscript(
            language: "en",
            segments: [
                TranscriptSegment(startMs: 0, endMs: 500, text: "Hello", speakerIndex: 0),
                TranscriptSegment(startMs: 500, endMs: 1_000, text: "Hi", speakerIndex: 1),
            ]
        )

        let attributed = SourceTranscriptMerger.attributeSystem(
            transcript,
            identities: [1: dana]
        )

        #expect(attributed.segments[0].speakerName == nil)
        #expect(attributed.segments[0].speakerIndex == 0)
        #expect(attributed.segments[1].speakerName == "Dana")
        #expect(attributed.segments[1].participantID == dana.id)
    }
}
