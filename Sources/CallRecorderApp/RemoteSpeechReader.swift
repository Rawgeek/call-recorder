import CallRecorderCore
import Foundation
import OSLog

/// What one connection check saw the endpoint answer.
struct RemoteConnectionReport: Equatable, Sendable {
    let status: Int
    let seconds: Double
    let model: String?
    let language: String?
    let segmentCount: Int

    /// Plain wording for the row that asked. It reports the answer rather than a verdict, because
    /// a 200 from a server with no model loaded is not a working reader.
    var summary: String {
        let modelName = model?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawParts: [String?] = [
            "HTTP \(status)",
            String(format: "%.1f s", seconds),
            modelName.flatMap { $0.isEmpty ? nil : "model \($0)" },
            language.flatMap { $0.isEmpty ? nil : "language \($0)" },
            "\(segmentCount) timed \(segmentCount == 1 ? "segment" : "segments")",
        ]
        let parts = rawParts.compactMap { $0 }
        return parts.joined(separator: " · ")
    }
}

/// Reads a recording through an OpenAI-compatible transcription endpoint.
///
/// The endpoint receives the same 16 kHz mono wave the local model reads. Its verbose JSON answer
/// is placed on the call's clock by the same mapper the decoder uses, so a call read remotely is
/// indistinguishable to the rest of the pipeline from one read locally, apart from the reader
/// named in its metadata.
///
/// A stop asked for from the surface cancels the HTTP request itself. Waiting on a flag and then
/// throwing would leave the upload running, and a three-minute call would keep sending after the
/// person pressed Stop.
struct RemoteSpeechReader: SpeechReading {
    let configuration: RemoteSpeechConfiguration
    let ffmpeg: URL?
    let session: URLSession
    private let logger = Logger(subsystem: "local.callrecorder.app", category: "remote-speech")

    init(
        configuration: RemoteSpeechConfiguration,
        ffmpeg: URL?,
        session: URLSession = .shared
    ) {
        self.configuration = configuration
        self.ffmpeg = ffmpeg
        self.session = session
    }

    func transcribe(
        audio: URL,
        language: String,
        hotwords: [String],
        cancellation: ProcessCancellation?
    ) async throws -> SpeechTranscript {
        try cancellation?.checkCancelled()
        guard let ffmpeg else { throw RemoteSpeechError.missingFFmpeg }
        let converted = try SpeechWaveConverter.convert(
            audio: audio,
            ffmpeg: ffmpeg,
            cancellation: cancellation
        )
        defer { try? FileManager.default.removeItem(at: converted.work) }

        let payload = try Data(contentsOf: converted.wave, options: .mappedIfSafe)
        let request = try RemoteSpeechRequest.transcription(
            configuration: configuration,
            audio: payload,
            filename: converted.wave.lastPathComponent,
            language: language,
            hotwords: hotwords
        )
        let started = Date()
        let (data, status) = try await send(request, cancellation: cancellation)
        guard (200..<300).contains(status) else {
            throw RemoteSpeechError.httpStatus(status, Self.excerpt(of: data))
        }
        let model = Self.answeredModel(in: data) ?? configuration.model
        let transcript = try RemoteTranscriptMapper.transcript(
            from: data,
            requestedLanguage: language,
            model: model
        )
        logger.notice(
            "read \(audio.lastPathComponent, privacy: .public) remotely in \(Date().timeIntervalSince(started), privacy: .public)s into \(transcript.segments.count, privacy: .public) pieces"
        )
        return transcript
    }

    /// Posts one second of silence and reports the endpoint's actual answer.
    func connectionReport(
        cancellation: ProcessCancellation? = nil
    ) async throws -> RemoteConnectionReport {
        let request = try RemoteSpeechRequest.connectionCheck(configuration: configuration)
        let started = Date()
        let (data, status) = try await send(request, cancellation: cancellation)
        let seconds = Date().timeIntervalSince(started)
        guard (200..<300).contains(status) else {
            throw RemoteSpeechError.httpStatus(status, Self.excerpt(of: data))
        }
        let document: RemoteTranscriptDocument
        do {
            document = try JSONDecoder().decode(RemoteTranscriptDocument.self, from: data)
        } catch {
            throw RemoteSpeechError.malformedAnswer(error.localizedDescription)
        }
        guard
            document.text != nil || document.segments != nil || document.duration != nil
        else {
            throw RemoteSpeechError.malformedAnswer(
                "the answer holds no text, segments, or duration"
            )
        }
        return RemoteConnectionReport(
            status: status,
            seconds: seconds,
            model: document.model,
            language: document.language,
            segmentCount: document.segments?.count ?? 0
        )
    }

    /// Sends the request, and turns a stop from the surface into a cancelled request.
    private func send(
        _ request: URLRequest,
        cancellation: ProcessCancellation?
    ) async throws -> (Data, Int) {
        try cancellation?.checkCancelled()
        let work = Task { try await session.data(for: request) }
        // URLSession stops on Swift task cancellation. The app's stop is a flag a process polls,
        // so the flag is watched here and the task is cancelled when it is set, which cancels the
        // upload rather than only the caller's wait for it.
        let monitor = Task {
            while !Task.isCancelled {
                if cancellation?.isCancelled == true {
                    work.cancel()
                    return
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        defer { monitor.cancel() }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await work.value
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            if cancellation?.isCancelled == true || error.code == .cancelled {
                throw CancellationError()
            }
            throw RemoteSpeechError.unreachable(error.localizedDescription)
        } catch {
            if cancellation?.isCancelled == true { throw CancellationError() }
            throw RemoteSpeechError.unreachable(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw RemoteSpeechError.malformedAnswer("the answer was not an HTTP response")
        }
        return (data, http.statusCode)
    }

    /// The model name in the answer, when the endpoint names one.
    private static func answeredModel(in data: Data) -> String? {
        guard
            let document = try? JSONDecoder().decode(RemoteTranscriptDocument.self, from: data),
            let model = document.model?.trimmingCharacters(in: .whitespacesAndNewlines),
            !model.isEmpty
        else { return nil }
        return model
    }

    /// The start of an error body, said once and without a whole document in the row.
    private static func excerpt(of data: Data) -> String {
        guard let text = String(data: data, encoding: .utf8) else { return "" }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 300 else { return trimmed }
        return String(trimmed.prefix(300)) + "…"
    }
}

/// Why neither reader could read a call, when the remote endpoint was tried first.
enum SpeechReaderFallbackError: LocalizedError, Equatable {
    case bothFailed(remote: String, local: String)

    var errorDescription: String? {
        switch self {
        case .bothFailed(let remote, let local):
            "The remote endpoint failed (\(remote)) and the local reader could not read the call "
                + "either (\(local)). Fix the endpoint in Settings, Models, Speech reader, or "
                + "install the local model there."
        }
    }
}

/// Tries the remote endpoint, then the local reader.
///
/// Falling back is a decision about one reading rather than a change to the setting: the next call
/// tries the endpoint again. The reader recorded on the transcript names the one that answered, so
/// a call that fell back does not claim it was read remotely.
struct FallbackSpeechReader: SpeechReading {
    let remote: any SpeechReading
    let local: any SpeechReading
    private let logger = Logger(subsystem: "local.callrecorder.app", category: "remote-speech")

    func transcribe(
        audio: URL,
        language: String,
        hotwords: [String],
        cancellation: ProcessCancellation?
    ) async throws -> SpeechTranscript {
        do {
            return try await remote.transcribe(
                audio: audio,
                language: language,
                hotwords: hotwords,
                cancellation: cancellation
            )
        } catch {
            if error is CancellationError || cancellation?.isCancelled == true {
                throw CancellationError()
            }
            logger.notice(
                "the remote reader failed; reading this track locally: \(error.localizedDescription, privacy: .public)"
            )
            do {
                let transcript = try await local.transcribe(
                    audio: audio,
                    language: language,
                    hotwords: hotwords,
                    cancellation: cancellation
                )
                let localName = transcript.reader ?? "Local reader"
                return transcript.readBy("\(localName) (remote endpoint failed)")
            } catch let localError {
                if localError is CancellationError || cancellation?.isCancelled == true {
                    throw CancellationError()
                }
                throw SpeechReaderFallbackError.bothFailed(
                    remote: error.localizedDescription,
                    local: localError.localizedDescription
                )
            }
        }
    }
}
