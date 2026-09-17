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
    /// Whether Call Recorder fetches its own newer releases and installs them.
    ///
    /// A newer release is downloaded and checked while the app runs, and swapped in when the app
    /// quits, so the next launch is the new version. Off means the check still runs and says what
    /// is available; nothing is downloaded until it is asked for.
    public var automaticAppUpdatesEnabled: Bool
    /// Whether a finished call gives up the audio it was recorded from.
    ///
    /// The audio of a finished call is moved out of the way once its transcript and its search
    /// index are verified, and kept for a day where it can be put back. A recording of a long
    /// meeting at 48 kHz is hundreds of megabytes, and a library of them is the largest thing the
    /// app holds, so giving the space back is the default. Keeping it is a choice, and a person
    /// who wants the audio beside the transcript asks for it here.
    public var removeAudioAfterTranscription: Bool
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
        case automaticAppUpdatesEnabled
        case removeAudioAfterTranscription
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
            automaticAppUpdatesEnabled: true,
            removeAudioAfterTranscription: true,
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
        // Added after the first release, with the same rule as the model option above: a Mac that
        // has never been offered the choice keeps the behaviour the app shipped with.
        automaticAppUpdatesEnabled =
            try container.decodeIfPresent(Bool.self, forKey: .automaticAppUpdatesEnabled)
            ?? fallback.automaticAppUpdatesEnabled
        // Added after the first release. Absent means the audio is given up, which is what the
        // app did before the option existed.
        removeAudioAfterTranscription =
            try container.decodeIfPresent(Bool.self, forKey: .removeAudioAfterTranscription)
            ?? fallback.removeAudioAfterTranscription
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

    // Guidance, so the models page can say which model fits which job instead of leaving a
    // person to guess from a name. Parameters, required VRAM and relative speed are OpenAI's
    // published model table; the word error rates are the paper's evaluations on read speech.

    /// Parameters as published: "39 M", "1,550 M".
    public let parameters: String
    /// Working memory whisper.cpp needs at runtime, in bytes.
    public let memoryBytes: Int64
    /// VRAM a GPU build asks for. On Apple silicon memory is shared, so the card points at
    /// `memoryBytes` instead; this stays for the published comparison.
    public let requiredVRAM: String
    /// Speed relative to the slowest model: "~10×", "1×".
    public let speed: String
    /// Word error rate on read English speech, as published.
    public let englishWordErrorRate: String?
    /// Word error rate across the multilingual evaluation, absent for English-only models.
    public let multilingualWordErrorRate: String?
    public let englishOnly: Bool
    /// The English-only twin of a multilingual model, named where the choice is made.
    public let englishTwinID: String?

    public static let catalog: [WhisperModel] = [
        model(
            id: "tiny",
            detail: "Fastest; rough with accents and noise",
            bytes: 77_691_713,
            sha256: "be07e048e1e599ad46341c8d2a135645097a538221678b7acdd1b1919c6e1b21",
            parameters: "39 M",
            memoryBytes: 273_000_000,
            vram: "~1 GB",
            speed: "~10×",
            englishWER: "7.6%",
            multilingualWER: "12%",
            twin: "tiny.en"
        ),
        model(
            id: "tiny.en",
            detail: "English only; a little better than Tiny at English",
            bytes: 77_704_715,
            sha256: "921e4cf8686fdd993dcd081a5da5b6c365bfde1162e72b08d75ac75289920b1f",
            parameters: "39 M",
            memoryBytes: 273_000_000,
            vram: "~1 GB",
            speed: "~10×",
            englishWER: "5.6%"
        ),
        model(
            id: "base",
            detail: "Quick drafts of clear speech",
            bytes: 147_951_465,
            sha256: "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe",
            parameters: "74 M",
            memoryBytes: 388_000_000,
            vram: "~1 GB",
            speed: "~7×",
            englishWER: "5.0%",
            multilingualWER: "10%",
            twin: "base.en"
        ),
        model(
            id: "base.en",
            detail: "English only; a little better than Base at English",
            bytes: 147_964_211,
            sha256: "a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002",
            parameters: "74 M",
            memoryBytes: 388_000_000,
            vram: "~1 GB",
            speed: "~7×",
            englishWER: "4.3%"
        ),
        model(
            id: "small",
            detail: "Recommended balance of speed and accuracy",
            bytes: 487_601_967,
            sha256: "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b",
            parameters: "244 M",
            memoryBytes: 852_000_000,
            vram: "~2 GB",
            speed: "~4×",
            englishWER: "3.4%",
            multilingualWER: "7%",
            twin: "small.en"
        ),
        model(
            id: "small.en",
            detail: "English only; a little better than Small at English",
            bytes: 487_614_201,
            sha256: "c6138d6d58ecc8322097e0f987c32f1be8bb0a18532a3f88f734d1bbf9c41e5d",
            parameters: "244 M",
            memoryBytes: 852_000_000,
            vram: "~2 GB",
            speed: "~4×",
            englishWER: "3.0%"
        ),
        model(
            id: "medium",
            detail: "More accurate; about half the speed of Small",
            bytes: 1_533_763_059,
            sha256: "6c14d5adee5f86394037b4e4e8b59f1673b6cee10e3cf0b11bbdbee79c156208",
            parameters: "769 M",
            memoryBytes: 2_100_000_000,
            vram: "~5 GB",
            speed: "~2×",
            englishWER: "2.9%",
            multilingualWER: "5%",
            twin: "medium.en"
        ),
        model(
            id: "medium.en",
            detail: "English only; a little better than Medium at English",
            bytes: 1_533_774_781,
            sha256: "cc37e93478338ec7700281a7ac30a10128929eb8f427dda2e865faa8f6da4356",
            parameters: "769 M",
            memoryBytes: 2_100_000_000,
            vram: "~5 GB",
            speed: "~2×",
            englishWER: "2.6%"
        ),

        model(
            id: "large-v1",
            detail: "The first large model; superseded by Large v2 and v3",
            bytes: 3_094_623_691,
            sha256: "7d99f41a10525d0206bddadd86760181fa920438b6b33237e3118ff6c83bb53d",
            parameters: "1,550 M",
            memoryBytes: 3_900_000_000,
            vram: "~10 GB",
            speed: "1×",
            englishWER: "2.7%",
            multilingualWER: "5.2%"
        ),
        model(
            id: "large-v2",
            detail: "Older large model; prefer Large v3 or Large v3 Turbo",
            bytes: 3_094_623_691,
            sha256: "9a423fe4d40c82774b6af34115b8b935f34152246eb19e80e376071d3f999487",
            parameters: "1,550 M",
            memoryBytes: 3_900_000_000,
            vram: "~10 GB",
            speed: "1×",
            englishWER: "2.7%",
            multilingualWER: "4%"
        ),
        model(
            id: "large-v3",
            detail: "Highest accuracy; slowest",
            bytes: 3_095_033_483,
            sha256: "64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2",
            parameters: "1,550 M",
            memoryBytes: 3_900_000_000,
            vram: "~10 GB",
            speed: "1×",
            englishWER: "2.4%",
            multilingualWER: "3.5%"
        ),
        model(
            id: "large-v3-turbo",
            detail: "Nearly Large v3 quality at about eight times the speed",
            bytes: 1_624_555_275,
            sha256: "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69",
            parameters: "809 M",
            memoryBytes: 2_300_000_000,
            vram: "~6 GB",
            speed: "~8×",
            englishWER: "2.5%",
            multilingualWER: "3.7%"
        ),

        // The quantized files. Upstream publishes each of these beside the full one, and they
        // matter most where memory is tight: a five-bit Large v3 Turbo is 574 MB instead of 1.6 GB
        // and holds about 1.3 GB of working set instead of 2.3 GB.
        //
        // The working set of a quantized file is not published anywhere. It is counted here the way
        // the published figures are made: the weight bytes of the file, plus the activation memory
        // its family needs, which is the published working set of the full file less that file's
        // own weight bytes. The parameters, the speed, and the architectures are unchanged by
        // quantization, so those are the family's own figures.
        model(
            id: "tiny-q5_1",
            detail: quantizedDetail("Q5_1", of: "Tiny"),
            bytes: 32_152_673,
            sha256: "818710568da3ca15689e31a743197b520007872ff9576237bda97bd1b469c3d7",
            parameters: "39 M",
            memoryBytes: 230_000_000,
            vram: "~1 GB",
            speed: "~10×",
            englishWER: nil,
            twin: "tiny.en-q5_1"
        ),
        model(
            id: "tiny-q8_0",
            detail: quantizedDetail("Q8_0", of: "Tiny"),
            bytes: 43_537_433,
            sha256: "c2085835d3f50733e2ff6e4b41ae8a2b8d8110461e18821b09a15c40c42d1cca",
            parameters: "39 M",
            memoryBytes: 240_000_000,
            vram: "~1 GB",
            speed: "~10×",
            englishWER: nil,
            twin: "tiny.en-q8_0"
        ),
        model(
            id: "tiny.en-q5_1",
            detail: quantizedDetail("Q5_1", of: "Tiny (English)"),
            bytes: 32_166_155,
            sha256: "c77c5766f1cef09b6b7d47f21b546cbddd4157886b3b5d6d4f709e91e66c7c2b",
            parameters: "39 M",
            memoryBytes: 230_000_000,
            vram: "~1 GB",
            speed: "~10×",
            englishWER: nil
        ),
        model(
            id: "tiny.en-q8_0",
            detail: quantizedDetail("Q8_0", of: "Tiny (English)"),
            bytes: 43_550_795,
            sha256: "5bc2b3860aa151a4c6e7bb095e1fcce7cf12c7b020ca08dcec0c6d018bb7dd94",
            parameters: "39 M",
            memoryBytes: 240_000_000,
            vram: "~1 GB",
            speed: "~10×",
            englishWER: nil
        ),
        model(
            id: "base-q5_1",
            detail: quantizedDetail("Q5_1", of: "Base"),
            bytes: 59_707_625,
            sha256: "422f1ae452ade6f30a004d7e5c6a43195e4433bc370bf23fac9cc591f01a8898",
            parameters: "74 M",
            memoryBytes: 300_000_000,
            vram: "~1 GB",
            speed: "~7×",
            englishWER: nil,
            twin: "base.en-q5_1"
        ),
        model(
            id: "base-q8_0",
            detail: quantizedDetail("Q8_0", of: "Base"),
            bytes: 81_768_585,
            sha256: "c577b9a86e7e048a0b7eada054f4dd79a56bbfa911fbdacf900ac5b567cbb7d9",
            parameters: "74 M",
            memoryBytes: 330_000_000,
            vram: "~1 GB",
            speed: "~7×",
            englishWER: nil,
            twin: "base.en-q8_0"
        ),
        model(
            id: "base.en-q5_1",
            detail: quantizedDetail("Q5_1", of: "Base (English)"),
            bytes: 59_721_011,
            sha256: "4baf70dd0d7c4247ba2b81fafd9c01005ac77c2f9ef064e00dcf195d0e2fdd2f",
            parameters: "74 M",
            memoryBytes: 300_000_000,
            vram: "~1 GB",
            speed: "~7×",
            englishWER: nil
        ),
        model(
            id: "base.en-q8_0",
            detail: quantizedDetail("Q8_0", of: "Base (English)"),
            bytes: 81_781_811,
            sha256: "a4d4a0768075e13cfd7e19df3ae2dbc4a68d37d36a7dad45e8410c9a34f8c87e",
            parameters: "74 M",
            memoryBytes: 330_000_000,
            vram: "~1 GB",
            speed: "~7×",
            englishWER: nil
        ),
        model(
            id: "small-q5_1",
            detail: quantizedDetail("Q5_1", of: "Small"),
            bytes: 190_085_487,
            sha256: "ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb",
            parameters: "244 M",
            memoryBytes: 580_000_000,
            vram: "~1 GB",
            speed: "~4×",
            englishWER: nil,
            twin: "small.en-q5_1"
        ),
        model(
            id: "small-q8_0",
            detail: quantizedDetail("Q8_0", of: "Small"),
            bytes: 264_464_607,
            sha256: "49c8fb02b65e6049d5fa6c04f81f53b867b5ec9540406812c643f177317f779f",
            parameters: "244 M",
            memoryBytes: 650_000_000,
            vram: "~2 GB",
            speed: "~4×",
            englishWER: nil,
            twin: "small.en-q8_0"
        ),
        model(
            id: "small.en-q5_1",
            detail: quantizedDetail("Q5_1", of: "Small (English)"),
            bytes: 190_098_681,
            sha256: "bfdff4894dcb76bbf647d56263ea2a96645423f1669176f4844a1bf8e478ad30",
            parameters: "244 M",
            memoryBytes: 580_000_000,
            vram: "~1 GB",
            speed: "~4×",
            englishWER: nil
        ),
        model(
            id: "small.en-q8_0",
            detail: quantizedDetail("Q8_0", of: "Small (English)"),
            bytes: 264_477_561,
            sha256: "67a179f608ea6114bd3fdb9060e762b588a3fb3bd00c4387971be4d177958067",
            parameters: "244 M",
            memoryBytes: 650_000_000,
            vram: "~2 GB",
            speed: "~4×",
            englishWER: nil
        ),
        model(
            id: "medium-q5_0",
            detail: quantizedDetail("Q5_0", of: "Medium"),
            bytes: 539_212_467,
            sha256: "19fea4b380c3a618ec4723c3eef2eb785ffba0d0538cf43f8f235e7b3b34220f",
            parameters: "769 M",
            memoryBytes: 1_140_000_000,
            vram: "~2 GB",
            speed: "~2×",
            englishWER: nil,
            twin: "medium.en-q5_0"
        ),
        model(
            id: "medium-q8_0",
            detail: quantizedDetail("Q8_0", of: "Medium"),
            bytes: 823_369_779,
            sha256: "42a1ffcbe4167d224232443396968db4d02d4e8e87e213d3ee2e03095dea6502",
            parameters: "769 M",
            memoryBytes: 1_420_000_000,
            vram: "~3 GB",
            speed: "~2×",
            englishWER: nil,
            twin: "medium.en-q8_0"
        ),
        model(
            id: "medium.en-q5_0",
            detail: quantizedDetail("Q5_0", of: "Medium (English)"),
            bytes: 539_225_533,
            sha256: "76733e26ad8fe1c7a5bf7531a9d41917b2adc0f20f2e4f5531688a8c6cd88eb0",
            parameters: "769 M",
            memoryBytes: 1_140_000_000,
            vram: "~2 GB",
            speed: "~2×",
            englishWER: nil
        ),
        model(
            id: "medium.en-q8_0",
            detail: quantizedDetail("Q8_0", of: "Medium (English)"),
            bytes: 823_382_461,
            sha256: "43fa2cd084de5a04399a896a9a7a786064e221365c01700cea4666005218f11c",
            parameters: "769 M",
            memoryBytes: 1_420_000_000,
            vram: "~3 GB",
            speed: "~2×",
            englishWER: nil
        ),
        model(
            id: "large-v2-q5_0",
            detail: quantizedDetail("Q5_0", of: "Large v2"),
            bytes: 1_080_732_091,
            sha256: "3a214837221e4530dbc1fe8d734f302af393eb30bd0ed046042ebf4baf70f6f2",
            parameters: "1,550 M",
            memoryBytes: 2_080_000_000,
            vram: "~3 GB",
            speed: "1×",
            englishWER: nil
        ),
        model(
            id: "large-v2-q8_0",
            detail: quantizedDetail("Q8_0", of: "Large v2"),
            bytes: 1_656_129_691,
            sha256: "fef54e6d898246a65c8285bfa83bd1807e27fadf54d5d4e81754c47634737e8c",
            parameters: "1,550 M",
            memoryBytes: 2_660_000_000,
            vram: "~4 GB",
            speed: "1×",
            englishWER: nil
        ),
        model(
            id: "large-v3-q5_0",
            detail: quantizedDetail("Q5_0", of: "Large v3"),
            bytes: 1_081_140_203,
            sha256: "d75795ecff3f83b5faa89d1900604ad8c780abd5739fae406de19f23ecd98ad1",
            parameters: "1,550 M",
            memoryBytes: 2_080_000_000,
            vram: "~3 GB",
            speed: "1×",
            englishWER: nil
        ),
        model(
            id: "large-v3-turbo-q5_0",
            detail: quantizedDetail("Q5_0", of: "Large v3 Turbo"),
            bytes: 574_041_195,
            sha256: "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2",
            parameters: "809 M",
            memoryBytes: 1_270_000_000,
            vram: "~2 GB",
            speed: "~8×",
            englishWER: nil
        ),
        model(
            id: "large-v3-turbo-q8_0",
            detail: quantizedDetail("Q8_0", of: "Large v3 Turbo"),
            bytes: 874_188_075,
            sha256: "317eb69c11673c9de1e1f0d459b253999804ec71ac4c23c17ecf5fbe24e259a1",
            parameters: "809 M",
            memoryBytes: 1_570_000_000,
            vram: "~3 GB",
            speed: "~8×",
            englishWER: nil
        ),
    ]

    /// The revision the catalog was pinned to. A first download always comes from here, so a new
    /// install starts from a file whose bytes were decided when the app was built.
    public static let pinnedRevision = "5359861c739e955e79d9a303bcbc70fb988958b1"
    public static let repository = "ggerganov/whisper.cpp"

    private static func model(
        id: String,
        detail: String,
        bytes: Int64,
        sha256: String,
        parameters: String,
        memoryBytes: Int64,
        vram: String,
        speed: String,
        englishWER: String?,
        multilingualWER: String? = nil,
        twin: String? = nil
    ) -> WhisperModel {
        let fileName = "ggml-\(id).bin"
        return WhisperModel(
            id: id,
            displayName: displayName(for: id),
            detail: detail,
            fileName: fileName,
            expectedBytes: bytes,
            sha256: sha256,
            downloadURL: URL(
                string: "https://huggingface.co/\(repository)/resolve/\(pinnedRevision)/\(fileName)"
            )!,
            repository: repository,
            parameters: parameters,
            memoryBytes: memoryBytes,
            requiredVRAM: vram,
            speed: speed,
            englishWordErrorRate: englishWER,
            multilingualWordErrorRate: multilingualWER,
            // A quantized file keeps the suffix in the middle of its identifier, so the test is
            // whether the model is English-only anywhere in it rather than at the very end.
            englishOnly: id.contains(".en"),
            englishTwinID: twin
        )
    }

    /// The name people read. The English-only files carry the distinction in the name, which is
    /// the one thing to notice before choosing one, so it stays in the display name.
    private static func displayName(for id: String) -> String {
        // A quantized file is the same model at a smaller size: "large-v3-turbo-q5_0" is named for
        // what it is, so a person reading the list can see both the model and the trade.
        if let split = splitQuantization(id) {
            return baseName(for: split.base) + " " + split.label
        }
        return baseName(for: id)
    }

    /// Separates the quantization from the model in an identifier.
    ///
    /// The file name decides it: ggml-large-v3-turbo-q5_0.bin is Large v3 Turbo, quantized to five
    /// bits. Nothing else in the catalog ends in a token shaped like that, so the test is the shape
    /// of the last part rather than a list of names that would have to be kept up to date.
    private static func splitQuantization(_ id: String) -> (base: String, label: String)? {
        guard
            let last = id.split(separator: "-").last,
            last.first == "q",
            last.count == 4,
            last.dropFirst().allSatisfy({ $0.isNumber || $0 == "_" })
        else { return nil }
        return (String(id.dropLast(last.count + 1)), last.uppercased())
    }

    /// What a quantized file trades for its size.
    ///
    /// The sizes are the ones upstream publishes: a five-bit file is about a third of the full one,
    /// and an eight-bit file a little over half. The accuracy cost is the few tenths of a percent
    /// of word error rate that quantization is documented to cost, which is why these rows carry
    /// no word error rate of their own: the published numbers belong to the full files, and
    /// repeating them beside a smaller file would claim it matched.
    private static func quantizedDetail(_ label: String, of base: String) -> String {
        label.hasPrefix("Q5")
            ? "About a third of the size of " + base + "; a little less accurate"
            : "A little over half the size of " + base + "; very close to its accuracy"
    }

    private static func baseName(for id: String) -> String {

        switch id {
        case "tiny": "Tiny"
        case "tiny.en": "Tiny (English)"
        case "base": "Base"
        case "base.en": "Base (English)"
        case "small": "Small"
        case "small.en": "Small (English)"
        case "medium": "Medium"
        case "medium.en": "Medium (English)"
        case "large-v1": "Large v1"
        case "large-v2": "Large v2"
        case "large-v3": "Large v3"
        case "large-v3-turbo": "Large v3 Turbo"
        default: id.capitalized
        }
    }
}

extension WhisperModel {
    /// The headroom the memory warning adds on top of the published working set.
    ///
    /// The published figure covers the model weights and the decoder. Everything else a
    /// transcription run holds — audio buffers, ffmpeg, the app, the rest of the system — needs
    /// room beside it, and a Mac that only just fits the published number will swap hard.
    public static let memoryHeadroomPercent: Int64 = 30

    /// The published working set plus the headroom.
    public var recommendedMemoryBytes: Int64 {
        memoryBytes * (100 + Self.memoryHeadroomPercent) / 100
    }

    /// Whether this model fits a Mac with the given memory and the headroom above.
    public func fits(inMemoryOf bytes: Int64) -> Bool {
        recommendedMemoryBytes <= bytes
    }

    /// How this model's memory need compares with the memory of the Mac it would run on.
    ///
    /// The two failing states are different, and one message for both was wrong in the direction
    /// that matters: a model that overruns the machine outright cannot run, and one that fits
    /// without the headroom runs by swapping through a transcript. The settings list colours them
    /// apart so a person can see which is which at a glance.
    public func memoryFit(inMemoryOf bytes: Int64) -> WhisperModelMemoryFit {
        if fits(inMemoryOf: bytes) { return .comfortable }
        return memoryBytes <= bytes ? .tight : .insufficient
    }

    /// The two models the settings page points at: the balanced one, and the accurate one.
    public var isRecommended: Bool {
        id == "small" || id == "large-v3-turbo"
    }

    /// Whether this model is one the settings page shows without being asked, on this Mac.
    public func isPrimary(inMemoryOf bytes: Int64) -> Bool {
        Self.primaryIDs(inMemoryOf: bytes).contains(id)
    }

    /// The quantization this file is, when it is one: "Q5_1", "Q8_0", or nil for a full file.
    ///
    /// Quantized files are the same model at a smaller size. They carry none of the published
    /// accuracy figures, because those belong to the full files, so the name is what says which
    /// trade a row is offering.
    public var quantizationLabel: String? {
        Self.splitQuantization(id)?.label
    }

    /// The models the settings page shows before it is asked for more.
    ///
    /// The three small files answer for every Mac, from the one that only has room for a rough
    /// transcript to the one that wants a good one. The fourth row is the accurate model this Mac
    /// can actually run: Large v3 Turbo where there is room for it, and Medium where there is not.
    /// Turbo is both faster and nearly as accurate as Medium, so offering Medium beside it would
    /// be offering a slower answer to the same question. Everything else is a variation: an
    /// English-only twin, an older large file.
    public static func primaryIDs(inMemoryOf bytes: Int64) -> [String] {
        let first = ["tiny", "base", "small"]
        guard
            let turbo = catalog.first(where: { $0.id == "large-v3-turbo" }),
            turbo.fits(inMemoryOf: bytes)
        else {
            return first + ["medium"]
        }
        return first + ["large-v3-turbo"]
    }
}

public enum WhisperModelMemoryFit: Equatable, Sendable {
    /// The published working set and the app's headroom both fit.
    case comfortable
    /// The working set fits and the headroom does not: the machine will swap under load.
    case tight
    /// Even the working set does not fit.
    case insufficient
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
