import CallRecorderCore
import Foundation
import OSLog

/// Why a call could not be read.
enum QwenEngineError: LocalizedError {
    case runtimeMissing
    case modelMissing
    case scriptMissing
    case scriptFailed(String)
    case untimedTranscript

    var errorDescription: String? {
        switch self {
        case .runtimeMissing:
            "The speech runtime is missing. Install it in Settings, Models, Speech."
        case .modelMissing:
            "The Qwen3-ASR model is not installed. Download it in Settings, Models, Speech."
        case .scriptMissing:
            "The transcription script is missing from this build of the app."
        case .scriptFailed(let message):
            message.isEmpty ? "The transcription run failed." : message
        case .untimedTranscript:
            "The model read words but wrote no time for them, so they cannot be placed in the call."
        }
    }
}

/// What can read one track of a recording into words.
///
/// The transcriber talks to this rather than to the model itself, so the passes that clean and
/// write a transcript can be exercised without a two-and-a-half-gigabyte model on disk.
protocol SpeechReading: Sendable {
    func transcribe(
        audio: URL,
        language: String,
        hotwords: [String],
        cancellation: ProcessCancellation?
    ) async throws -> SpeechTranscript
}

/// What the transcription script answers with.
struct QwenTranscriptDocument: Decodable, Sendable {
    struct Piece: Decodable, Sendable {
        let start: Double
        let end: Double
        let text: String
    }

    let language: String
    let detectedLanguage: String?
    let duration: Double
    let segments: [Piece]
    let dropped: Int
    let seconds: Double
}

/// Reads recordings with Qwen3-ASR, run on MLX by the speech runtime.
///
/// The model is a Python program rather than a framework this app links, because that is where the
/// published weights run: the app keeps the model, the script, and the runtime in place, and hands
/// the script one converted track at a time. The conversion is the same one every engine before it
/// needed — 16 kHz mono — and it happens in a temporary folder that is removed afterwards.
///
/// A reading that comes back with no timed pieces is a fault rather than an empty call: words the
/// model wrote without a time cannot be placed against the diarization, so nothing honest can be
/// built from them.
///
/// The piece length the audio is read in is the script's own default, which is where it is measured
/// and documented. It is left there rather than passed from here so that one number decides it.
actor QwenEngine: SpeechReading {
    private var python: URL?
    private let script: URL?
    private let ffmpeg: URL?
    private let model: URL
    private let logger = Logger(subsystem: "local.callrecorder.app", category: "qwen")

    init(python: URL?, script: URL?, ffmpeg: URL?, model: URL) {
        self.python = python
        self.script = script
        self.ffmpeg = ffmpeg
        self.model = model
    }

    /// Moves the reader onto another Python environment.
    ///
    /// The environment is chosen in Speaker setup, which is the same choice the reader runs in, so
    /// the next call is read in the environment the person picked rather than in the one this
    /// launch started with.
    func use(python: URL?) {
        self.python = python
    }

    /// Whether everything the run needs is in place.
    var isReady: Bool {
        guard let python, let script, let ffmpeg else { return false }
        return FileManager.default.isExecutableFile(atPath: python.path)
            && FileManager.default.fileExists(atPath: script.path)
            && FileManager.default.isExecutableFile(atPath: ffmpeg.path)
            && FileManager.default.fileExists(atPath: model.path)
    }

    func transcribe(
        audio: URL,
        language: String,
        hotwords: [String],
        cancellation: ProcessCancellation?
    ) async throws -> SpeechTranscript {
        guard let python, FileManager.default.isExecutableFile(atPath: python.path) else {
            throw QwenEngineError.runtimeMissing
        }
        guard let script else { throw QwenEngineError.scriptMissing }
        guard let ffmpeg else { throw QwenEngineError.runtimeMissing }
        guard FileManager.default.fileExists(atPath: model.path) else {
            throw QwenEngineError.modelMissing
        }

        let work = FileManager.default.temporaryDirectory
            .appending(path: "qwen-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let wave = work.appending(path: "audio.wav")
        _ = try ProcessRunner.runChecked(
            executable: ffmpeg,
            arguments: [
                "-v", "error", "-y", "-i", audio.path,
                "-vn", "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", wave.path,
            ],
            cancellation: cancellation
        )

        let output = work.appending(path: "transcript.json")
        let started = Date()
        let result = try ProcessRunner.runChecked(
            executable: python,
            arguments: [
                script.path,
                "--model", model.path,
                "--audio", wave.path,
                "--output", output.path,
                "--language", language,
                "--hotwords", hotwords.joined(separator: ","),
            ],
            cancellation: cancellation
        )
        guard FileManager.default.fileExists(atPath: output.path) else {
            throw QwenEngineError.scriptFailed(result.standardError)
        }
        let document = try JSONDecoder().decode(
            QwenTranscriptDocument.self,
            from: Data(contentsOf: output)
        )
        let segments = document.segments
            .map { piece in
                TranscriptSegment(
                    startMs: Int((piece.start * 1000).rounded()),
                    endMs: Int((piece.end * 1000).rounded()),
                    text: piece.text.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
            .filter { !$0.text.isEmpty }
        guard !segments.isEmpty else {
            let said = document.segments.map(\.text).joined()
            guard said.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw QwenEngineError.untimedTranscript
            }
            return SpeechTranscript(
                language: TranscriptLanguage.naming(requested: language, text: ""),
                segments: []
            )
        }
        let text = segments.map(\.text).joined(separator: " ")
        logger.notice(
            """
            read \(audio.lastPathComponent, privacy: .public) in \
            \(Date().timeIntervalSince(started), privacy: .public)s into \
            \(segments.count, privacy: .public) pieces, \
            \(document.dropped, privacy: .public) dropped
            """
        )
        let named = document.detectedLanguage.flatMap { detected -> String? in
            let code = detected.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return code.count == 2 ? code : nil
        }
        return SpeechTranscript(
            language: named ?? TranscriptLanguage.naming(requested: language, text: text),
            segments: segments
        )
    }
}
