import CallRecorderCore
import Foundation
import Testing
@testable import CallRecorderApp

/// A URLProtocol that answers from a closure, so the remote reader's request and answer handling
/// can be checked without a network or a model.
private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var delay: TimeInterval = 0

    private let lock = NSLock()
    private var stopped = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        let work = { [weak self] in
            guard let self, !self.isStopped else { return }
            guard let handler = Self.handler else {
                self.client?.urlProtocol(self, didFailWithError: URLError(.unknown))
                return
            }
            do {
                let (response, data) = try handler(self.request)
                guard !self.isStopped else { return }
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                self.client?.urlProtocol(self, didLoad: data)
                self.client?.urlProtocolDidFinishLoading(self)
            } catch {
                guard !self.isStopped else { return }
                self.client?.urlProtocol(self, didFailWithError: error)
            }
        }
        if Self.delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.delay, execute: work)
        } else {
            work()
        }
    }

    override func stopLoading() {
        lock.lock()
        stopped = true
        lock.unlock()
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }
}

private func stubbedSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: configuration)
}

private func respond(
    status: Int,
    body: String,
    to request: URLRequest
) throws -> (HTTPURLResponse, Data) {
    let response = try #require(
        HTTPURLResponse(
            url: request.url ?? URL(string: "http://stub")!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )
    )
    return (response, Data(body.utf8))
}

private let remoteAnswer = """
    {
      "text": " Привет, это тест. We shipped the order.",
      "language": "russian",
      "duration": 3.25,
      "model": "large-v3",
      "segments": [
        { "id": 0, "start": 0.0, "end": 1.5, "text": " Привет, это тест." },
        { "id": 1, "start": 1.5, "end": 3.25, "text": " We shipped the order." }
      ]
    }
    """

@Suite("Remote endpoint address")
struct RemoteEndpointAddressTests {
    @Test("a server address gets the OpenAI transcription route")
    func appendsTheRoute() throws {
        let base = RemoteSpeechConfiguration(baseURL: "http://100.127.247.60:8099")
        #expect(try base.endpointURL().absoluteString == "http://100.127.247.60:8099/v1/audio/transcriptions")

        let trailing = RemoteSpeechConfiguration(baseURL: "http://100.127.247.60:8099/")
        #expect(try trailing.endpointURL().absoluteString == "http://100.127.247.60:8099/v1/audio/transcriptions")

        let versioned = RemoteSpeechConfiguration(baseURL: "https://api.example.com/v1")
        #expect(try versioned.endpointURL().absoluteString == "https://api.example.com/v1/audio/transcriptions")

        let full = RemoteSpeechConfiguration(baseURL: "https://proxy.example.com/speech/v1/audio/transcriptions")
        #expect(
            try full.endpointURL().absoluteString
                == "https://proxy.example.com/speech/v1/audio/transcriptions"
        )
    }

    @Test("a query or fragment never reaches the request")
    func dropsTheQuery() throws {
        let address = RemoteSpeechConfiguration(baseURL: "https://host:9/?key=not-the-token#frag")
        #expect(try address.endpointURL().absoluteString == "https://host:9/v1/audio/transcriptions")
    }

    @Test("an address that cannot be posted to is refused with its own sentence")
    func refusesWhatIsNotHTTP() {
        #expect(throws: RemoteSpeechError.missingAddress) {
            try RemoteSpeechConfiguration(baseURL: "  ").endpointURL()
        }
        #expect(throws: RemoteSpeechError.self) {
            try RemoteSpeechConfiguration(baseURL: "ftp://host/audio").endpointURL()
        }
        #expect(throws: RemoteSpeechError.self) {
            try RemoteSpeechConfiguration(baseURL: "not an address").endpointURL()
        }
    }

    @Test("plain http is kept to a private network, and a public server must use https")
    func holdsPublicAddressesToHTTPS() throws {
        for address in [
            "http://100.127.247.60:8099",
            "http://10.0.0.4:8099",
            "http://172.16.4.2:8099",
            "http://192.168.1.9:8099",
            "http://localhost:8099",
            "http://studio.local:8099",
            "http://studio.tail1234.ts.net",
        ] {
            _ = try RemoteSpeechConfiguration(baseURL: address).endpointURL()
        }
        for address in [
            "http://example.com",
            "http://172.32.0.1:8099",
            "http://100.128.0.1:8099",
        ] {
            #expect(throws: RemoteSpeechError.insecureAddress) {
                try RemoteSpeechConfiguration(baseURL: address).endpointURL()
            }
        }
        _ = try RemoteSpeechConfiguration(baseURL: "https://api.example.com").endpointURL()
    }
}

@Suite("Remote verbose answer")
struct RemoteTranscriptMappingTests {
    @Test("timed segments become milliseconds on the call's clock")
    func mapsTimedSegments() throws {
        let transcript = try RemoteTranscriptMapper.transcript(
            from: Data(remoteAnswer.utf8),
            requestedLanguage: "auto",
            model: "large-v3"
        )

        #expect(transcript.language == "ru")
        #expect(transcript.segments.count == 2)
        #expect(transcript.segments[0].startMs == 0)
        #expect(transcript.segments[0].endMs == 1_500)
        #expect(transcript.segments[1].startMs == 1_500)
        #expect(transcript.segments[1].endMs == 3_250)
        #expect(transcript.segments[1].text == "We shipped the order.")
        #expect(transcript.reader == "Remote endpoint (large-v3)")
    }

    @Test("a text-only answer with a duration becomes one timed turn")
    func placesTextWithoutSegments() throws {
        let answer = """
            { "text": "Hello from the endpoint.", "language": "english", "duration": 12.5 }
            """
        let transcript = try RemoteTranscriptMapper.transcript(
            from: Data(answer.utf8),
            requestedLanguage: "auto",
            model: "whisper-1"
        )
        #expect(transcript.language == "en")
        #expect(transcript.segments.count == 1)
        #expect(transcript.segments[0].endMs == 12_500)
    }

    @Test("words without times and without a duration are refused")
    func refusesUntimedWords() {
        let answer = #"{ "text": "Words with nothing to place them by." }"#
        #expect(throws: RemoteSpeechError.untimedAnswer) {
            try RemoteTranscriptMapper.transcript(
                from: Data(answer.utf8),
                requestedLanguage: "auto",
                model: "m"
            )
        }
    }

    @Test("silence answers with an empty transcript rather than a fault")
    func keepsSilenceEmpty() throws {
        let transcript = try RemoteTranscriptMapper.transcript(
            from: Data(#"{ "text": "", "language": "en", "segments": [] }"#.utf8),
            requestedLanguage: "auto",
            model: "m"
        )
        #expect(transcript.segments.isEmpty)
        #expect(transcript.language == "en")
    }

    @Test("a document that is not verbose JSON is refused")
    func refusesGarbage() {
        #expect(throws: RemoteSpeechError.self) {
            try RemoteTranscriptMapper.transcript(
                from: Data("not json".utf8),
                requestedLanguage: "auto",
                model: "m"
            )
        }
    }
}

@Suite("Remote request")
struct RemoteSpeechRequestTests {
    private let configuration = RemoteSpeechConfiguration(
        baseURL: "http://127.0.0.1:8099",
        model: "large-v3",
        token: "secret-token",
        timeoutSeconds: 42
    )

    @Test("the body carries the file and the contract's fields")
    func buildsTheMultipartBody() throws {
        let request = try RemoteSpeechRequest.transcription(
            configuration: configuration,
            audio: Data([0x01, 0x02]),
            filename: "audio.wav",
            language: "ru",
            hotwords: ["Floship", "warehouse"],
            boundary: "BOUNDARY"
        )
        let body = try #require(request.httpBody)
        let text = try #require(String(data: body, encoding: .utf8))

        #expect(request.url?.absoluteString == "http://127.0.0.1:8099/v1/audio/transcriptions")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "multipart/form-data; boundary=BOUNDARY")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-token")
        #expect(request.timeoutInterval == 42)
        #expect(text.contains(#"name="file"; filename="audio.wav""#))
        #expect(text.contains(#"name="model""#))
        #expect(text.contains("large-v3"))
        #expect(text.contains(#"name="response_format""#))
        #expect(text.contains("verbose_json"))
        #expect(text.contains(#"name="language""#))
        #expect(text.contains(#"name="prompt""#))
        #expect(text.contains("Floship warehouse"))
        #expect(text.hasSuffix("--BOUNDARY--\r\n"))
    }

    @Test("no token means no Authorization header, and auto means no language field")
    func omitsOptionalFields() throws {
        let request = try RemoteSpeechRequest.transcription(
            configuration: RemoteSpeechConfiguration(baseURL: "https://host"),
            audio: Data(),
            filename: "audio.wav",
            language: "auto",
            hotwords: [],
            boundary: "B"
        )
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        let text = try #require(request.httpBody.flatMap { String(data: $0, encoding: .utf8) })
        #expect(!text.contains(#"name="language""#))
        #expect(!text.contains(#"name="prompt""#))
        #expect(!text.contains(#"name="model""#))
    }

    @Test("the connection check sends one second of silence, never a call")
    func checksWithSilence() throws {
        let request = try RemoteSpeechRequest.connectionCheck(
            configuration: configuration,
            boundary: "B"
        )
        let body = try #require(request.httpBody)
        let text = String(decoding: body, as: UTF8.self)
        #expect(text.contains(#"filename="connection-check.wav""#))
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-token")
    }
}

@Suite("Remote reader")
struct RemoteSpeechReaderTests {
    @Test("a 200 verbose answer becomes a placed transcript")
    func readsTheAnswer() async throws {
        StubURLProtocol.handler = { request in try respond(status: 200, body: remoteAnswer, to: request) }
        defer { StubURLProtocol.handler = nil }
        let reader = RemoteSpeechReader(
            configuration: RemoteSpeechConfiguration(baseURL: "http://127.0.0.1:8099"),
            ffmpeg: nil,
            session: stubbedSession()
        )

        let report = try await reader.connectionReport()

        #expect(report.status == 200)
        #expect(report.segmentCount == 2)
        #expect(report.model == "large-v3")
        #expect(report.summary.contains("HTTP 200"))
        #expect(report.summary.contains("model large-v3"))
        #expect(report.summary.contains("2 timed segments"))
    }

    @Test("an HTTP error carries the status and what the endpoint said")
    func reportsHTTPErrors() async {
        StubURLProtocol.handler = { request in
            try respond(status: 401, body: #"{"detail":"invalid token"}"#, to: request)
        }
        defer { StubURLProtocol.handler = nil }
        let reader = RemoteSpeechReader(
            configuration: RemoteSpeechConfiguration(baseURL: "http://127.0.0.1:8099"),
            ffmpeg: nil,
            session: stubbedSession()
        )

        do {
            _ = try await reader.connectionReport()
            Issue.record("a 401 was accepted")
        } catch let error as RemoteSpeechError {
            #expect(error.errorDescription?.contains("HTTP 401") == true)
            #expect(error.errorDescription?.contains("invalid token") == true)
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test("a malformed answer is a fault, not a silent empty call")
    func reportsMalformedAnswers() async {
        StubURLProtocol.handler = { request in
            try respond(status: 200, body: "not json", to: request)
        }
        defer { StubURLProtocol.handler = nil }
        let reader = RemoteSpeechReader(
            configuration: RemoteSpeechConfiguration(baseURL: "http://127.0.0.1:8099"),
            ffmpeg: nil,
            session: stubbedSession()
        )

        do {
            _ = try await reader.connectionReport()
            Issue.record("a malformed answer was accepted")
        } catch let error as RemoteSpeechError {
            #expect(error.errorDescription?.contains("verbose transcription") == true)
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test("a stop from the surface cancels the HTTP request")
    func cancelsTheRequest() async throws {
        // The protocol answers far later than the test waits, so only the cancellation path can
        // end this request.
        StubURLProtocol.handler = { request in try respond(status: 200, body: "{}", to: request) }
        StubURLProtocol.delay = 5
        defer {
            StubURLProtocol.handler = nil
            StubURLProtocol.delay = 0
        }
        let reader = RemoteSpeechReader(
            configuration: RemoteSpeechConfiguration(baseURL: "http://127.0.0.1:8099"),
            ffmpeg: nil,
            session: stubbedSession()
        )
        let cancellation = ProcessCancellation()
        let task = Task {
            try await reader.connectionReport(cancellation: cancellation)
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        cancellation.cancel()

        do {
            _ = try await task.value
            Issue.record("a cancelled request answered")
        } catch is CancellationError {
            // The stop is an answer, not a failure.
        } catch {
            Issue.record("a cancelled request reported \(error)")
        }
    }
}

private enum FallbackFailure: Error, Sendable {
    case remote(RemoteSpeechError)
    case localMissing
    case cancelled
}

private struct FallbackReader: SpeechReading {
    var answer: SpeechTranscript?
    var failure: FallbackFailure?
    var calls = Counter()

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
        func increment() {
            lock.lock()
            value += 1
            lock.unlock()
        }
    }

    func transcribe(
        audio: URL,
        language: String,
        hotwords: [String],
        cancellation: ProcessCancellation?
    ) async throws -> SpeechTranscript {
        calls.increment()
        switch failure {
        case .remote(let error): throw error
        case .localMissing: throw QwenEngineError.runtimeMissing
        case .cancelled: throw CancellationError()
        case nil: break
        }
        return answer ?? SpeechTranscript(language: "en", segments: [])
    }
}

@Suite("Speech reader fallback")
struct SpeechReaderFallbackTests {
    private func audio() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "fallback-\(UUID().uuidString).wav")
        try Data([0x00]).write(to: url)
        return url
    }

    @Test("a working endpoint answers, and the local reader is not called")
    func prefersTheEndpoint() async throws {
        let remote = FallbackReader(
            answer: SpeechTranscript(
                language: "ru",
                segments: [TranscriptSegment(startMs: 0, endMs: 1_000, text: "Привет")],
                reader: "Remote endpoint (large-v3)"
            )
        )
        let local = FallbackReader(answer: SpeechTranscript(language: "ru", segments: []))
        let reader = FallbackSpeechReader(remote: remote, local: local)

        let transcript = try await reader.transcribe(
            audio: try audio(),
            language: "auto",
            hotwords: [],
            cancellation: nil
        )

        #expect(transcript.reader == "Remote endpoint (large-v3)")
        #expect(remote.calls.count == 1)
        #expect(local.calls.count == 0)
    }

    @Test("a failed endpoint falls back, and the metadata names the local reader")
    func fallsBackToLocal() async throws {
        let remote = FallbackReader(failure: .remote(.httpStatus(500, "no model")))
        let local = FallbackReader(
            answer: SpeechTranscript(
                language: "en",
                segments: [TranscriptSegment(startMs: 0, endMs: 1_000, text: "Local words")],
                reader: "Qwen3-ASR 1.7B"
            )
        )
        let reader = FallbackSpeechReader(remote: remote, local: local)

        let transcript = try await reader.transcribe(
            audio: try audio(),
            language: "auto",
            hotwords: [],
            cancellation: nil
        )

        #expect(transcript.text == "Local words")
        #expect(transcript.reader == "Qwen3-ASR 1.7B (remote endpoint failed)")
        #expect(remote.calls.count == 1)
        #expect(local.calls.count == 1)
    }

    @Test("a stop is never turned into a local reading")
    func honoursCancellation() async throws {
        let remote = FallbackReader(failure: .cancelled)
        let local = FallbackReader(answer: SpeechTranscript(language: "en", segments: []))
        let reader = FallbackSpeechReader(remote: remote, local: local)

        await #expect(throws: CancellationError.self) {
            _ = try await reader.transcribe(
                audio: try audio(),
                language: "auto",
                hotwords: [],
                cancellation: nil
            )
        }
        #expect(local.calls.count == 0)
    }

    @Test("when both readers fail the message names both")
    func namesBothFailures() async throws {
        let remote = FallbackReader(failure: .remote(.httpStatus(401, "bad token")))
        let local = FallbackReader(failure: .localMissing)
        let reader = FallbackSpeechReader(remote: remote, local: local)

        do {
            _ = try await reader.transcribe(
                audio: try audio(),
                language: "auto",
                hotwords: [],
                cancellation: nil
            )
            Issue.record("two failures were reported as a reading")
        } catch {
            #expect(error.localizedDescription.contains("HTTP 401"))
            #expect(error.localizedDescription.contains("speech runtime is missing"))
        }
    }
}

@Suite("Remote settings")
struct RemoteSpeechSettingsTests {
    @Test("the reader and endpoint survive a save")
    func settingsRoundTrip() throws {
        var settings = AppSettings.default
        settings.speechReader = .remote
        settings.remoteSpeechURL = "http://100.127.247.60:8099"
        settings.remoteSpeechModel = "large-v3"
        settings.remoteSpeechTimeoutSeconds = 900

        let decoded = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONEncoder().encode(settings)
        )

        #expect(decoded == settings)
        #expect(decoded.speechReader == .remote)
        #expect(decoded.remoteSpeechURL == "http://100.127.247.60:8099")
        #expect(decoded.remoteSpeechModel == "large-v3")
        #expect(decoded.remoteSpeechTimeoutSeconds == 900)
    }

    @Test("a settings blob from before the choice reads locally")
    func legacySettingsStayLocal() throws {
        let legacy = """
            { "selectedMicrophoneID": "Yeti", "transcriptionLanguage": "ru" }
            """
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(legacy.utf8))
        #expect(decoded.speechReader == .local)
        #expect(decoded.remoteSpeechURL.isEmpty)
        #expect(decoded.selectedMicrophoneID == "Yeti")
    }

    @Test("an unreadable reader or timeout costs only that choice")
    func damagedValuesFallBackAlone() throws {
        let damaged = """
            {
              "selectedMicrophoneID": "Yeti",
              "speechReader": "satellite",
              "remoteSpeechTimeoutSeconds": 0
            }
            """
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(damaged.utf8))
        #expect(decoded.speechReader == .local)
        #expect(decoded.remoteSpeechTimeoutSeconds == AppSettings.default.remoteSpeechTimeoutSeconds)
        #expect(decoded.selectedMicrophoneID == "Yeti")
    }

    @Test("the settings blob never carries the token")
    func settingsCarryNoSecret() throws {
        var settings = AppSettings.default
        settings.speechReader = .remote
        settings.remoteSpeechURL = "https://host"
        let json = String(decoding: try JSONEncoder().encode(settings), as: UTF8.self)
        #expect(!json.lowercased().contains("token"))
        #expect(!json.contains("Bearer"))
    }
}
