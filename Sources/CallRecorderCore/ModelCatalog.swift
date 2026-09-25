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
    /// How long a recording the app started by itself has to last before it is kept.
    ///
    /// Zero keeps every recording. The rule lives in `AutomaticRecordingRails`.
    public var minimumAutomaticRecordingSeconds: Double
    /// How long a recording the app started by itself may run before it is stopped.
    ///
    /// Zero is no ceiling. The rule lives in `AutomaticRecordingRails`.
    public var maximumAutomaticRecordingMinutes: Double
    /// How long a recording the app started by itself may hold nothing but room tone before it is
    /// stopped.
    ///
    /// Zero is no such rule. See `AutomaticRecordingRails` and `AudioLevels`.
    public var silenceStopMinutes: Double
    /// Whether the voice recorder, dictation, and the assistant are left out of automatic
    /// detection. The list is `NonCallMicrophoneApps`.
    public var ignoresNonCallApps: Bool
    public var selectedMicrophoneID: String?
    /// Whether the people on a call decide how many voices the detector separates.
    ///
    /// One detector can be held to a count and one cannot. The count-aware detector answers exactly
    /// the number it is given, and the list the app holds is usually right: fourteen remote voices
    /// in a standup stayed fourteen rather than becoming sixteen. It reads every call twice over,
    /// through its own separation model, and on a long meeting that is minutes of work; the detector
    /// this app records with now is Nemotron 3, which counts the voices itself in seconds and has no
    /// count to be told. On, the list of people steers the count-aware detector, and a count that is
    /// too low writes two people into one voice. Off, which is the default, the fast detector counts
    /// the voices it hears. A count a person sets in the review window is honored either way.
    public var diarizationUsesParticipantCount: Bool
    /// Whether a recording goes ahead on a Mac that has no audio input at all.
    ///
    /// ScreenCaptureKit records a call's system audio without a microphone, so a Mac mini with no
    /// input device still holds the other side of the call. On makes that recording; off keeps the
    /// refusal, which is the choice for a Mac that does have a microphone and wants every
    /// recording to hold both sides. A microphone that exists but was chosen wrongly is not this
    /// setting: the device list still falls back to the built-in microphone.
    public var recordsWithoutMicrophone: Bool
    public var localParticipantID: ParticipantID?
    public var outputDirectory: String
    /// Whether Call Recorder refreshes its model files on its own when the host publishes newer
    /// ones. Off means the user runs every check by hand.
    public var automaticModelUpdatesEnabled: Bool
    /// Whether Call Recorder fetches its own newer releases and installs them.
    ///
    /// A newer release is downloaded and checked while the app runs, and swapped in when the app
    /// quits, so the next launch is the new version. Off means the check still runs and says what
    /// is available; nothing is downloaded until it is asked for.
    public var automaticAppUpdatesEnabled: Bool
    /// How often the app looks for a newer release of itself while it stays open.
    ///
    /// Added after the first release. A settings blob written before the choice existed has no
    /// value here and falls back to the step the app shipped with, which is six hours.
    public var appUpdateCheckInterval: AppUpdateInterval
    /// Whether a finished call gives up the audio it was recorded from.
    ///
    /// The audio of a finished call is moved out of the way once its transcript and its search
    /// index are verified, and kept for a day where it can be put back. A recording of a long
    /// meeting at 48 kHz is hundreds of megabytes, and a library of them is the largest thing the
    /// app holds, so giving the space back is the default. Keeping it is a choice, and a person
    /// who wants the audio beside the transcript asks for it here.
    public var removeAudioAfterTranscription: Bool
    /// The language a recording is transcribed in, or "auto" to let the model decide for itself.
    ///
    /// The reader is told "auto" unless the user says otherwise. Naming the language holds the
    /// decoder to the script of that language when two candidate tokens are close, which is what
    /// keeps a call that mixes Russian with English product names from being written in the wrong
    /// script throughout.
    public var transcriptionLanguage: String
    /// Whether a saved transcript prints the time each turn started.
    ///
    /// Off by default: a file is read for what was said, and a printed time in the middle of a
    /// paragraph is machine furniture. A call whose notes are searched by when something was said
    /// turns it on, and every turn then opens with its time.
    public var transcriptTimestamps: Bool
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
        case minimumAutomaticRecordingSeconds
        case maximumAutomaticRecordingMinutes
        case silenceStopMinutes
        case ignoresNonCallApps
        case selectedMicrophoneID
        case diarizationUsesParticipantCount
        case recordsWithoutMicrophone
        case localParticipantID
        case outputDirectory
        case automaticModelUpdatesEnabled
        case automaticAppUpdatesEnabled
        case appUpdateCheckInterval
        case removeAudioAfterTranscription
        case transcriptionLanguage
        case transcriptTimestamps
        case appliedGlossaryFingerprint
        case appliedArtifactRuleVersion
    }

    public static var `default`: AppSettings {
        AppSettings(
            automaticDetectionEnabled: true,
            automaticDetectionNoticeDismissed: false,
            automaticStopGraceSeconds: 2,
            minimumAutomaticRecordingSeconds: AutomaticRecordingRails.defaultMinimumSeconds,
            maximumAutomaticRecordingMinutes: AutomaticRecordingRails.defaultMaximumMinutes,
            silenceStopMinutes: AutomaticRecordingRails.defaultSilenceMinutes,
            ignoresNonCallApps: true,
            selectedMicrophoneID: nil,
            diarizationUsesParticipantCount: false,
            recordsWithoutMicrophone: true,
            localParticipantID: nil,
            outputDirectory: FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Desktop/Call Recordings", directoryHint: .isDirectory).path,
            automaticModelUpdatesEnabled: true,
            automaticAppUpdatesEnabled: true,
            appUpdateCheckInterval: .default,
            removeAudioAfterTranscription: true,
            transcriptionLanguage: "auto",
            transcriptTimestamps: false,
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
        // Added after the first release, and each carries the behaviour the app had before the
        // option existed: a settings blob with no value here belongs to a Mac that recorded
        // everything it detected, which is what the defaults describe.
        minimumAutomaticRecordingSeconds =
            try container.decodeIfPresent(Double.self, forKey: .minimumAutomaticRecordingSeconds)
            ?? fallback.minimumAutomaticRecordingSeconds
        maximumAutomaticRecordingMinutes =
            try container.decodeIfPresent(Double.self, forKey: .maximumAutomaticRecordingMinutes)
            ?? fallback.maximumAutomaticRecordingMinutes
        silenceStopMinutes =
            try container.decodeIfPresent(Double.self, forKey: .silenceStopMinutes)
            ?? fallback.silenceStopMinutes
        ignoresNonCallApps =
            try container.decodeIfPresent(Bool.self, forKey: .ignoresNonCallApps)
            ?? fallback.ignoresNonCallApps
        selectedMicrophoneID =
            try container.decodeIfPresent(String.self, forKey: .selectedMicrophoneID)
        // Added after the first release, and absent now means the behaviour the detector switch
        // introduced: the separation counts the voices it hears. A stored blob that holds the value
        // keeps it, so a library whose count-aware separation is wanted stays on it.
        diarizationUsesParticipantCount =
            try container.decodeIfPresent(Bool.self, forKey: .diarizationUsesParticipantCount)
            ?? fallback.diarizationUsesParticipantCount
        // Added after the first release. Absent means the behaviour this release introduced: a Mac
        // with no audio input records the other side of the call instead of refusing to record.
        recordsWithoutMicrophone =
            try container.decodeIfPresent(Bool.self, forKey: .recordsWithoutMicrophone)
            ?? fallback.recordsWithoutMicrophone
        localParticipantID =
            try container.decodeIfPresent(ParticipantID.self, forKey: .localParticipantID)
        outputDirectory =
            try container.decodeIfPresent(String.self, forKey: .outputDirectory)
            ?? fallback.outputDirectory
        // Added after the first release, so a settings blob written before it exists must still
        // load, and must land on the same behaviour the app had before the option existed.
        automaticModelUpdatesEnabled =
            try container.decodeIfPresent(Bool.self, forKey: .automaticModelUpdatesEnabled)
            ?? fallback.automaticModelUpdatesEnabled
        // Added after the first release, with the same rule as the model option above: a Mac that
        // has never been offered the choice keeps the behaviour the app shipped with.
        automaticAppUpdatesEnabled =
            try container.decodeIfPresent(Bool.self, forKey: .automaticAppUpdatesEnabled)
            ?? fallback.automaticAppUpdatesEnabled
        // Read as the raw string rather than as the enum: a value this build does not know, written
        // by a later build or read from a damaged file, must cost the user this one choice instead
        // of failing the decode of every setting beside it.
        let storedInterval =
            (try? container.decodeIfPresent(String.self, forKey: .appUpdateCheckInterval)) ?? nil
        appUpdateCheckInterval =
            storedInterval.flatMap(AppUpdateInterval.init(rawValue:))
            ?? fallback.appUpdateCheckInterval
        // Added after the first release. Absent means the audio is given up, which is what the
        // app did before the option existed.
        removeAudioAfterTranscription =
            try container.decodeIfPresent(Bool.self, forKey: .removeAudioAfterTranscription)
            ?? fallback.removeAudioAfterTranscription
        // Both added after the first release. Absent means the language is detected and the times
        // are not printed, which is what the app did before the choices existed.
        transcriptionLanguage =
            try container.decodeIfPresent(String.self, forKey: .transcriptionLanguage)
            ?? fallback.transcriptionLanguage
        transcriptTimestamps =
            try container.decodeIfPresent(Bool.self, forKey: .transcriptTimestamps)
            ?? fallback.transcriptTimestamps
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

/// The headroom a model run needs on top of the size of its files.
///
/// The size of the files covers the weights and the decoder. Everything else a run holds — audio
/// buffers, ffmpeg, the app, the rest of the system — needs room beside it, and a Mac that only
/// just fits the published number will swap hard.
public enum ModelMemoryHeadroom {
    public static let percent: Int64 = 30
}

/// How a model's memory need compares with the memory of the Mac it would run on.
public enum ModelMemoryFit: Equatable, Sendable {
    /// The published working set and the app's headroom both fit.
    case comfortable
    /// The working set fits and the headroom does not: the machine will swap under load.
    case tight
    /// Even the working set does not fit.
    case insufficient
}

public extension SupportingModel {
    /// The size of the files on disk plus the headroom every model run needs beside it.
    ///
    /// The weights of a model this size are paged in rather than copied, so the file size is the
    /// right measure of what the run costs the machine, and the headroom covers the rest: audio
    /// buffers, ffmpeg, the window.
    var recommendedMemoryBytes: Int64 {
        totalBytes * (100 + ModelMemoryHeadroom.percent) / 100
    }

    func memoryFit(inMemoryOf bytes: Int64) -> ModelMemoryFit {
        if recommendedMemoryBytes <= bytes { return .comfortable }
        return totalBytes <= bytes ? .tight : .insufficient
    }
}

/// Sizes, stated the way the model host and the published model table state them.
public enum ModelSizeLabel {
    /// File sizes in binary units: the same bytes the model table calls "466 MiB".
    public static func file(bytes: Int64) -> String {
        let mebibyte = 1_048_576.0
        let gibibyte = 1_073_741_824.0
        let value = Double(bytes)
        if value >= gibibyte { return String(format: "%.1f GiB", value / gibibyte) }
        if value >= mebibyte { return String(format: "%.0f MiB", value / mebibyte) }
        return String(format: "%.0f KiB", value / 1024)
    }

    /// Memory in decimal units, which is how the published table states it.
    public static func memory(bytes: Int64) -> String {
        let value = Double(bytes)
        if value >= 1_000_000_000 { return String(format: "%.1f GB", value / 1_000_000_000) }
        return String(format: "%.0f MB", value / 1_000_000)
    }
}

public enum ModelFileVerifier {
    /// True when the file is the size and content that was expected.
    ///
    /// A host hashes what it publishes, but not always the same way: a large file it stores for the
    /// download carries a SHA-256, and a small file carries only the name it has in the host's
    /// repository, which is a Git blob hash of the contents. Either one decides the file, and a
    /// file is never accepted on its size alone.
    public static func verify(
        fileAt url: URL,
        expectedBytes: Int64,
        sha256: String,
        blobID: String? = nil
    ) throws -> Bool {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard Int64(values.fileSize ?? -1) == expectedBytes else { return false }
        if sha256.isEmpty {
            guard let blobID, !blobID.isEmpty else { return false }
            return try gitBlobSHA1(of: url) == blobID.lowercased()
        }
        return try ModelFileVerifier.sha256(of: url) == sha256.lowercased()
    }

    /// The SHA-256 of a file, read in blocks so a large one never sits in memory.
    public static func sha256(of url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hasher = SHA256()
        while let data = try file.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The name a file has in a host's repository, which is how small files are published.
    ///
    /// It is the SHA-1 of the header "blob <bytes>\\0" followed by the contents, which is what Git
    /// computes for every file it stores.
    public static func gitBlobSHA1(of url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let bytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        var hasher = Insecure.SHA1()
        hasher.update(data: Data("blob \(bytes)\0".utf8))
        while let data = try file.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The same name, for bytes already in hand.
    public static func gitBlobSHA1(of data: Data) -> String {
        var hasher = Insecure.SHA1()
        hasher.update(data: Data("blob \(data.count)\0".utf8))
        hasher.update(data: data)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
