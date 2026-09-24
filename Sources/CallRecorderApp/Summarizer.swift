import CallRecorderCore
import Darwin
import Foundation

/// What went wrong when a brief could not be written.
enum SummarizerError: LocalizedError, Equatable {
    /// llama.cpp is not installed, so nothing on this Mac can run the model.
    case runtimeUnavailable
    /// The brief model is not downloaded.
    case modelUnavailable
    /// The server started and then stopped, or never answered.
    case serverDidNotStart(String)
    /// The server answered with an error instead of a brief.
    case requestFailed(String)
    /// The server answered, and the answer held no words.
    case answerEmpty

    var errorDescription: String? {
        switch self {
        case .runtimeUnavailable:
            return "The brief model needs llama.cpp, which is not installed. "
                + "Install it with: brew install llama.cpp"
        case .modelUnavailable:
            return "The brief model is not downloaded. Settings -> Summary -> Download."
        case .serverDidNotStart(let detail):
            return "The model did not start: " + detail
        case .requestFailed(let detail):
            return "The model refused the request: " + detail
        case .answerEmpty:
            return "The model wrote nothing. Try again, or choose another model."
        }
    }
}

/// Writes the brief of a call, with a model that runs on this Mac.
///
/// The model is served by llama.cpp rather than loaded in this process. That is on purpose: it can
/// be updated, replaced, or removed by the person whose Mac it is, and a crash inside it takes down
/// a server rather than the app. The server is started for one call and stopped when that call has
/// been written up, so the memory it holds is memory the next recording can have. Nothing here
/// reaches the network: the model file is local, and the only address used is the loopback port the
/// server itself opened.
struct Summarizer: Sendable {
    /// The llama.cpp server binary.
    let runtime: URL
    /// The GGUF file the model was downloaded to.
    let model: URL
    /// The catalog id written beside the brief.
    let modelID: String
    /// How much of the model's context one run may use.
    let contextTokens: Int
    /// How long the server may take to answer the health check on a cold start.
    let startupTimeout: TimeInterval
    /// How long one completion may take.
    let completionTimeout: TimeInterval
    /// Where a failure is explained for a person. Left alone, nothing is recorded.
    var log: (@Sendable (String) -> Void)?

    init(
        runtime: URL,
        model: URL,
        modelID: String = CallBrief.modelID,
        contextTokens: Int = 16_384,
        startupTimeout: TimeInterval = 120,
        completionTimeout: TimeInterval = 600,
        log: (@Sendable (String) -> Void)? = nil
    ) {
        self.runtime = runtime
        self.model = model
        self.modelID = modelID
        self.contextTokens = contextTokens
        self.startupTimeout = startupTimeout
        self.completionTimeout = completionTimeout
        self.log = log
    }

    /// Whether this Mac can write a brief at all, and what is missing when it cannot.
    static func readiness(runtime: URL?, model: URL?) -> SummarizerError? {
        guard runtime != nil else { return .runtimeUnavailable }
        guard model != nil else { return .modelUnavailable }
        return nil
    }

    /// The brief of one call, from a transcript that may be longer than the model can hold.
    ///
    /// A call that fits in one pass is read once. A longer one is read in parts, and the parts are
    /// then written into one brief: dropping the end of a three hour call would lose the decisions
    /// made at the end of it, which are the ones somebody is about to act on.
    func writeBrief(
        transcript: String,
        context: CallContext,
        cancellation: ProcessCancellation? = nil
    ) async throws -> String {
        try cancellation?.checkCancelled()
        let server = try SummarizerServer(
            executable: runtime,
            model: model,
            contextTokens: contextTokens,
            log: log
        )
        defer { server.stop() }
        try await server.waitUntilReady(timeout: startupTimeout, cancellation: cancellation)

        let parts = SummaryTranscript.parts(of: transcript)
        guard parts.count > 1 else {
            return try await ask(
                server: server,
                system: SummaryPrompt.system(),
                user: SummaryPrompt.user(transcript: transcript, context: context),
                cancellation: cancellation
            )
        }
        log?("brief: a long call, read in " + String(parts.count) + " parts")
        var briefs: [String] = []
        for (index, part) in parts.enumerated() {
            try cancellation?.checkCancelled()
            briefs.append(
                try await ask(
                    server: server,
                    system: SummaryPrompt.system(),
                    user: SummaryPrompt.user(
                        transcript: part,
                        context: context,
                        part: (index: index, count: parts.count)
                    ),
                    cancellation: cancellation
                )
            )
        }
        return try await ask(
            server: server,
            system: SummaryPrompt.system(),
            user: SummaryPrompt.merge(briefs: briefs, context: context),
            cancellation: cancellation
        )
    }

    private func ask(
        server: SummarizerServer,
        system: String,
        user: String,
        cancellation: ProcessCancellation?
    ) async throws -> String {
        try cancellation?.checkCancelled()
        let body = SummarizerRequest(
            messages: [
                .init(role: "system", content: system),
                .init(role: "user", content: user),
            ],
            temperature: CallBrief.temperature,
            maxTokens: CallBrief.maximumTokens,
            chatTemplateKwargs: SummarizerRequest.plainAnswer
        )
        let answer: String
        do {
            answer = try await server.completion(
                body: body,
                timeout: completionTimeout,
                cancellation: cancellation
            )
        } catch let error as SummarizerError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SummarizerError.requestFailed(error.localizedDescription)
        }
        let brief = Self.withoutReasoning(answer)
        guard !brief.isEmpty else { throw SummarizerError.answerEmpty }
        return brief
    }

    /// The answer with any reasoning the model wrote in front of it taken away.
    ///
    /// The request asks the template for a plain answer, and a runtime that follows it generates
    /// no reasoning. This is here for the one that does not: a brief that opens with the model
    /// talking to itself is not a brief. A block that never closes is dropped whole, and an answer
    /// that held nothing else is reported as empty rather than saved.
    static func withoutReasoning(_ text: String) -> String {
        var answer = text
        while let open = answer.range(of: "<think>") {
            if let close = answer.range(of: "</think>", range: open.upperBound..<answer.endIndex) {
                answer.removeSubrange(open.lowerBound..<close.upperBound)
            } else {
                answer.removeSubrange(open.lowerBound..<answer.endIndex)
            }
        }
        return answer.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The request the server is sent, in the shape its API expects.
struct SummarizerRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    let messages: [Message]
    let temperature: Double
    let maxTokens: Int
    let chatTemplateKwargs: [String: Bool]

    /// The template is asked for a plain answer with no reasoning in front of it.
    ///
    /// Qwen3.5 reasons before it answers unless its template is told not to, and reasoning written
    /// into a brief is not a brief. A template that does not read the setting ignores it, so the
    /// request is sent to every model: one swapped in later cannot quietly start writing down its
    /// thoughts.
    static let plainAnswer = ["enable_thinking": false]

    enum CodingKeys: String, CodingKey {
        case messages
        case temperature
        case maxTokens = "max_tokens"
        case chatTemplateKwargs = "chat_template_kwargs"
    }
}

/// The part of the answer this app reads.
struct SummarizerResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String?
        }

        let message: Message
    }

    let choices: [Choice]

    var text: String? { choices.first?.message.content }
}

/// One llama.cpp server, held for the length of one brief.
final class SummarizerServer: @unchecked Sendable {
    let port: Int
    private let process = Process()
    private let logURL: URL
    private let session: URLSession
    private let base: URL
    private let log: (@Sendable (String) -> Void)?

    /// How much prompt cache the server may keep, in MiB.
    ///
    /// llama.cpp's server keeps the state of a prompt it has already processed and restores it when
    /// a later prompt shares a beginning with it, and it will spend up to eight gigabytes of RAM
    /// doing so: that is its own default, and this app never asked for it. The live window holds one
    /// server for a whole call and sends it a prompt every ninety seconds, so on 2026-09-24 that
    /// cache filled to its ceiling over the first hour of a recording -- thirty-three entries of
    /// 230-330 MiB each, for a 4B model whose weights are 2.5 GiB. The server's physical footprint
    /// read 3.7 GiB sixteen minutes in and 9.0 GiB at the hour, where it stopped moving, and 8.1 GiB
    /// of it was host heap that a Mac with no free pages pushed straight into swap.
    ///
    /// Half a gigabyte holds the one entry the window trades between a summary update and a
    /// question, which is the reuse worth paying for, and bounds the rest. The context is left at
    /// what the window needs for the words and the answer.
    static let promptCacheMiB = 512

    init(
        executable: URL,
        model: URL,
        contextTokens: Int,
        log: (@Sendable (String) -> Void)?
    ) throws {
        guard let port = Self.freePort() else {
            throw SummarizerError.serverDidNotStart("this Mac gave it no free port")
        }
        self.port = port
        self.log = log
        self.base = URL(string: "http://127.0.0.1:" + String(port))!
        self.logURL = FileManager.default.temporaryDirectory
            .appending(path: "call-brief-" + UUID().uuidString + ".log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: logURL)
        process.standardOutput = handle
        process.standardError = handle
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 600
        configuration.timeoutIntervalForResource = 3_600
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
        process.executableURL = executable
        process.arguments = Self.arguments(
            model: model,
            contextTokens: contextTokens,
            port: port
        )
        process.environment = Self.environment(from: ProcessInfo.processInfo.environment)
    }

    /// What the server will be started with, read back from the process that will be started.
    ///
    /// These are the whole of what this app asks of a program it does not ship, and a bound that
    /// was set here and then not handed to the process is a bound somebody pays for in memory. Read
    /// from the process rather than kept beside it, so a test sees what the server sees.
    var launchArguments: [String] { process.arguments ?? [] }
    var launchEnvironment: [String: String] { process.environment ?? [:] }

    deinit {
        try? FileManager.default.removeItem(at: logURL)
    }

    /// Starts the server and returns once it answers its health check.
    func waitUntilReady(timeout: TimeInterval, cancellation: ProcessCancellation?) async throws {
        do {
            try process.run()
        } catch {
            throw SummarizerError.serverDidNotStart(error.localizedDescription)
        }
        log?(
            "brief: the model server is up on port " + String(port) + ", holding "
                + String(Self.promptCacheMiB) + " MiB of prompt cache"
        )
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try cancellation?.checkCancelled()
            if !process.isRunning {
                throw SummarizerError.serverDidNotStart(tail())
            }
            if await isHealthy() { return }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw SummarizerError.serverDidNotStart(
            "it did not answer within " + String(Int(timeout)) + " seconds. " + tail()
        )
    }

    /// One completion, or the reason there is none.
    func completion(
        body: SummarizerRequest,
        timeout: TimeInterval,
        cancellation: ProcessCancellation?
    ) async throws -> String {
        var request = URLRequest(url: base.appending(path: "v1/chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout
        request.httpBody = try JSONEncoder().encode(body)
        do {
            let (data, response) = try await session.data(for: request)
            try cancellation?.checkCancelled()
            guard let http = response as? HTTPURLResponse else {
                throw SummarizerError.requestFailed("the answer was not HTTP")
            }
            guard (200..<300).contains(http.statusCode) else {
                let text = String(data: data, encoding: .utf8) ?? ""
                throw SummarizerError.requestFailed(
                    "HTTP " + String(http.statusCode) + ": "
                        + DiagnosticsReporter.redacted(error: String(text.prefix(400)))
                )
            }
            guard let decoded = try? JSONDecoder().decode(SummarizerResponse.self, from: data),
                let text = decoded.text
            else {
                throw SummarizerError.answerEmpty
            }
            return text
        } catch let error as SummarizerError {
            throw error
        }
    }

    /// Ends the server, and the memory it holds.
    func stop() {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning, Date() < deadline {
            usleep(50_000)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }

    private func isHealthy() async -> Bool {
        var request = URLRequest(url: base.appending(path: "health"))
        request.timeoutInterval = 2
        guard let (data, response) = try? await session.data(for: request),
            let http = response as? HTTPURLResponse,
            http.statusCode == 200
        else { return false }
        return String(data: data, encoding: .utf8)?.contains("ok") ?? false
    }

    /// The end of what the server wrote, for a failure that has to explain itself.
    private func tail() -> String {
        let text = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        let lines = text.split(separator: "\n").suffix(4).joined(separator: " | ")
        return lines.isEmpty ? "it wrote nothing." : DiagnosticsReporter.redacted(error: lines)
    }

    /// What the server is asked to run.
    static func arguments(model: URL, contextTokens: Int, port: Int) -> [String] {
        [
            "--model", model.path,
            "--host", "127.0.0.1",
            "--port", String(port),
            "--ctx-size", String(contextTokens),
            "--no-webui",
            // One slot: the briefs of one call are written one after another, and a second slot
            // would reserve a second copy of the context for an answer nobody waits for.
            "--parallel", "1",
        ]
    }

    /// The environment the server is started in: everything this app has, and the cache ceiling.
    ///
    /// The ceiling is passed as a variable rather than as `--cache-ram`, which is the same setting
    /// by another name: llama.cpp reads `LLAMA_ARG_CACHE_RAM` as the default for that option, while
    /// a llama-server older than the option ignores a variable it does not know and starts anyway.
    /// An unknown argument is not ignored -- the server refuses to start, which would take the
    /// brief and the live window with it -- so a setting that only bounds memory is not worth
    /// that risk on a server this app does not ship.
    static func environment(from base: [String: String]) -> [String: String] {
        var environment = base
        environment["LLAMA_ARG_CACHE_RAM"] = String(promptCacheMiB)
        return environment
    }

    /// A port nothing is listening on, asked for by binding one and letting it go.
    ///
    /// The kernel hands out a port only when asked this way, so the number is free at the moment it
    /// is chosen. The server takes it a moment later, and if something else takes it in between,
    /// the server says so and the brief fails with that message rather than a wrong one.
    static func freePort() -> Int? {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { return nil }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard named == 0 else { return nil }
        return Int(UInt16(bigEndian: actual.sin_port))
    }
}
