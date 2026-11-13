import Foundation
import Security

/// Which reader turns a recording into words.
public enum SpeechReaderChoice: String, CaseIterable, Codable, Identifiable, Sendable {
    /// Qwen3-ASR, run by the Python environment beside the app's models.
    case local
    /// An OpenAI-compatible transcription endpoint. Audio leaves this Mac when it is chosen.
    case remote

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .local: "Local model"
        case .remote: "Remote endpoint"
        }
    }
}

/// Everything one remote reading needs: where to send it, what to call the model, and how long to
/// wait.
public struct RemoteSpeechConfiguration: Equatable, Sendable {
    public let baseURL: String
    public let model: String
    public let token: String
    public let timeoutSeconds: Double

    public init(
        baseURL: String,
        model: String = "",
        token: String = "",
        timeoutSeconds: Double = 600
    ) {
        self.baseURL = baseURL
        self.model = model
        self.token = token
        self.timeoutSeconds = timeoutSeconds
    }

    /// Whether there is an address to send to at all.
    public var isConfigured: Bool {
        !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The address a transcription request is posted to.
    ///
    /// A server address, a server address ending in /v1, and the full route are all accepted, so
    /// the field can hold what a person was given without asking them to know the route.
    public func endpointURL() throws -> URL {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw RemoteSpeechError.missingAddress }
        guard
            var components = URLComponents(string: trimmed),
            let scheme = components.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            components.host?.isEmpty == false
        else {
            throw RemoteSpeechError.invalidAddress(trimmed)
        }
        // A private server usually has no certificate and is reached by an address ATS cannot
        // except, which is why the app allows plain http at all. A public address is held to
        // https: the audio of a confidential call is not sent in the clear across the internet.
        if scheme == "http", let host = components.host, !Self.isPrivateHost(host) {
            throw RemoteSpeechError.insecureAddress
        }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        if path.hasSuffix("/v1/audio/transcriptions") || path.hasSuffix("/audio/transcriptions") {
            // Already the route. Left as written so a proxy can publish it somewhere else.
        } else if path.hasSuffix("/v1") {
            path += "/audio/transcriptions"
        } else {
            path += "/v1/audio/transcriptions"
        }
        components.path = path
        components.query = nil
        components.fragment = nil
        guard let url = components.url else {
            throw RemoteSpeechError.invalidAddress(trimmed)
        }
        return url
    }

    /// Whether a host is on a network the app may speak to in plain http.
    public static func isPrivateHost(_ host: String) -> Bool {
        let name = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if name == "localhost" || name == "::1" { return true }
        for suffix in [".local", ".lan", ".home.arpa", ".ts.net"] where name.hasSuffix(suffix) {
            return true
        }
        if name.contains(":") {
            return name.hasPrefix("fc")
                || name.hasPrefix("fd")
                || name.hasPrefix("fe80")
                || name.hasPrefix("::1")
        }
        let parts = name.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else {
            return false
        }
        switch (parts[0], parts[1]) {
        case (10, _), (127, _), (192, 168), (169, 254):
            return true
        case (172, 16...31):
            return true
        case (100, 64...127):
            // Tailscale's address range, which is where the Mac Studio's endpoint lives.
            return true
        default:
            return false
        }
    }
}

/// Why a remote reading could not be made.
public enum RemoteSpeechError: LocalizedError, Equatable, Sendable {
    case missingAddress
    case invalidAddress(String)
    case insecureAddress
    case missingFFmpeg
    case httpStatus(Int, String)
    case unreachable(String)
    case malformedAnswer(String)
    case untimedAnswer
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .missingAddress:
            return "No remote endpoint is set. Enter one in Settings, Models, Speech reader."
        case .invalidAddress:
            return "The remote endpoint is not an http or https address. Enter a server such as "
                + "http://host:8099."
        case .insecureAddress:
            return "A public endpoint must use https. Plain http is allowed only for a server on "
                + "a private network."
        case .missingFFmpeg:
            return "ffmpeg is missing, so the recording could not be converted for the remote endpoint."
        case .httpStatus(let status, let detail):
            let said = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            return said.isEmpty
                ? "The remote endpoint answered HTTP \(status)."
                : "The remote endpoint answered HTTP \(status): \(said)"
        case .unreachable(let detail):
            return "The remote endpoint could not be reached: \(detail)"
        case .malformedAnswer(let detail):
            return "The remote endpoint answered with a document that is not a verbose transcription: \(detail)"
        case .untimedAnswer:
            return "The remote endpoint returned words without times, so they cannot be placed in the call."
        case .keychain(let status):
            return "The bearer token could not be read from the Keychain (status \(status))."
        }
    }
}

/// The verbose JSON an OpenAI-compatible endpoint answers with.
///
/// Only the fields this app places words by are read. Extra fields an endpoint adds — token ids,
/// probabilities, a top-level text — are ignored rather than making the answer unreadable.
public struct RemoteTranscriptDocument: Decodable, Equatable, Sendable {
    public struct Piece: Decodable, Equatable, Sendable {
        public let start: Double?
        public let end: Double?
        public let text: String

        public init(start: Double?, end: Double?, text: String) {
            self.start = start
            self.end = end
            self.text = text
        }
    }

    public let text: String?
    public let language: String?
    public let duration: Double?
    public let model: String?
    public let segments: [Piece]?

    public init(
        text: String? = nil,
        language: String? = nil,
        duration: Double? = nil,
        model: String? = nil,
        segments: [Piece]? = nil
    ) {
        self.text = text
        self.language = language
        self.duration = duration
        self.model = model
        self.segments = segments
    }
}

/// Places a remote answer on the call's clock.
public enum RemoteTranscriptMapper {
    public static func transcript(
        from data: Data,
        requestedLanguage: String,
        model: String
    ) throws -> SpeechTranscript {
        let document: RemoteTranscriptDocument
        do {
            document = try JSONDecoder().decode(RemoteTranscriptDocument.self, from: data)
        } catch {
            throw RemoteSpeechError.malformedAnswer(error.localizedDescription)
        }
        guard document.text != nil || document.segments != nil || document.duration != nil else {
            throw RemoteSpeechError.malformedAnswer(
                "the answer holds no text, segments, or duration"
            )
        }

        let pieces = (document.segments ?? []).compactMap { piece -> TranscriptSegment? in
            let text = piece.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            guard let start = piece.start, let end = piece.end else { return nil }
            let startMs = max(0, Int((start * 1000).rounded()))
            let endMs = max(startMs, Int((end * 1000).rounded()))
            return TranscriptSegment(startMs: startMs, endMs: endMs, text: text)
        }

        // A word that came back without a time cannot be placed against the diarization. When the
        // answer carries a length the whole reading is still one turn, which is usable; when it
        // does not, the answer is a fault rather than an empty call.
        if pieces.isEmpty {
            let said = (document.text ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if said.isEmpty {
                let answeredText = (document.segments ?? [])
                    .map(\.text)
                    .joined()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard answeredText.isEmpty else { throw RemoteSpeechError.untimedAnswer }
                return SpeechTranscript(
                    language: language(
                        answered: document.language,
                        requested: requestedLanguage,
                        text: ""
                    ),
                    segments: [],
                    reader: readerName(model: model)
                )
            }
            guard let duration = document.duration, duration > 0 else {
                throw RemoteSpeechError.untimedAnswer
            }
            let endMs = max(1, Int((duration * 1000).rounded()))
            return SpeechTranscript(
                language: language(
                    answered: document.language,
                    requested: requestedLanguage,
                    text: said
                ),
                segments: [
                    TranscriptSegment(startMs: 0, endMs: endMs, text: said)
                ],
                reader: readerName(model: model)
            )
        }

        let text = pieces.map(\.text).joined(separator: " ")
        return SpeechTranscript(
            language: language(
                answered: document.language,
                requested: requestedLanguage,
                text: text
            ),
            segments: pieces,
            reader: readerName(model: model)
        )
    }

    /// What the transcript says it was read with, so a call's metadata names its reader.
    public static func readerName(model: String) -> String {
        let name = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Remote endpoint" : "Remote endpoint (\(name))"
    }

    /// The language the endpoint named, as a two-letter code.
    ///
    /// OpenAI writes a name ("english") and this app's own server writes a code ("en"). Both are
    /// answers about the same recording, so both are reduced to the code the rest of the app reads.
    public static func language(
        answered: String?,
        requested: String,
        text: String
    ) -> String {
        let raw = (answered ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if raw.count == 2 { return raw }
        if let known = languageNames[raw] { return known }
        return TranscriptLanguage.naming(requested: requested, text: text)
    }

    private static let languageNames: [String: String] = [
        "english": "en", "eng": "en",
        "russian": "ru", "rus": "ru",
        "ukrainian": "uk", "ukr": "uk",
        "german": "de", "deu": "de", "ger": "de",
        "spanish": "es", "spa": "es",
        "french": "fr", "fra": "fr", "fre": "fr",
        "italian": "it", "ita": "it",
        "portuguese": "pt", "por": "pt",
        "polish": "pl", "pol": "pl",
        "dutch": "nl", "nld": "nl", "dut": "nl",
        "turkish": "tr", "tur": "tr",
        "czech": "cs", "ces": "cs", "cze": "cs",
    ]
}

/// Builds the multipart request an OpenAI-compatible transcription endpoint expects.
public enum RemoteSpeechRequest {
    public static let route = "/v1/audio/transcriptions"

    /// Posts the recording with the fields the reference client sends.
    public static func transcription(
        configuration: RemoteSpeechConfiguration,
        audio: Data,
        filename: String,
        language: String,
        hotwords: [String],
        boundary: String = "----callrecorder" + UUID().uuidString
    ) throws -> URLRequest {
        var fields: [(String, String)] = [("response_format", "verbose_json")]
        let model = configuration.model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !model.isEmpty { fields.insert(("model", model), at: 0) }
        let code = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if code.count == 2, code != "au", code != "nn" {
            fields.append(("language", code))
        }
        let prompt =
            hotwords
            .map { $0.replacingOccurrences(of: ",", with: " ") }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !prompt.isEmpty { fields.append(("prompt", prompt)) }
        return try request(
            configuration: configuration,
            body: multipartBody(
                audio: audio,
                filename: filename,
                fields: fields,
                boundary: boundary
            ),
            boundary: boundary
        )
    }

    /// A request that proves the address, the token, and the answer shape without uploading a call.
    ///
    /// One second of silence is enough for an endpoint to answer in the documented format. The
    /// answer is reported as an answer, so a server that is reachable but cannot transcribe is not
    /// called healthy.
    public static func connectionCheck(
        configuration: RemoteSpeechConfiguration,
        boundary: String = "----callrecorder" + UUID().uuidString
    ) throws -> URLRequest {
        var fields: [(String, String)] = [("response_format", "verbose_json")]
        let model = configuration.model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !model.isEmpty { fields.insert(("model", model), at: 0) }
        return try request(
            configuration: configuration,
            body: multipartBody(
                audio: silentWave(),
                filename: "connection-check.wav",
                fields: fields,
                boundary: boundary
            ),
            boundary: boundary
        )
    }

    public static func multipartBody(
        audio: Data,
        filename: String,
        fields: [(String, String)],
        boundary: String
    ) -> Data {
        let crlf = Data([0x0D, 0x0A])
        let dash = Data(("--" + boundary).utf8)
        var body = Data()
        body.append(dash)
        body.append(crlf)
        body.append(
            Data(
                "Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"".utf8
            )
        )
        body.append(crlf)
        body.append(Data("Content-Type: audio/wav".utf8))
        body.append(crlf)
        body.append(crlf)
        body.append(audio)
        body.append(crlf)
        for (name, value) in fields {
            body.append(dash)
            body.append(crlf)
            body.append(Data("Content-Disposition: form-data; name=\"\(name)\"".utf8))
            body.append(crlf)
            body.append(crlf)
            body.append(Data(value.utf8))
            body.append(crlf)
        }
        body.append(dash)
        body.append(Data("--".utf8))
        body.append(crlf)
        return body
    }

    private static func request(
        configuration: RemoteSpeechConfiguration,
        body: Data,
        boundary: String
    ) throws -> URLRequest {
        var request = URLRequest(url: try configuration.endpointURL())
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let token = configuration.token.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = max(1, configuration.timeoutSeconds)
        return request
    }

    /// One second of 16 kHz mono silence, with the header a wave file needs.
    public static func silentWave(seconds: Double = 1, sampleRate: Int = 16_000) -> Data {
        let byteCount = max(2, Int(seconds * Double(sampleRate)) * 2)
        var data = Data()
        func append32(_ value: UInt32) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        func append16(_ value: UInt16) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        data.append(Data("RIFF".utf8))
        append32(UInt32(36 + byteCount))
        data.append(Data("WAVEfmt ".utf8))
        append32(16)
        append16(1)
        append16(1)
        append32(UInt32(sampleRate))
        append32(UInt32(sampleRate * 2))
        append16(2)
        append16(16)
        data.append(Data("data".utf8))
        append32(UInt32(byteCount))
        data.append(Data(count: byteCount))
        return data
    }
}

/// Where the remote reader's bearer token lives.
///
/// The token is a secret, so it is kept in the login Keychain rather than in the settings blob or
/// a plist beside it. The protocol exists so the store's rules can be checked without adding an
/// item to the Keychain of the Mac running the tests.
public protocol SpeechEndpointTokenStorage: Sendable {
    func readToken() throws -> String?
    func writeToken(_ token: String) throws
    func deleteToken() throws
}

public struct SpeechEndpointTokenStore: SpeechEndpointTokenStorage {
    private static let service = "local.callrecorder.app.speech"
    private static let account = "endpoint-token-v1"

    public init() {}

    public func readToken() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw RemoteSpeechError.keychain(status) }
        guard let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func writeToken(_ token: String) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return try deleteToken() }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
        let update: [String: Any] = [kSecValueData as String: Data(trimmed.utf8)]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw RemoteSpeechError.keychain(updateStatus)
        }
        var insert = query
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        insert[kSecValueData as String] = Data(trimmed.utf8)
        let insertStatus = SecItemAdd(insert as CFDictionary, nil)
        guard insertStatus == errSecSuccess else {
            throw RemoteSpeechError.keychain(insertStatus)
        }
    }

    public func deleteToken() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw RemoteSpeechError.keychain(status)
        }
    }
}
