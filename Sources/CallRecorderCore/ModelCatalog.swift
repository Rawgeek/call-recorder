import CryptoKit
import Foundation

public struct AppSettings: Codable, Equatable, Sendable {
    public var automaticDetectionEnabled: Bool
    /// Whether the popover's reminder that automatic recording is off was sent away.
    ///
    /// The card offers the fix for the setting the app is built around, and it sat over the Recent
    /// list for as long as the setting stayed off, with no way to put it down. The reminder is a
    /// nudge rather than a fault, so it can be dismissed; turning automatic recording back on and
    /// off again is a new decision about it and brings the reminder back.
    public var automaticDetectionNoticeDismissed: Bool
    public var automaticStopGraceSeconds: Double
    public var selectedMicrophoneID: String?
    public var localParticipantID: ParticipantID?
    public var selectedWhisperModelID: String
    public var outputDirectory: String
    /// Whether Call Recorder refreshes its model files on its own when the host publishes newer
    /// ones. Off means the user runs every check by hand.
    public var automaticModelUpdatesEnabled: Bool
    /// The glossary repair rules that were in force when the saved transcripts were last
    /// rewritten, or nil when that has never happened.
    ///
    /// A term added in the Vocabulary pane, or through MCP, changes how future audio is decoded
    /// and nothing else: the library keeps the spelling the model produced. Re-applying the
    /// glossary to the whole library is what fixes the files already on disk, and it used to
    /// happen only when someone found the button. Recording the rules that were applied is what
    /// lets the app notice the library is owed a repair and do it without being asked.
    public var appliedGlossaryFingerprint: String?

    /// The version of the not-speech rules the library was last cleaned with.
    ///
    /// A prompt echo, a bracketed marker, and a repetition loop are written by the model rather
    /// than spoken, and a library recorded before the rules existed still carries them. The value
    /// is the rule set the last repair used, so a rule that changes cleans the library again and a
    /// rule that does not leaves it alone. Absent means never cleaned.
    public var appliedArtifactRuleVersion: Int?

    enum CodingKeys: String, CodingKey {
        case automaticDetectionEnabled
        case automaticDetectionNoticeDismissed
        case automaticStopGraceSeconds
        case selectedMicrophoneID
        case localParticipantID
        case selectedWhisperModelID
        case outputDirectory
        case automaticModelUpdatesEnabled
        case appliedGlossaryFingerprint
        case appliedArtifactRuleVersion
    }

    public static var `default`: AppSettings {
        AppSettings(
            automaticDetectionEnabled: true,
            automaticDetectionNoticeDismissed: false,
            automaticStopGraceSeconds: 2,
            selectedMicrophoneID: nil,
            localParticipantID: nil,
            selectedWhisperModelID: "small",
            outputDirectory: FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Desktop/Call Recordings", directoryHint: .isDirectory).path,
            automaticModelUpdatesEnabled: true,
            appliedGlossaryFingerprint: nil,
            appliedArtifactRuleVersion: nil
        )
    }
}

extension AppSettings {
    /// Reads stored settings without requiring every key.
    ///
    /// Settings are saved as one JSON blob, so a plain decoder would reset the whole blob the
    /// moment a new field is added: the missing key fails the decode, the caller falls back to
    /// defaults, and the user silently loses their microphone, participant and folder choices.
    /// Every field therefore falls back on its own.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = AppSettings.default
        automaticDetectionEnabled =
            try container.decodeIfPresent(Bool.self, forKey: .automaticDetectionEnabled)
            ?? fallback.automaticDetectionEnabled
        // Added after the first release. Absent means the reminder has never been dismissed, which
        // is what a settings blob written before the option existed has to mean, and what keeps a
        // first run showing the card.
        automaticDetectionNoticeDismissed =
            try container.decodeIfPresent(Bool.self, forKey: .automaticDetectionNoticeDismissed)
            ?? fallback.automaticDetectionNoticeDismissed
        automaticStopGraceSeconds =
            try container.decodeIfPresent(Double.self, forKey: .automaticStopGraceSeconds)
            ?? fallback.automaticStopGraceSeconds
        selectedMicrophoneID =
            try container.decodeIfPresent(String.self, forKey: .selectedMicrophoneID)
        localParticipantID =
            try container.decodeIfPresent(ParticipantID.self, forKey: .localParticipantID)
        selectedWhisperModelID =
            try container.decodeIfPresent(String.self, forKey: .selectedWhisperModelID)
            ?? fallback.selectedWhisperModelID
        outputDirectory =
            try container.decodeIfPresent(String.self, forKey: .outputDirectory)
            ?? fallback.outputDirectory
        // Added after the first release, so a settings blob written before it exists must still
        // load, and must land on the same behaviour the app had before the option existed.
        automaticModelUpdatesEnabled =
            try container.decodeIfPresent(Bool.self, forKey: .automaticModelUpdatesEnabled)
            ?? fallback.automaticModelUpdatesEnabled
        // Also added after the first release. Absent means the library has never been repaired
        // against a recorded glossary, which is the honest reading and makes the next launch do
        // the work once.
        appliedGlossaryFingerprint =
            try container.decodeIfPresent(String.self, forKey: .appliedGlossaryFingerprint)
        // Its own fallback for the same reason as the key above: a settings blob written before
        // the rules existed has no value here, and the honest reading is that the library has
        // never been cleaned, which makes the next launch do the work once.
        appliedArtifactRuleVersion =
            try container.decodeIfPresent(Int.self, forKey: .appliedArtifactRuleVersion)
    }
}

public struct WhisperModel: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let detail: String
    public let fileName: String
    public let expectedBytes: Int64
    public let sha256: String
    public let downloadURL: URL
    /// The model host repository the file comes from, used when checking for newer copies.
    public let repository: String

    public static let catalog: [WhisperModel] = [
        model(
            id: "tiny",
            detail: "Fastest, lowest accuracy",
            bytes: 77_691_713,
            sha256: "be07e048e1e599ad46341c8d2a135645097a538221678b7acdd1b1919c6e1b21"
        ),
        model(
            id: "base",
            detail: "Fast, basic accuracy",
            bytes: 147_951_465,
            sha256: "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe"
        ),
        model(
            id: "small",
            detail: "Recommended balance",
            bytes: 487_601_967,
            sha256: "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b"
        ),
        model(
            id: "medium",
            detail: "More accurate, slower",
            bytes: 1_533_763_059,
            sha256: "6c14d5adee5f86394037b4e4e8b59f1673b6cee10e3cf0b11bbdbee79c156208"
        ),
    ]

    /// The revision the catalog was pinned to. A first download always comes from here, so a new
    /// install starts from a file whose bytes were decided when the app was built.
    public static let pinnedRevision = "80da2d8bfee42b0e836fc3a9890373e5defc00a6"
    public static let repository = "ggerganov/whisper.cpp"

    private static func model(
        id: String,
        detail: String,
        bytes: Int64,
        sha256: String
    ) -> WhisperModel {
        let fileName = "ggml-\(id).bin"
        return WhisperModel(
            id: id,
            displayName: id.capitalized,
            detail: detail,
            fileName: fileName,
            expectedBytes: bytes,
            sha256: sha256,
            downloadURL: URL(
                string: "https://huggingface.co/\(repository)/resolve/\(pinnedRevision)/\(fileName)"
            )!,
            repository: repository
        )
    }
}

public enum ModelFileVerifier {
    public static func verify(
        fileAt url: URL,
        expectedBytes: Int64,
        sha256: String
    ) throws -> Bool {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard Int64(values.fileSize ?? -1) == expectedBytes else { return false }

        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hasher = SHA256()
        while let data = try file.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return digest == sha256.lowercased()
    }
}
