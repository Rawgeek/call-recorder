import CallRecorderCore
import Darwin
import Foundation

/// Why a chunk of live audio could not be read.
enum LiveTranscriptionError: LocalizedError, Equatable {
    case whisperServerUnavailable
    case modelUnavailable(String)
    case serverDidNotStart(String)
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .whisperServerUnavailable:
            "Live text needs whisper.cpp, which is not installed. Install it with: brew install "
                + "whisper-cpp"
        case let .modelUnavailable(name):
            "The transcription model \"" + name + "\" is not downloaded, so live text cannot run. "
                + "Settings, Models downloads it."
        case let .serverDidNotStart(detail):
            "The live transcriber did not start: " + detail
        case let .requestFailed(detail):
            "The live transcriber could not read a chunk: " + detail
        }
    }
}

/// A thing that can turn one WAV file into whisper.cpp's JSON.
///
/// The transport is a protocol so the queue, the ordering, and the decoding can be checked without
/// a model, a process, or a call: a test hands over a stub that answers with bytes of its choosing.
protocol LiveTranscriptionTransport: Sendable {
    /// Brings whatever the transport needs into existence, or returns when it is already there.
    func start() async throws
    func transcribe(audioAt url: URL, prompt: String, language: String?) async throws -> Data
    func stop() async
}

/// One `whisper-server`, held for the length of one recording.
///
/// A process rather than a call per chunk, because the model is the expensive part: loading
/// large-v3-turbo costs seconds and hundreds of megabytes, and doing that every fifteen seconds of
/// a two hour call would spend the machine on nothing. The server is started when the recording
/// starts and stopped the moment it ends, before the finished call is transcribed — two copies of
/// the same model in memory at once is the waste amanu's notes warn about.
final class LiveTranscriptionServer: LiveTranscriptionTransport, @unchecked Sendable {
    private let process = Process()
    private let port: Int
    private let session: URLSession
    private let logURL: URL
    private let label: String
    private let lock = NSLock()
    private var startTask: Task<Void, any Error>?
    private var stopRequested = false

    /// - Parameters:
    ///   - executable: the `whisper-server` binary.
    ///   - model: the GGUF model file, already verified by the model manager.
    ///   - prompt: the names and terms to spell correctly, built the way the batch run builds it.
    init(executable: URL, model: URL, prompt: String) throws {
        guard let port = SummarizerServer.freePort() else {
            throw LiveTranscriptionError.serverDidNotStart("this Mac gave it no free port")
        }
        self.port = port
        label = model.deletingPathExtension().lastPathComponent
        logURL = FileManager.default.temporaryDirectory
            .appending(path: "live-transcriber-" + UUID().uuidString + ".log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: logURL)
        process.standardOutput = handle
        process.standardError = handle
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 300
        configuration.timeoutIntervalForResource = 900
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
        process.executableURL = executable
        process.arguments = [
            "-m", model.path,
            // Auto rather than a fixed language: a call can be in any language, and the batch run
            // makes the same choice. The first confident detection is kept for the rest of the call
            // by the transcriber above, which is what stops a short chunk of numbers being read as
            // another language halfway through a meeting.
            "-l", "auto",
            "--host", "127.0.0.1",
            "--port", String(port),
            "--prompt", prompt,
        ]
    }

    deinit {
        try? FileManager.default.removeItem(at: logURL)
    }

    /// Starts the server once and waits for it to answer.
    ///
    /// The same start is asked for by the recording's first moment and by the first chunk that is
    /// ready, so the work is shared: one task is kept and every caller waits on it.
    func start() async throws {
        let task: Task<Void, any Error> = lock.withLock {
            if let startTask { return startTask }
            let task = Task { try await self.launchAndWait() }
            startTask = task
            return task
        }
        try await task.value
    }

    private func launchAndWait() async throws {
        // A stop that landed before the launch is a stop: the call it belonged to is over, and a
        // server started now would be one nobody is left to shut down.
        if lock.withLock({ stopRequested }) { return }
        do {
            try process.run()
        } catch {
            throw LiveTranscriptionError.serverDidNotStart(error.localizedDescription)
        }
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            if lock.withLock({ stopRequested }) { return }
            if !process.isRunning {
                throw LiveTranscriptionError.serverDidNotStart(tail())
            }
            if await isAnswering() { return }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw LiveTranscriptionError.serverDidNotStart(
            "it did not answer within three minutes. " + tail()
        )
    }

    func transcribe(audioAt url: URL, prompt: String, language: String?) async throws -> Data {
        try await start()
        let boundary = "callrecorder-" + UUID().uuidString
        var fields: [(String, String)] = [("response_format", "verbose_json")]
        // Zero temperature for the same reason the batch run uses it: a call is a record, not a
        // place for the model to be creative, and the setting makes two runs of one chunk agree.
        fields.append(("temperature", "0"))
        if !prompt.isEmpty { fields.append(("prompt", prompt)) }
        if let language, !language.isEmpty { fields.append(("language", language)) }
        let body = try Self.multipartBody(
            boundary: boundary,
            file: url,
            fields: fields,
            audio: try Data(contentsOf: url)
        )
        var request = URLRequest(url: base.appending(path: "inference"))
        request.httpMethod = "POST"
        request.setValue(
            "multipart/form-data; boundary=" + boundary,
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = body
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw LiveTranscriptionError.requestFailed("the answer was not HTTP")
            }
            guard (200..<300).contains(http.statusCode) else {
                let text = String(decoding: data, as: UTF8.self)
                throw LiveTranscriptionError.requestFailed(
                    "HTTP " + String(http.statusCode) + ": "
                        + DiagnosticsReporter.redacted(error: String(text.prefix(300)))
                )
            }
            return data
        } catch let error as LiveTranscriptionError {
            throw error
        } catch {
            throw LiveTranscriptionError.requestFailed(error.localizedDescription)
        }
    }

    /// Ends the server and the memory it holds.
    func stop() async {
        lock.withLock { stopRequested = true }
        guard process.isRunning else { return }
        ProcessRunner.end(process)
    }

    private var base: URL { URL(string: "http://127.0.0.1:" + String(port))! }

    /// Whether the server is listening yet.
    ///
    /// The port is bound after the model is loaded, so an answer here means the next request is
    /// read rather than refused — which is the whole reason the start waits for it.
    private func isAnswering() async -> Bool {
        var request = URLRequest(url: base)
        request.timeoutInterval = 2
        guard let (_, response) = try? await session.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    /// The end of what the server wrote, for a failure that has to explain itself.
    private func tail() -> String {
        let text = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        let lines = text.split(separator: "\n").suffix(4).joined(separator: " | ")
        return lines.isEmpty ? "it wrote nothing." : DiagnosticsReporter.redacted(error: lines)
    }

    /// The body of one chunk upload.
    static func multipartBody(
        boundary: String,
        file: URL,
        fields: [(String, String)],
        audio: Data
    ) throws -> Data {
        var body = Data()
        func append(_ text: String) { body.append(contentsOf: Array(text.utf8)) }
        for (name, value) in fields {
            append("--" + boundary + "\r\n")
            append("Content-Disposition: form-data; name=\"" + name + "\"\r\n\r\n")
            append(value + "\r\n")
        }
        append("--" + boundary + "\r\n")
        append(
            "Content-Disposition: form-data; name=\"file\"; filename=\""
                + file.lastPathComponent + "\"\r\n"
        )
        append("Content-Type: audio/wav\r\n\r\n")
        body.append(audio)
        append("\r\n--" + boundary + "--\r\n")
        return body
    }
}

/// Ends live servers an earlier launch left behind.
///
/// A live server is a child process, and a child outlives a parent that was force quit: the model
/// stays in memory and the port stays taken until the machine is restarted or somebody notices. At
/// launch nothing of ours is recording, so a `whisper-server` holding one of this app's own model
/// files is one of ours that was left behind, and it goes.
///
/// Only a server is matched, and only by the folder its model came from: the same folder feeds the
/// one-shot transcriber that writes a call's transcript, and that process is finished work rather
/// than a leftover — ending it would throw away a call that was already recorded.
enum LiveServerCleanup {
    /// Ends live transcribers an earlier launch left behind.
    static func endOrphanedTranscribers(whisperModelDirectory: URL) {
        end(matching: [
            "whisper-server.*" + NSRegularExpression.escapedPattern(for: whisperModelDirectory.path)
        ])
    }

    /// Ends every model server this app can have started, for the moment it quits.
    ///
    /// A brief is written by `llama-server` and the live window by `whisper-server`; both are
    /// children, and both hold gigabytes. Only those two programs are matched, and only when they
    /// hold one of this app's own model files, so nothing else on the machine is touched.
    static func endServersOnQuit(whisperModelDirectory: URL, briefModel: URL?) {
        var patterns = [
            "whisper-server.*" + NSRegularExpression.escapedPattern(for: whisperModelDirectory.path)
        ]
        if let briefModel {
            patterns.append(
                "llama-server.*" + NSRegularExpression.escapedPattern(for: briefModel.path)
            )
        }
        end(matching: patterns)
    }

    private static func end(matching patterns: [String]) {
        for pattern in patterns {
            for pid in processIdentifiers(matching: pattern) {
                kill(pid, SIGTERM)
            }
        }
    }

    private static func processIdentifiers(matching pattern: String) -> [pid_t] {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/pgrep")
        process.arguments = ["-f", pattern]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(whereSeparator: { $0.isNewline })
            .compactMap { pid_t($0) }
            .filter { $0 != getpid() }
    }
}
