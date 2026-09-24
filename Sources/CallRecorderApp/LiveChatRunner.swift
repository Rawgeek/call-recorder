import CallRecorderCore
import Foundation

/// The model behind the window's running summary.
///
/// A recorder hands over the same client it answers questions with, so the model is loaded once and
/// the words never leave the Mac; a test hands over a stub, so the schedule and the window can be
/// checked without a model, a process, or a call.
protocol LiveSummarizing: Sendable {
    func summarize(previous: String, transcript: LiveTranscript) async throws -> String
}

extension LiveChatRunner: LiveSummarizing {
    /// Writes the running summary again from everything said so far.
    ///
    /// The summary on screen is sent with the words so an update keeps whatever is still true
    /// instead of writing the call out from nothing every minute; the words are sent as the same
    /// tail a question is answered from, because both are about the call so far.
    func summarize(previous: String, transcript: LiveTranscript) async throws -> String {
        guard !transcript.isEmpty else { throw LiveChatError.empty }
        return try await complete(
            system: LiveSummary.systemPrompt(),
            user: LiveSummary.userPrompt(
                previous: previous,
                transcript: transcript.tail(maxCharacters: LiveSummary.maximumContextCharacters)
            ),
            maxTokens: LiveSummary.updateTokenBudget
        )
    }
}

/// Why a question about the call could not be answered.
enum LiveChatError: LocalizedError, Equatable {
    /// The question cannot be asked at all, and this is the sentence to show instead.
    case refused(String)
    /// The model stopped, or never started.
    case model(SummarizerError)
    /// The model answered with nothing.
    case empty

    var errorDescription: String? {
        switch self {
        case let .refused(sentence): sentence
        case let .model(error): error.errorDescription
        case .empty: "The model wrote nothing. Try asking again, or in fewer words."
        }
    }
}

/// Answers questions about a call that is still running, with a model on this Mac.
///
/// The same llama.cpp server the brief uses, started the first time a question is asked and kept
/// until the recording ends: loading a 4B model takes seconds, and a question about a meeting is
/// usually followed by another one. Nothing here reaches the network — the call is answered from
/// the words on this Mac, which is the only reason a private meeting can be asked about at all.
actor LiveChatRunner {
    private let runtime: URL
    private let model: URL
    private let log: (@Sendable (String) -> Void)?
    private var server: SummarizerServer?

    init(runtime: URL, model: URL, log: (@Sendable (String) -> Void)? = nil) {
        self.runtime = runtime
        self.model = model
        self.log = log
    }

    func ask(_ question: String, transcript: LiveTranscript) async throws -> String {
        if let refusal = LiveChat.refusal(question: question, transcript: transcript) {
            throw LiveChatError.refused(refusal)
        }
        return try await complete(
            system: LiveChat.systemPrompt(),
            user: LiveChat.userPrompt(
                question: question,
                transcript: transcript.tail(maxCharacters: LiveChat.maximumContextCharacters)
            ),
            maxTokens: LiveChat.answerTokenBudget
        )
    }

    /// Answers one prompt from the model the window shares.
    ///
    /// The server is started the first time either the summary or a question needs it, and kept
    /// until the recording ends: loading a 4B model takes seconds, and a summary every minute would
    /// pay that cost every minute without this.
    private func complete(system: String, user: String, maxTokens: Int) async throws -> String {
        let server = try await readyServer()
        let request = SummarizerRequest(
            messages: [
                .init(role: "system", content: system),
                .init(role: "user", content: user),
            ],
            // A low temperature rather than zero: the answer is read while people are talking, and
            // it is worth more as a slightly different sentence than as the same one twice.
            temperature: 0.2,
            maxTokens: maxTokens,
            chatTemplateKwargs: SummarizerRequest.plainAnswer
        )
        let answer: String
        do {
            answer = try await server.completion(body: request, timeout: 240, cancellation: nil)
        } catch let error as SummarizerError {
            throw LiveChatError.model(error)
        } catch {
            throw LiveChatError.model(.requestFailed(error.localizedDescription))
        }
        let text = Summarizer.withoutReasoning(answer)
        guard !text.isEmpty else { throw LiveChatError.empty }
        return text
    }

    func stop() async {
        server?.stop()
        server = nil
    }

    private func readyServer() async throws -> SummarizerServer {
        if let server { return server }
        let started: SummarizerServer
        do {
            started = try SummarizerServer(
                executable: runtime,
                model: model,
                // Enough room for the transcript tail the window sends and the answer it asks for,
                // and no more: the cache a larger context reserves is memory the recording can use.
                contextTokens: 8_192,
                log: log
            )
            try await started.waitUntilReady(timeout: 180, cancellation: nil)
        } catch let error as SummarizerError {
            throw LiveChatError.model(error)
        } catch {
            throw LiveChatError.model(.serverDidNotStart(error.localizedDescription))
        }
        server = started
        return started
    }
}
