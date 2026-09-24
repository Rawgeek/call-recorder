import CallRecorderCore
import Foundation
import OSLog

/// The live path of one recording: the tap, the transcriber, and the questions.
///
/// One of these is built when a recording starts and torn down when it ends. It owns the folder the
/// live chunks are written to and the two model servers behind the window, and it reports what it
/// finds as events. Nothing here touches the library: the call's transcript is written after the
/// call, from the recording, by the pipeline that already does that work.
///
/// Everything in here is disposable by design. A live path that cannot start, cannot keep up, or
/// stops with an error leaves the recording exactly as it would have been without it — amanu's
/// failure list is written from the same rule, and it is the only rule that matters for a feature
/// that watches a call somebody is having.
@MainActor
final class LiveTranscriptSession {
    /// What the window needs to hear about.
    enum Event: Sendable {
        case ready
        case text([LiveTranscriptEntry])
        case backlog(seconds: Double, droppedChunks: Int)
        case failure(String)
        /// A fresh running summary of the call so far, written by the model on this Mac.
        case summary(String)
        case answer(LiveChatAnswer)
        case answerFailure(String)
    }

    /// Everything one call's live path needs that is decided before it starts.
    struct Configuration {
        /// The call's own folder. The live audio lives in a subfolder of it and is removed with it.
        let callDirectory: URL
        /// Where `whisper-server` is, when this Mac has whisper.cpp.
        let whisperServer: URL?
        /// The model file the batch run would use, when it is installed.
        let whisperModel: URL?
        /// What that model is called, for the sentence that says it is not installed.
        let whisperModelName: String
        /// The names and terms to spell correctly, built the way the batch run builds them.
        let prompt: String
        let glossary: [GlossaryTerm]
        /// How the two sides of the call are drawn.
        let localSpeaker: String
        let remoteSpeaker: String
        /// llama.cpp and the brief model, for questions. Both are absent on a Mac that has not
        /// installed them, and a question is then refused with a sentence rather than failing later.
        let chatRuntime: URL?
        let chatModel: URL?
        /// How often the words on screen are replaced by a summary of them, or nil when the person
        /// turned summarizing off. Nothing is asked of the model when this is nil.
        let summaryIntervalSeconds: Double?
    }

    private let configuration: Configuration
    private let onEvent: @Sendable (Event) -> Void
    private let directory: URL
    /// The reader's own side of the model, when a test handed one over instead of leaving the
    /// session to build a whisper.cpp client. Nil on every path the app takes.
    private let readingTransport: (any LiveTranscriptionTransport)?
    private let logger = Logger(subsystem: "local.callrecorder.app", category: "live")
    /// The reader of the audio. Readable from outside this class so a test can hand it chunks of its
    /// own and wait for what it made of them; nothing else reads it.
    private(set) var transcriber: LiveTranscriber?
    private var chat: LiveChatRunner?
    private var summarizer: (any LiveSummarizing)?
    /// Why the live path cannot run, kept from the moment it is built until there is a window to
    /// say it in.
    private var preparationFailure: LiveTranscriptionError?
    /// The words as this session heard them, kept beside the window's copy so a summary can be
    /// written without asking the window for what it holds.
    private var transcript: LiveTranscript
    private var summary = ""
    private var summarizedEntryCount = 0
    private var summaryTask: Task<Void, Never>?
    private var isSummarizing = false
    private var isFinished = false

    /// - Parameters:
    ///   - configuration: what this call's live path needs.
    ///   - readingTransport: why a test can check the live path without a model: it hands over the
    ///     reader's side and answers from bytes the test chose. Nil on every path the app takes,
    ///     which is the one that builds a whisper.cpp client from the configuration.
    ///   - summarizer: the writer of the running summary, or nil to use the same local model the
    ///     window asks questions with. A test hands over a stub.
    init(
        configuration: Configuration,
        readingTransport: (any LiveTranscriptionTransport)? = nil,
        summarizer: (any LiveSummarizing)? = nil,
        onEvent: @escaping @Sendable (Event) -> Void
    ) {
        self.configuration = configuration
        self.onEvent = onEvent
        self.summarizer = summarizer
        self.readingTransport = readingTransport
        directory = configuration.callDirectory.appending(path: ".live", directoryHint: .isDirectory)
        transcript = LiveTranscript(
            localSpeaker: configuration.localSpeaker,
            remoteSpeaker: configuration.remoteSpeaker
        )
        prepareTranscriber()
    }

    /// Builds the reader of the audio, and keeps the reason when it cannot be built.
    ///
    /// This runs while the session is made rather than in `start()`, because the tap that reads a
    /// recording's audio is asked for before capture opens: a tap handed back without a reader is a
    /// live view with nothing in it for the whole call. The 2026-09-21 14:02 recording is that bug —
    /// the window said "Listening", the model was up, and not one word arrived, because the tap was
    /// nil. Building the reader starts nothing: `start()` launches the model, and chunks that arrive
    /// first wait in the reader's own queue, which is capped.
    private func prepareTranscriber() {
        let transport: any LiveTranscriptionTransport
        if let readingTransport {
            transport = readingTransport
        } else {
            guard
                let executable = configuration.whisperServer,
                let model = configuration.whisperModel
            else {
                preparationFailure = configuration.whisperServer == nil
                    ? .whisperServerUnavailable
                    : .modelUnavailable(configuration.whisperModelName)
                return
            }
            do {
                transport = try LiveTranscriptionServer(
                    executable: executable,
                    model: model,
                    prompt: configuration.prompt
                )
            } catch let error as LiveTranscriptionError {
                preparationFailure = error
                return
            } catch {
                preparationFailure = .serverDidNotStart(error.localizedDescription)
                return
            }
        }
        transcriber = LiveTranscriber(
            transport: transport,
            prompt: configuration.prompt,
            localSpeaker: configuration.localSpeaker,
            remoteSpeaker: configuration.remoteSpeaker,
            glossary: configuration.glossary,
            onEvent: { [weak self] event in
                Task { @MainActor in self?.forward(event) }
            }
        )
    }

    /// Whether there is a path at all: no server or no model means no tap is attached, and the
    /// recording does not pay for a feature that cannot run.
    var isAvailable: Bool {
        transcriber != nil
    }

    /// How the two sides of this call are drawn, for the transcript the window reads.
    var localSpeakerName: String { configuration.localSpeaker }
    var remoteSpeakerName: String { configuration.remoteSpeaker }

    /// Starts the transcriber, before the first chunk is ready.
    func start() {
        guard let transcriber else {
            if let preparationFailure { report(preparationFailure) }
            return
        }
        Task { await transcriber.start() }
        startSummaryLoop()
    }

    /// A tap for one segment of the recording, or nil when live text cannot run.
    func makeTap(offsetSeconds: Double) -> LiveAudioTap? {
        guard let transcriber else { return nil }
        return LiveAudioTap(
            directory: directory,
            offsetSeconds: offsetSeconds
        ) { chunk in
            transcriber.enqueue(chunk)
        }
    }

    // MARK: - The running summary

    /// Starts the passes that replace the words on screen with a summary of them.
    ///
    /// One loop for the whole call, waiting a fixed interval between passes, because the words
    /// arrive continuously and a summary is only worth reading once enough of them have. Whether a
    /// pass is worth it is decided by the words themselves, so a quiet stretch of a call costs
    /// nothing and a busy one updates on every interval.
    private func startSummaryLoop() {
        guard
            summaryTask == nil,
            let interval = configuration.summaryIntervalSeconds,
            interval > 0,
            summaryWriter() != nil
        else { return }
        summaryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                await self?.summarizeIfWorthIt()
            }
        }
    }

    /// The client that writes the summary: the one a test handed over, or the same local model the
    /// window asks questions with.
    private func summaryWriter() -> (any LiveSummarizing)? {
        if let summarizer { return summarizer }
        return chatRunner()
    }

    private func summarizeIfWorthIt() async {
        guard !isFinished, !isSummarizing, let writer = summaryWriter() else { return }
        guard LiveSummary.isWorthUpdating(
            transcript: transcript,
            lastEntryCount: summarizedEntryCount
        ) else { return }
        isSummarizing = true
        defer { isSummarizing = false }
        let previous = summary
        let words = transcript
        do {
            let updated = try await writer.summarize(previous: previous, transcript: words)
            guard !isFinished else { return }
            summary = updated
            summarizedEntryCount = words.entries.count
            onEvent(.summary(updated))
        } catch {
            // A summary that failed is not the call's problem: the words are still on screen and
            // the next pass tries again. It is worth a line, because a summary that never arrives
            // looks exactly like one that is not due yet.
            let message = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            logger.notice("live summary skipped: \(message, privacy: .public)")
        }
    }

    /// Asks the model a question about the call so far.
    func ask(_ question: String, transcript: LiveTranscript) {
        guard let runner = chatRunner() else {
            onEvent(
                .answerFailure(
                    SummarizerError.modelUnavailable.errorDescription
                        ?? "The brief model is not downloaded."
                )
            )
            return
        }
        Task { [weak self] in
            do {
                let answer = try await runner.ask(question, transcript: transcript)
                await MainActor.run {
                    self?.onEvent(.answer(LiveChatAnswer(question: question, answer: answer)))
                }
            } catch {
                let message = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                await MainActor.run { self?.onEvent(.answerFailure(message)) }
            }
        }
    }

    /// The local model the window shares: one server for the summary and for questions.
    private func chatRunner() -> LiveChatRunner? {
        if let chat { return chat }
        guard let runtime = configuration.chatRuntime, let model = configuration.chatModel else {
            return nil
        }
        let started = LiveChatRunner(runtime: runtime, model: model)
        chat = started
        return started
    }

    /// Ends everything the live path owns, and removes the audio it wrote.
    ///
    /// Called before the finished call is queued, on purpose: the live server holds the same model
    /// the batch run is about to load, and two copies of it in memory is the waste amanu's design
    /// document calls out by name.
    func finish() async {
        guard !isFinished else { return }
        isFinished = true
        summaryTask?.cancel()
        summaryTask = nil
        if let transcriber { await transcriber.stop() }
        if let chat { await chat.stop() }
        transcriber = nil
        chat = nil
        if FileManager.default.fileExists(atPath: directory.path) {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                logger.notice(
                    "live audio left behind at \(self.directory.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    private func forward(_ event: LiveTranscriberEvent) {
        switch event {
        case .ready:
            onEvent(.ready)
        case let .entries(lines):
            // The words are kept here as well as in the window: the summary is written from the
            // call so far, and both copies are stamped by the same rules.
            transcript.append(lines)
            onEvent(.text(lines))
        case let .backlog(seconds, droppedChunks):
            onEvent(.backlog(seconds: seconds, droppedChunks: droppedChunks))
        case let .failed(message):
            onEvent(.failure(message))
        }
    }

    private func report(_ error: any Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        logger.notice("live path unavailable: \(message, privacy: .public)")
        onEvent(.failure(message))
    }
}
