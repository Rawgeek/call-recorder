import CallRecorderCore
import FluidAudio
import Foundation
import OSLog

/// Why a call could not be read with Parakeet.
enum ParakeetEngineError: LocalizedError {
    case modelUnavailable
    case untimedTranscript

    var errorDescription: String? {
        switch self {
        case .modelUnavailable:
            "The Parakeet model is not installed. Download it in Settings, Models, Components."
        case .untimedTranscript:
            "Parakeet read words but wrote no time for them, so they cannot be placed in the call."
        }
    }
}

/// Where the Parakeet model lives, and what a complete copy of it holds.
///
/// The model is a Core ML bundle of four graphs and a vocabulary, downloaded from Hugging Face
/// into the folder the app keeps its other models in. Nothing of it ships inside the app.
enum ParakeetModel {
    /// The folder the model is kept in, named after the repository it was published in.
    static let repositoryFolderName = "parakeet-tdt-0.6b-v3-coreml"

    /// What a transcript read by this engine says it was read with.
    static let modelName = "Parakeet TDT 0.6B v3"

    /// The files a call is read with.
    ///
    /// The vocabulary is checked with the graphs because a bundle that lost it loads and then
    /// decodes nothing, which fails a call at the end of its own work rather than at the start.
    static let requiredFileNames = [
        "Preprocessor.mlmodelc",
        "Encoder.mlmodelc",
        "Decoder.mlmodelc",
        "JointDecisionv3.mlmodelc",
        "parakeet_vocab.json",
    ]

    /// The folder every model is installed under, beside the whisper files.
    static func root(in applicationDirectory: URL) -> URL {
        applicationDirectory.appending(path: "models", directoryHint: .isDirectory)
    }

    /// The folder this model is read from.
    static func repository(in applicationDirectory: URL) -> URL {
        root(in: applicationDirectory)
            .appending(path: repositoryFolderName, directoryHint: .isDirectory)
    }

    static func isComplete(in applicationDirectory: URL) -> Bool {
        isComplete(at: repository(in: applicationDirectory))
    }

    /// Whether the files of a complete install are on disk.
    ///
    /// This is the cheap half of readiness: it does not prove that Core ML loads them. It does
    /// keep a download that stopped halfway from being chosen as the engine of a call.
    static func isComplete(at repository: URL) -> Bool {
        requiredFileNames.allSatisfy {
            FileManager.default.fileExists(atPath: repository.appending(path: $0).path)
        }
    }

    /// What the installed copy takes on disk, for the settings row.
    static func installedBytes(in applicationDirectory: URL) -> Int64 {
        let repository = repository(in: applicationDirectory)
        guard
            let walk = FileManager.default.enumerator(
                at: repository,
                includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
            )
        else { return 0 }
        var bytes: Int64 = 0
        for case let url as URL in walk {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true, let size = values?.fileSize else { continue }
            bytes += Int64(size)
        }
        return bytes
    }

    /// Downloads the model, reporting how much of it has arrived.
    ///
    /// Only the four graphs a call is read with are fetched, at the precision the reader loads:
    /// the repository also publishes an int4 encoder and files for other runtimes, and pulling
    /// every one of them would multiply the download for nothing.
    static func download(
        in applicationDirectory: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let root = root(in: applicationDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try await ModelHub.download(
            .parakeetV3,
            to: root,
            variant: ParakeetEncoderPrecision.int8.rawValue,
            progressHandler: { report in progress(report.fractionCompleted) }
        )
    }
}

/// Reads recordings with Parakeet TDT 0.6B v3.
///
/// The model runs on the Neural Engine and reads twenty-five European languages in one pass,
/// Russian and Ukrainian among them, so a call that mixes languages needs no language named and
/// no second pass. It answers with the words and the time each was said, which is what the turns
/// of a transcript are built from, so every later stage of the pipeline stays as it was.
///
/// The graphs are large and take seconds to load. They are loaded once and kept, because a call
/// read now and a call read in an hour run on the same model.
actor ParakeetEngine {
    private let repository: URL
    private var manager: AsrManager?
    private let logger = Logger(subsystem: "local.callrecorder.app", category: "parakeet")

    init(repository: URL) {
        self.repository = repository
    }

    /// Reads one track of a call into the turns a transcript is written in.
    ///
    /// The file goes in as the recorder wrote it: Parakeet resamples to its own rate and mixes to
    /// one channel itself, so this path converts nothing and writes no intermediate wave file.
    func transcribe(audio: URL, language: String) async throws -> WhisperTranscript {
        guard ParakeetModel.isComplete(at: repository) else {
            throw ParakeetEngineError.modelUnavailable
        }
        let manager = try await loadedManager()
        let started = Date()
        var state = TdtDecoderState.make()
        let result = try await manager.transcribe(
            audio,
            decoderState: &state,
            language: Self.hint(for: language)
        )
        let segments = ParakeetSegments.build(words: Self.words(from: result))
        guard !segments.isEmpty else {
            // A recording that holds nothing is not a failure. A room with nobody in it and a
            // microphone that was muted both read as no words, whisper.cpp with its silence filter
            // answers one the same way, and the app already has a name for a call with no speech.
            // Words without times are the other case, and they are a fault: they cannot be placed
            // in the call, so nothing honest can be written with them.
            guard result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ParakeetEngineError.untimedTranscript
            }
            // The language is whatever was asked for, and the app's own word for a reading that
            // named none: there are no words here to read a language off.
            let named = SpeechEngineChoice.asksTheModel(language) ? "unknown" : language
            return WhisperTranscript(language: named, segments: [])
        }
        logger.notice(
            """
            read \(audio.lastPathComponent, privacy: .public) in \
            \(Date().timeIntervalSince(started), privacy: .public)s into \
            \(segments.count, privacy: .public) turns
            """
        )
        let text = segments.map(\.text).joined(separator: " ")
        return WhisperTranscript(
            language: SpeechEngineChoice.transcriptLanguage(requested: language, text: text),
            segments: segments
        )
    }

    private func loadedManager() async throws -> AsrManager {
        if let manager { return manager }
        let models = try AsrModels.loadLocal(
            from: repository,
            version: .v3,
            encoderPrecision: .int8
        )
        let manager = AsrManager(models: models)
        self.manager = manager
        return manager
    }

    /// Lets go of the loaded graphs, so a model that was deleted is not read from memory.
    func forgetLoadedModels() {
        manager = nil
    }

    /// The language to hold the decoder to, or nil to let it read the language as it goes.
    ///
    /// Naming the language tells the decoder to prefer the script of that language when two
    /// candidate tokens are close, which is what keeps a Russian call from being written in
    /// Latin letters. A language the app knows nothing about is passed on as nothing.
    private static func hint(for language: String) -> Language? {
        guard !SpeechEngineChoice.asksTheModel(language) else { return nil }
        let code = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return Language(rawValue: String(code.prefix(2)))
    }

    /// The words Parakeet timed, in the order it said them.
    ///
    /// The model answers with sub-word tokens. A turn is a sentence, so the tokens are joined
    /// back into the word each one belongs to before the boundaries between turns are found.
    private static func words(from result: ASRResult) -> [RecognizedWord] {
        guard let timings = result.tokenTimings, !timings.isEmpty else { return [] }
        return buildWordTimings(from: timings).map { timing in
            RecognizedWord(
                text: timing.word,
                startMs: Int((timing.startTime * 1000).rounded()),
                endMs: Int((timing.endTime * 1000).rounded())
            )
        }
    }
}
