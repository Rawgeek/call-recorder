import CallRecorderCore
import Darwin
import Foundation

struct Diarizer: Sendable {
    let python: URL
    let script: URL
    let ffmpeg: URL?
    let timeout: TimeInterval

    init(
        python: URL,
        script: URL,
        ffmpeg: URL? = nil,
        timeout: TimeInterval = 90 * 60
    ) {
        self.python = python
        self.script = script
        self.ffmpeg = ffmpeg
        self.timeout = timeout
    }

    /// Runs diarization on a 16kHz mono WAV.
    func run(
        on waveURL: URL,
        numberOfSpeakers: Int?,
        cancellation: ProcessCancellation? = nil
    ) throws -> DiarizationResult {
        var arguments = [waveURL.path]
        if let numberOfSpeakers {
            arguments += ["--num-speakers", String(numberOfSpeakers)]
        }
        return try execute(arguments: arguments, cancellation: cancellation)
    }

    func check() throws {
        _ = try execute(arguments: ["--check"])
    }

    private func execute(
        arguments: [String],
        cancellation: ProcessCancellation? = nil,
        ffmpegOverride: URL? = nil
    ) throws -> DiarizationResult {
        let process = Process()
        process.executableURL = python
        process.arguments = [script.path] + arguments
        process.environment = Self.runtimeEnvironment(
            base: ProcessInfo.processInfo.environment,
            ffmpeg: ffmpegOverride ?? ffmpeg
        )
        let errorURL = FileManager.default.temporaryDirectory.appending(
            path: "diarizer-\(UUID().uuidString).stderr")
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        let errorFile = try FileHandle(forWritingTo: errorURL)
        // Both streams go to files rather than to pipes.
        //
        // The output used to arrive through a pipe read by a thread on the utility queue, and the
        // parent waited five seconds for that reader to finish after the script had exited. On a
        // busy machine the reader could still be waiting to be scheduled when the five seconds ran
        // out, and a diarization that failed for a real reason was then reported as an empty
        // output, which names the wrong fault and sends whoever reads the error to the wrong place.
        // A file has no reader to wait for: what the script wrote is on disk when it exits.
        let outputURL = FileManager.default.temporaryDirectory.appending(
            path: "diarizer-\(UUID().uuidString).stdout")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let outputFile = try FileHandle(forWritingTo: outputURL)
        defer {
            try? errorFile.close()
            try? outputFile.close()
            try? FileManager.default.removeItem(at: errorURL)
            try? FileManager.default.removeItem(at: outputURL)
        }
        process.standardError = errorFile
        process.standardOutput = outputFile
        let terminated = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in terminated.signal() }
        do {
            try process.run()
        } catch {
            throw error
        }
        // Waited on in short steps rather than one long block, so a stopped analysis and a run
        // that has overstayed its timeout both end the script instead of waiting for it.
        let deadline = Date().addingTimeInterval(timeout)
        while terminated.wait(timeout: .now() + 0.2) == .timedOut {
            if cancellation?.isCancelled == true {
                ProcessRunner.end(process)
                throw CancellationError()
            }
            if Date() >= deadline {
                process.terminate()
                if terminated.wait(timeout: .now() + 2) == .timedOut {
                    kill(process.processIdentifier, SIGKILL)
                    _ = terminated.wait(timeout: .now() + 2)
                }
                throw DiarizerError.timedOut
            }
        }
        let data = (try? Data(contentsOf: outputURL)) ?? Data()
        if let raw = try? JSONDecoder().decode(DiarizerRawOutput.self, from: data), let error = raw.error {
            throw DiarizerError.scriptFailed(DiagnosticsReporter.redacted(error: error))
        }
        guard process.terminationStatus == 0 else {
            let stderr = try String(contentsOf: errorURL, encoding: .utf8)
            throw DiarizerError.scriptFailed(
                DiagnosticsReporter.redacted(
                    error: "Exit \(process.terminationStatus): \(stderr.suffix(8_000))"
                ))
        }
        guard !data.isEmpty else { throw DiarizerError.emptyOutput }
        return try Self.decode(data)
    }

    func run(
        audio: URL,
        ffmpeg: URL,
        cancellation: ProcessCancellation? = nil
    ) throws -> DiarizationResult {
        let wave = FileManager.default.temporaryDirectory.appending(
            path: "diarizing-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: wave) }
        _ = try ProcessRunner.runChecked(
            executable: ffmpeg,
            arguments: [
                "-v", "error", "-n", "-i", audio.path,
                "-vn", "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", wave.path,
            ],
            cancellation: cancellation)
        return try execute(
            arguments: [wave.path],
            cancellation: cancellation,
            ffmpegOverride: ffmpeg
        )
    }

    /// TorchCodec loads FFmpeg's shared libraries at runtime. A GUI app does not inherit
    /// Homebrew's shell setup, so the executable may be found while its dylibs are not. Derive
    /// the library directory from the exact ffmpeg binary the app selected and expose it only to
    /// the speaker-analysis child process.
    static func runtimeEnvironment(base: [String: String], ffmpeg: URL?) -> [String: String] {
        guard let ffmpeg else { return base }
        let libraryDirectory = ffmpeg
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "lib", directoryHint: .isDirectory)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: libraryDirectory.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else { return base }

        var environment = base
        var paths = (base["DYLD_FALLBACK_LIBRARY_PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        if !paths.contains(libraryDirectory.path) {
            paths.insert(libraryDirectory.path, at: 0)
        }
        environment["DYLD_FALLBACK_LIBRARY_PATH"] = paths.joined(separator: ":")
        return environment
    }

    static func decode(_ data: Data) throws -> DiarizationResult {
        let raw = try JSONDecoder().decode(DiarizerRawOutput.self, from: data)
        if let error = raw.error { throw DiarizerError.scriptFailed(error) }
        return try result(from: raw)
    }

    private static func result(from raw: DiarizerRawOutput) throws -> DiarizationResult {
        let turns = (raw.segments ?? []).map {
            DiarizationTurn(start: $0.start, end: $0.end, speakerLabel: $0.speaker)
        }
        var seenLabels = Set<String>()
        let clusters = try (raw.speakers ?? []).map { speaker in
            guard
                !speaker.speaker.isEmpty,
                seenLabels.insert(speaker.speaker).inserted,
                speaker.embedding.count == 256,
                speaker.embedding.allSatisfy(\.isFinite)
            else { throw DiarizerError.invalidEmbedding }
            let norm = sqrt(speaker.embedding.reduce(0) { $0 + $1 * $1 })
            guard norm.isFinite, abs(norm - 1) < 0.02 else {
                throw DiarizerError.invalidEmbedding
            }
            let duration =
                turns
                .filter { $0.speakerLabel == speaker.speaker }
                .reduce(0) { $0 + max(0, $1.end - $1.start) }
            return DiarizedSpeakerCluster(
                speakerLabel: speaker.speaker,
                embedding: speaker.embedding.map(Float.init),
                speechDurationSeconds: duration
            )
        }
        guard clusters.isEmpty || raw.model?.isEmpty == false else {
            throw DiarizerError.invalidEmbedding
        }
        return DiarizationResult(
            modelVersion: raw.model,
            turns: turns,
            clusters: clusters
        )
    }

    struct DiarizerRawOutput: Decodable {
        let error: String?
        let model: String?
        let segments: [Segment]?
        let speakers: [Speaker]?

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let array = try? container.decode([Segment].self) {
                error = nil
                model = nil
                segments = array
                speakers = nil
            } else {
                let obj = try container.decode(ObjectOutput.self)
                error = obj.error
                model = obj.model
                segments = obj.segments
                speakers = obj.speakers
            }
        }

        struct Segment: Decodable {
            let start: Double
            let end: Double
            let speaker: String
        }

        struct Speaker: Decodable {
            let speaker: String
            let embedding: [Double]
        }

        private struct ObjectOutput: Decodable {
            let error: String?
            let model: String?
            let segments: [Segment]?
            let speakers: [Speaker]?
        }
    }
}

struct DiarizationResult: Equatable, Sendable {
    let modelVersion: String?
    let turns: [DiarizationTurn]
    let clusters: [DiarizedSpeakerCluster]
}

struct DiarizedSpeakerCluster: Equatable, Sendable {
    let speakerLabel: String
    let embedding: [Float]
    let speechDurationSeconds: Double
}

struct DiarizationTurn: Equatable {
    let start: Double  // seconds
    let end: Double  // seconds
    let speakerLabel: String  // "SPEAKER_00" etc.
}

enum DiarizerError: LocalizedError, Equatable {
    case emptyOutput
    case scriptFailed(String)
    case invalidEmbedding
    case timedOut
    case runtimeUnavailable
    case noSpeakersDetected

    var errorDescription: String? {
        switch self {
        case .emptyOutput: "Diarization produced no output."
        case .scriptFailed(let msg): "Diarization failed: \(msg)"
        case .invalidEmbedding: "Diarization produced an invalid speaker embedding."
        case .timedOut: "Diarization timed out and was stopped. Retry it from Recovery."
        case .runtimeUnavailable:
            "Local speaker-analysis runtime is missing. Choose its Python environment in Review. Your audio and transcript are safe."
        case .noSpeakersDetected:
            "Speech was transcribed, but no usable speakers were detected. Audio is retained. Retry speaker detection from Review."
        }
    }
}

enum SegmentMerger {
    /// Merges diarization speaker labels into whisper segments by timestamp overlap.
    /// Assigns speakerIndex by order of first appearance (0, 1, 2…).
    /// The renderer maps these to "Speaker 1", "Speaker 2", etc.
    static func merge(
        whisperSegments: [TranscriptSegment],
        diarization: [DiarizationTurn]
    ) -> [TranscriptSegment] {
        guard !diarization.isEmpty else { return whisperSegments }

        var speakerIndexMap = [String: Int]()
        for turn in diarization where speakerIndexMap[turn.speakerLabel] == nil {
            speakerIndexMap[turn.speakerLabel] = speakerIndexMap.count
        }

        return whisperSegments.map { segment in
            let segStart = Double(segment.startMs) / 1000.0
            let segEnd = Double(segment.endMs) / 1000.0

            var overlaps: [String: Double] = [:]
            for turn in diarization {
                let overlap = min(segEnd, turn.end) - max(segStart, turn.start)
                if overlap > 0 { overlaps[turn.speakerLabel, default: 0] += overlap }
            }

            let bestLabel = overlaps.keys.sorted().max { overlaps[$0, default: 0] < overlaps[$1, default: 0] }
            guard let bestLabel, let idx = speakerIndexMap[bestLabel] else {
                return segment
            }
            return TranscriptSegment(
                startMs: segment.startMs,
                endMs: segment.endMs,
                text: segment.text,
                speakerIndex: idx,
                source: segment.source
            )
        }
    }
}
