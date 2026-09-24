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

    @Test func whisperArgumentsKeepHardeningFlagsWithoutVad() {
        // The three hardening flags used to travel with the VAD block, so a run without a VAD model
        // carried the decoder's own context from chunk to chunk. The 2026-09-18 call holds the
        // result of that: "межми грешен" three times in one segment. They are part of the command
        // whether or not voice activity is configured.
        let arguments = WhisperCommand.arguments(
            model: URL(filePath: "/models/ggml-small.bin"),
            audio: URL(filePath: "/calls/input.wav"),
            outputBase: URL(filePath: "/calls/transcript.partial"),
            prompt: "",
            vadModel: nil
        )

        #expect(arguments.contains("--max-context"))
        #expect(arguments.contains("--no-fallback"))
        #expect(arguments.contains("--temperature"))
        #expect(!arguments.contains("--vad"))
    }

    @Test func whisperArgumentsCarryThePinnedLanguage() {
        // "auto" is the default and is what the app shipped with. A call that is in one language
        // with English product names in it is decoded better when the language is pinned, so the
        // choice the settings pane offers has to reach the command line.
        let pinned = WhisperCommand.arguments(
            model: URL(filePath: "/models/ggml-small.bin"),
            audio: URL(filePath: "/calls/input.wav"),
            outputBase: URL(filePath: "/calls/transcript.partial"),
            prompt: "",
            language: "ru"
        )
        let automatic = WhisperCommand.arguments(
            model: URL(filePath: "/models/ggml-small.bin"),
            audio: URL(filePath: "/calls/input.wav"),
            outputBase: URL(filePath: "/calls/transcript.partial"),
            prompt: ""
        )

        #expect(pinned.contains("ru"))
        #expect(pinned.firstIndex(of: "--language").map { pinned[$0 + 1] } == "ru")
        #expect(automatic.firstIndex(of: "--language").map { automatic[$0 + 1] } == "auto")
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

    @Test func rejectsAPhraseLoopInsideOneSegment() {
        func transcript(_ texts: [String]) -> WhisperTranscript {
            WhisperTranscript(
                language: "ru",
                segments: texts.enumerated().map { index, text in
                    TranscriptSegment(
                        startMs: index * 1000,
                        endMs: index * 1000 + 500,
                        text: text
                    )
                }
            )
        }

        // One segment holding the same two-word phrase three times. The cross-segment checks see a
        // single line and pass it; the 2026-09-18 call was saved with this shape in it.
        #expect(
            TranscriptQualityValidator.isRepetitive(
                transcript(["межми грешен межми грешен межми грешен"])
            )
        )

        // A sentence that uses the same two words twice is ordinary speech, and a phrase said twice
        // for emphasis is not a loop either.
        #expect(
            !TranscriptQualityValidator.isRepetitive(
                transcript(["я не знаю, что с этим заказом делать, если честно, не знаю."])
            )
        )
    }

    @Test func acceptsAPersonAgreeingSixTimesInOneLine() {
        func transcript(_ texts: [String]) -> WhisperTranscript {
            WhisperTranscript(
                language: "ru",
                segments: texts.enumerated().map { index, text in
                    TranscriptSegment(
                        startMs: index * 1000,
                        endMs: index * 1000 + 500,
                        text: text
                    )
                }
            )
        }

        // The 2026-09-23 call, verbatim. Six "да" in one line hold four overlapping three-word
        // runs, which the guard used to count as a loop and throw the whole 68 minute recording
        // away for -- twice, and the cleaning pass it judges for cannot remove copies that overlap.
        // The copies laid end to end are three pairs, under the floor.
        #expect(
            !TranscriptQualityValidator.isRepetitive(
                transcript([
                    "да да да да да да просто действительно столько стоит конечно лучше казаться они а может быть"
                ])
            )
        )

        // The same word, said by a model that cannot stop: eighteen of them are six pairs end to
        // end, which is most of the line, and the guard still refuses it.
        #expect(
            TranscriptQualityValidator.isRepetitive(
                transcript([Array(repeating: "да", count: 18).joined(separator: " ")])
            )
        )
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
