import CallRecorderCore
import Foundation
import Testing
@testable import CallRecorderApp

@Suite("Transcriber")
struct TranscriberTests {
    @Test("a finalized call stores participants and normalized transcript files", .enabled(if: TestEnvironment.hasFFmpeg), .enabled(if: TestEnvironment.hasBundledVADModel))
    func completesLocalCallPipeline() async throws {
        // Given
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "call-recorder-transcriber-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ffmpeg = URL(filePath: "/opt/homebrew/bin/ffmpeg")
        let segmentURL = directory.appending(path: "segment-001.mp4")
        let generated = try ProcessRunner.run(
            executable: ffmpeg,
            arguments: [
                "-v", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=0.2",
                "-c:a", "aac", segmentURL.path,
            ]
        )
        #expect(generated.exitCode == 0)
        let fakeWhisper = try makeFakeWhisper(in: directory)
        let model = directory.appending(path: "ggml-small.bin")
        try Data().write(to: model)
        let callID = CallID(rawValue: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!)
        let participant = Participant(
            id: ParticipantID(rawValue: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!),
            name: "Alice"
        )
        let term = GlossaryTerm(
            id: GlossaryTermID(rawValue: UUID(uuidString: "99999999-8888-7777-6666-555555555555")!),
            preferred: "Turso",
            aliases: ["Torso"]
        )
        let store = try CallStore(path: directory.appending(path: "calls.db").path)
        let pipeline = CallPipeline(
            store: store,
            finalizer: MediaFinalizer(
                ffmpeg: ffmpeg,
                ffprobe: URL(filePath: "/opt/homebrew/bin/ffprobe")
            )
        )

        // When
        try await pipeline.start(callID: callID, startedAt: Date(timeIntervalSince1970: 1_800_000_000))
        let savedParticipant = try await store.upsertParticipant(name: participant.name)
        let audio = try await pipeline.finalize(
            callID: callID,
            segments: [CaptureSegment(index: 1, fileURL: segmentURL)],
            destination: directory,
            endedAt: Date(timeIntervalSince1970: 1_800_000_001)
        )
        let queuedAfterFinalize = try #require(try await store.processingJobs().first)
        let record = try await pipeline.transcribe(
            callID: callID,
            audio: audio,
            modelID: "small",
            modelFile: model,
            participantIDs: [savedParticipant.id],
            glossary: [term],
            directory: directory,
            using: Transcriber(ffmpeg: ffmpeg, whisperCLI: fakeWhisper)
        )
        try FileManager.default.removeItem(at: fakeWhisper)
        let resumed = try await Transcriber(
            ffmpeg: ffmpeg,
            whisperCLI: fakeWhisper
        ).transcribe(
            callID: callID,
            audio: audio,
            modelID: "small",
            modelFile: model,
            participants: [savedParticipant],
            glossary: [term],
            directory: directory
        )

        // Then
        #expect(record.language == "ru")
        #expect(queuedAfterFinalize.stage == .queued)
        #expect(queuedAfterFinalize.executionState == .pending)
        #expect(record.model == "small")
        #expect(record.text == "Привет, Alice.")
        #expect(resumed == record)
        #expect(FileManager.default.fileExists(atPath: record.markdownPath))
        #expect(FileManager.default.fileExists(atPath: record.jsonPath))
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: URL(filePath: record.jsonPath)))
                as? [String: Any]
        )
        #expect(object["callId"] as? String == callID.rawValue.uuidString)
        #expect(object["language"] as? String == "ru")
        #expect((object["participants"] as? [[String: Any]])?.first?["name"] as? String == "Alice")
        #expect((object["segments"] as? [[String: Any]])?.first?["startMs"] as? Int == 0)
        #expect(try await store.participants(for: callID) == [savedParticipant])
        #expect(try await store.pendingIndexCallIDs() == [callID])
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).allSatisfy {
            !$0.hasSuffix(".wav")
        })
    }

    @Test("the glossary and the names are the prompt whisper is given", .enabled(if: TestEnvironment.hasFFmpeg), .enabled(if: TestEnvironment.hasBundledVADModel))
    func promptCarriesTheGlossaryToWhisper() async throws {
        // The prompt is the only place a term can change what the model hears, so the last link
        // in the chain is worth pinning: the builder can be right and the flag not be sent. This
        // reads the prompt back out of the arguments whisper-cli was started with.
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "call-recorder-prompt-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ffmpeg = URL(filePath: "/opt/homebrew/bin/ffmpeg")
        let audio = directory.appending(path: "call.m4a")
        _ = try ProcessRunner.runChecked(
            executable: ffmpeg,
            arguments: [
                "-v", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=0.2",
                "-c:a", "aac", audio.path,
            ]
        )
        let promptFile = directory.appending(path: "prompt.txt")
        let whisper = try makePromptRecordingFakeWhisper(in: directory, promptFile: promptFile)
        let model = directory.appending(path: "ggml-small.bin")
        try Data().write(to: model)
        let sam = Participant(id: ParticipantID(rawValue: UUID()), name: "Sam Rivers")
        let term = GlossaryTerm(
            id: GlossaryTermID(rawValue: UUID()),
            preferred: "Globex",
            aliases: ["Globexx"]
        )

        _ = try await Transcriber(ffmpeg: ffmpeg, whisperCLI: whisper).transcribe(
            callID: CallID(rawValue: UUID()),
            audio: audio,
            modelID: "small",
            modelFile: model,
            participants: [sam],
            glossary: [term],
            directory: directory
        )

        let prompt = try String(contentsOf: promptFile, encoding: .utf8)
        #expect(prompt.contains("Sam Rivers"))
        #expect(prompt.contains("Globex"))
        // The wrong spelling is what the glossary exists to prevent, so it is not sent.
        #expect(!prompt.contains("Globexx"))
    }

    @Test("independent sources are transcribed and local microphone is attributed", .enabled(if: TestEnvironment.hasFFmpeg), .enabled(if: TestEnvironment.hasBundledVADModel))
    func transcribesIndependentSources() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "call-recorder-sources-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ffmpeg = URL(filePath: "/opt/homebrew/bin/ffmpeg")
        for name in ["system.m4a", "microphone.m4a"] {
            _ = try ProcessRunner.runChecked(
                executable: ffmpeg,
                arguments: [
                    "-v", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=0.2",
                    "-c:a", "aac", directory.appending(path: name).path,
                ]
            )
        }
        let compatibilityMix = directory.appending(path: "call.m4a")
        try FileManager.default.copyItem(
            at: directory.appending(path: "system.m4a"),
            to: compatibilityMix
        )
        let fakeWhisper = try makeSourceAwareFakeWhisper(in: directory)
        let model = directory.appending(path: "ggml-small.bin")
        try Data().write(to: model)
        let sam = Participant(id: ParticipantID(rawValue: UUID()), name: "Sam")

        let record = try await Transcriber(
            ffmpeg: ffmpeg,
            whisperCLI: fakeWhisper
        ).transcribe(
            callID: CallID(rawValue: UUID()),
            audio: compatibilityMix,
            modelID: "small",
            modelFile: model,
            participants: [sam],
            glossary: [],
            directory: directory,
            localParticipant: sam
        )

        #expect(record.text == "Local hello.\nRemote hello.")
        let markdown = try String(contentsOf: URL(filePath: record.markdownPath), encoding: .utf8)
        #expect(markdown.contains("**Sam**: Local hello."))
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: URL(filePath: record.jsonPath)))
                as? [String: Any]
        )
        let segments = try #require(object["segments"] as? [[String: Any]])
        #expect(segments.map { $0["source"] as? String } == ["microphone", "system"])
        let first = try #require(segments.first)
        #expect(first["speakerName"] as? String == "Sam")
    }

    @Test("safe global voice match labels a remote speaker without enrolling it", .enabled(if: TestEnvironment.hasFFmpeg), .enabled(if: TestEnvironment.hasBundledVADModel))
    func labelsSafeGlobalVoiceMatch() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "call-recorder-identity-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ffmpeg = URL(filePath: "/opt/homebrew/bin/ffmpeg")
        let ffprobe = URL(filePath: "/opt/homebrew/bin/ffprobe")
        let system = directory.appending(path: "system.m4a")
        _ = try ProcessRunner.runChecked(
            executable: ffmpeg,
            arguments: [
                "-v", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=0.2",
                "-c:a", "aac", system.path,
            ]
        )
        let compatibilityMix = directory.appending(path: "call.m4a")
        try FileManager.default.copyItem(at: system, to: compatibilityMix)
        let store = try CallStore(path: directory.appending(path: "calls.db").path)
        try await store.migrate()
        let participant = try await store.upsertParticipant(name: "Dana")
        let profileCallID = CallID(rawValue: UUID())
        let candidateCallID = CallID(rawValue: UUID())
        try await store.createCall(.started(id: profileCallID, at: Date()))
        try await store.createCall(.started(id: candidateCallID, at: Date()))
        var embedding = Array(repeating: Float.zero, count: 256)
        embedding[0] = 1
        let speakers = SpeakerStore(
            store: store,
            cipher: try VoiceprintCipher(keyData: Data(0..<32))
        )
        let confirmed = PendingSpeakerCluster(
            callID: profileCallID,
            speakerIndex: 0,
            speakerLabel: "SPEAKER_00",
            cluster: SpeakerCluster(
                id: SpeakerClusterID(rawValue: UUID()),
                modelVersion: "model-v1",
                embedding: embedding,
                speechDurationMilliseconds: 10_000
            ),
            createdAt: Date()
        )
        try await speakers.savePending(confirmed)
        let policy = SpeakerMatchPolicy(
            acceptanceSimilarity: 0.80,
            reviewSimilarity: 0.65,
            acceptanceMargin: 0.08,
            minimumSpeechMilliseconds: 8_000,
            minimumConfirmedSamples: 1
        )
        try await speakers.confirm(
            clusterID: confirmed.cluster.id,
            participantID: participant.id,
            policy: policy
        )
        let fakeDiarizer = try makeFakeDiarizer(in: directory)
        let fakeWhisper = try makeFakeWhisper(in: directory)
        let model = directory.appending(path: "ggml-small.bin")
        try Data().write(to: model)
        let pipeline = CallPipeline(
            store: store,
            finalizer: MediaFinalizer(ffmpeg: ffmpeg, ffprobe: ffprobe)
        )

        let record = try await pipeline.transcribe(
            callID: candidateCallID,
            audio: compatibilityMix,
            modelID: "small",
            modelFile: model,
            participantIDs: [],
            glossary: [],
            directory: directory,
            using: Transcriber(ffmpeg: ffmpeg, whisperCLI: fakeWhisper)
        )

        // The transcript survives a failed speaker stage. Retry needs no Whisper binary.
        try FileManager.default.removeItem(at: fakeWhisper)
        let revisions = TranscriptRevisionManager(root: directory.appending(path: "revisions"))
        await #expect(throws: DiarizerError.runtimeUnavailable) {
            try await pipeline.recognizeSpeakers(
                callID: candidateCallID, audioDirectory: directory, using: nil,
                speakerStore: speakers, revisionManager: revisions
            )
        }
        #expect(FileManager.default.fileExists(atPath: record.markdownPath))
        try await pipeline.recognizeSpeakers(
            callID: candidateCallID, audioDirectory: directory,
            using: Diarizer(python: URL(filePath: "/usr/bin/python3"), script: fakeDiarizer),
            speakerStore: speakers, revisionManager: revisions, policy: policy
        )

        let markdown = try String(contentsOf: URL(filePath: record.markdownPath), encoding: .utf8)
        #expect(markdown.contains("**Dana**: Привет, Alice."))
        #expect(try await store.participants(for: candidateCallID) == [participant])
        #expect(try await speakers.confirmedSampleCount(for: participant.id) == 1)
    }

    @Test("a long source is split into 300s chunks with offset timestamps", .enabled(if: TestEnvironment.hasFFmpeg))
    func splitsLongSourceIntoChunks() async throws {
        // Given
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "call-recorder-chunks-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ffmpeg = URL(filePath: "/opt/homebrew/bin/ffmpeg")
        let audio = directory.appending(path: "call.m4a")
        _ = try ProcessRunner.runChecked(
            executable: ffmpeg,
            arguments: [
                "-v", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=301",
                "-c:a", "aac", audio.path,
            ]
        )
        var whisperCalls: [String] = []
        let lock = NSLock()
        let fakeWhisper = directory.appending(path: "recording-whisper-cli")
        let script = [
            "#!/bin/sh",
            "/usr/bin/printf '%s\\n' \"$*\" >> \"$RECORDING_ARGUMENTS_LOG\"",
            "input=''",
            "output=''",
            "while [ \"$#\" -gt 0 ]; do",
            "  case \"$1\" in",
            "    --file) input=\"$2\"; shift 2 ;;",
            "    --output-file) output=\"$2\"; shift 2 ;;",
            "    *) shift ;;",
            "  esac",
            "done",
            "case \"$(/usr/bin/basename \"$input\")\" in",
            #"  chunk-000.wav) json='{"result":{"language":"en"},"transcription":[{"offsets":{"from":100,"to":300},"text":" First part. "}]}' ;;"#,
            #"  *) json='{"result":{"language":"en"},"transcription":[{"offsets":{"from":400,"to":700},"text":" Second part. "}]}' ;;"#,
            "esac",
            #"/usr/bin/printf '%s' "$json" > "${output}.json""#,
        ].joined(separator: "\n")
        try Data(script.utf8).write(to: fakeWhisper)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeWhisper.path
        )
        let logURL = directory.appending(path: "whisper-arguments.log")
        setenv("RECORDING_ARGUMENTS_LOG", logURL.path, 1)
        defer { unsetenv("RECORDING_ARGUMENTS_LOG") }
        let model = directory.appending(path: "ggml-small.bin")
        try Data().write(to: model)
        let vadModel = directory.appending(path: "ggml-silero-v6.2.0.bin")
        try Data(count: 885_098).write(to: vadModel)

        // When
        let record = try await Transcriber(
            ffmpeg: ffmpeg,
            whisperCLI: fakeWhisper,
            vadModel: vadModel
        ).transcribe(
            callID: CallID(rawValue: UUID()),
            audio: audio,
            modelID: "small",
            modelFile: model,
            participants: [],
            glossary: [],
            directory: directory
        )
        whisperCalls = try String(contentsOf: logURL, encoding: .utf8)
            .split(separator: "\n")
            .map { String($0) }

        // Then
        #expect(whisperCalls.count == 2)
        let chunks = whisperCalls.map { line -> String in
            let tokens = line.split(separator: " ")
            let fileIndex = tokens.firstIndex(of: "--file")
            return URL(filePath: String(tokens[fileIndex! + 1])).lastPathComponent
        }
        #expect(chunks == ["chunk-000.wav", "chunk-001.wav"])
        let vadPaths = whisperCalls.map { line -> String in
            let tokens = line.split(separator: " ")
            let vadIndex = tokens.firstIndex(of: "--vad-model")
            return String(tokens[vadIndex! + 1])
        }
        #expect(vadPaths == [vadModel.path, vadModel.path])
        #expect(whisperCalls.allSatisfy { $0.contains("--vad-max-speech-duration-s") })
        #expect(record.text == "First part.\nSecond part.")
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: URL(filePath: record.jsonPath)))
                as? [String: Any]
        )
        let segments = try #require(object["segments"] as? [[String: Any]])
        #expect(segments.map { $0["startMs"] as? Int } == [100, 300_400])
        #expect(segments.map { $0["endMs"] as? Int } == [300, 300_700])
        let leftover = try FileManager.default.contentsOfDirectory(
            atPath: directory.path
        ).filter {
            $0.hasSuffix(".wav")
                || ($0.hasSuffix(".json") && $0 != "transcript.json")
                || $0.contains("chunks-")
        }
        #expect(leftover.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func aStoppedTranscriptionEndsItsRunningCommand() async throws {
        // Given a transcriber whose first command does not finish on its own
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "call-recorder-stop-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let slowTool = directory.appending(path: "slow-tool")
        try Data("#!/bin/sh\nsleep 60\n".utf8).write(to: slowTool)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: slowTool.path
        )
        let audio = directory.appending(path: "call.m4a")
        try Data("audio".utf8).write(to: audio)
        let model = directory.appending(path: "ggml-small.bin")
        try Data().write(to: model)
        let cancellation = ProcessCancellation()
        let transcriber = Transcriber(
            ffmpeg: slowTool,
            whisperCLI: slowTool,
            vadModel: nil,
            cancellation: cancellation
        )
        let started = Date()

        // When the work is stopped while that command is still running
        let run = Task.detached {
            try await transcriber.transcribe(
                callID: CallID(rawValue: UUID()),
                audio: audio,
                modelID: "small",
                modelFile: model,
                participants: [],
                glossary: [],
                directory: directory
            )
        }
        try await Task.sleep(for: .milliseconds(400))
        cancellation.cancel()
        let outcome = await run.result

        // Then the stage ends in seconds, and it says the work was stopped rather than blaming
        // the encoder for an exit that came from a signal.
        #expect(throws: CancellationError.self) { try outcome.get() }
        #expect(Date().timeIntervalSince(started) < 20)
    }

    private func makeFakeWhisper(in directory: URL) throws -> URL {
        let url = directory.appending(path: "whisper-cli")
        let script = [
            "#!/bin/sh",
            "output=''",
            "while [ \"$#\" -gt 0 ]; do",
            "  case \"$1\" in",
            "    --output-file) output=\"$2\"; shift 2 ;;",
            "    *) shift ;;",
            "  esac",
            "done",
            #"/usr/bin/printf '%s' '{"result":{"language":"ru"},"transcription":[{"offsets":{"from":0,"to":1000},"text":" Привет, Alice. "}]}' > "${output}.json""#,
        ].joined(separator: "\n")
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func makePromptRecordingFakeWhisper(in directory: URL, promptFile: URL) throws -> URL {
        let url = directory.appending(path: "prompt-recording-whisper-cli")
        let script = [
            "#!/bin/sh",
            "output=''",
            "prompt=''",
            "while [ \"$#\" -gt 0 ]; do",
            "  case \"$1\" in",
            "    --output-file) output=\"$2\"; shift 2 ;;",
            "    --prompt) prompt=\"$2\"; shift 2 ;;",
            "    *) shift ;;",
            "  esac",
            "done",
            "/usr/bin/printf '%s' \"$prompt\" > \(promptFile.path)",
            #"/usr/bin/printf '%s' '{"result":{"language":"en"},"transcription":[{"offsets":{"from":0,"to":1000},"text":" Hi. "}]}' > "${output}.json""#,
        ].joined(separator: "\n")
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func makeSourceAwareFakeWhisper(in directory: URL) throws -> URL {
        let url = directory.appending(path: "source-aware-whisper-cli")
        let script = [
            "#!/bin/sh",
            "input=''",
            "output=''",
            "while [ \"$#\" -gt 0 ]; do",
            "  case \"$1\" in",
            "    --file) input=\"$2\"; shift 2 ;;",
            "    --output-file) output=\"$2\"; shift 2 ;;",
            "    *) shift ;;",
            "  esac",
            "done",
            "case \"$input\" in",
            #"  *microphone*) json='{"result":{"language":"en"},"transcription":[{"offsets":{"from":100,"to":300},"text":" Local hello. "}]}' ;;"#,
            #"  *) json='{"result":{"language":"en"},"transcription":[{"offsets":{"from":400,"to":700},"text":" Remote hello. "}]}' ;;"#,
            "esac",
            #"/usr/bin/printf '%s' "$json" > "${output}.json""#,
        ].joined(separator: "\n")
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func makeFakeDiarizer(in directory: URL) throws -> URL {
        let url = directory.appending(path: "fake-diarizer.py")
        let script = """
            import json
            embedding = [1.0] + [0.0] * 255
            print(json.dumps({
                "model": "model-v1",
                "segments": [{"start": 0.0, "end": 10.0, "speaker": "SPEAKER_00"}],
                "speakers": [{"speaker": "SPEAKER_00", "embedding": embedding}],
            }))
            """
        try Data(script.utf8).write(to: url)
        return url
    }
}
