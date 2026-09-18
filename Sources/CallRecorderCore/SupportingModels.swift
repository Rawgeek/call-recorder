import Foundation

/// One file a supporting model needs, pinned to the bytes the model host publishes.
///
/// The path is the host's own path, so the folder layout a JavaScript runtime expects is the
/// same layout the download writes.
public struct SupportingModelFile: Codable, Hashable, Sendable {
    public let path: String
    public let bytes: Int64
    /// The SHA-256 the host publishes for a large file, or empty when all the host publishes is
    /// the Git blob hash below.
    public let sha256: String
    /// The name the file has in the host's repository, for the small files a host hashes that way:
    /// a config.json, a tokenizer configuration.
    public let blobID: String?

    public init(path: String, bytes: Int64, sha256: String, blobID: String? = nil) {
        self.path = path
        self.bytes = bytes
        self.sha256 = sha256
        self.blobID = blobID
    }
}

/// A model Call Recorder needs but does not ask anyone to choose between.
///
/// Whisper is a choice: the user picks it and can switch. The embedding model is not. It is a
/// dependency of transcript search, and it cannot be shipped inside the app because it is larger
/// than the app itself, so it is downloaded once and verified like everything else.
///
/// Files are installed the way the runtime that reads them addresses them:
/// installPath/repository/revision/path. The revision is part of the path, so installing a newer
/// copy never overwrites the one a search is reading.
public struct SupportingModel: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let detail: String
    public let repository: String
    /// The revision every pinned hash below was taken from.
    public let revision: String
    /// Folder under Application Support that holds this model, before the layout is applied.
    public let installPath: String
    /// The model's own version, in the words the project that publishes it uses.
    public let versionLabel: String
    public let files: [SupportingModelFile]

    public var totalBytes: Int64 {
        files.reduce(0) { $0 + $1.bytes }
    }

    /// The address one file is fetched from. A revision can be named to fetch a newer copy.
    public func downloadURL(for path: String, revision: String? = nil) -> URL {
        let pinned = revision ?? self.revision
        return URL(string: "https://huggingface.co/" + repository + "/resolve/" + pinned + "/" + path)!
    }

    /// The folder the installed copy lives in, once someone downloads it.
    public func directory(in applicationDirectory: URL, revision: String? = nil) -> URL {
        let pinned = revision ?? self.revision
        let root = applicationDirectory.appending(path: installPath, directoryHint: .isDirectory)
        return root
            .appending(path: repository, directoryHint: .isDirectory)
            .appending(path: pinned, directoryHint: .isDirectory)
    }

    /// The folder a hub client reads installed copies from, before the revision is applied.
    public func repositoryDirectory(in applicationDirectory: URL) -> URL {
        applicationDirectory
            .appending(path: installPath, directoryHint: .isDirectory)
            .appending(path: repository, directoryHint: .isDirectory)
    }

    public static let embeddingGemmaID = "embeddinggemma"

    /// The model that writes the brief of a finished call.
    ///
    /// It is not part of transcription and nothing in the pipeline needs it, so it is the one
    /// component a person can leave undownloaded and never notice. The id is written where the app
    /// asks what a brief was written by, so it is a name rather than a label: CallBrief.modelID.
    public static let callBriefID = "call-brief"

    /// The file inside the brief model's folder that the runtime loads.
    public var ggufFileName: String? {
        guard id == Self.callBriefID else { return nil }
        return files.first { $0.path.hasSuffix(".gguf") }?.path
    }

    /// Names the revision that is installed, beside the model folders.
    ///
    /// The runtime that reads these files is handed a folder, not a revision, so the installed
    /// revision has to be written down where that runtime can read it. Without this, an app
    /// build and an installed model that drifted apart would fail as a load error rather than as
    /// a message.
    public static let installedMarkerName = "installed.json"

    /// The silence filter whisper.cpp runs when it is handed a long call.
    ///
    /// It used to travel inside the app. It is 865 KB and needs no setup, so bundling it looked
    /// free, but every model the app downloads instead of carrying is a model that can be fixed
    /// without a new build. The host publishes the same bytes it always did:
    /// ggml-org/whisper-vad carries the converted 6.2.0 file, which is the one whisper.cpp loads.
    public static let sileroVADID = "silero-vad"
    public static let sileroVADFileName = "ggml-silero-v6.2.0.bin"
    public static let sileroVADBytes: Int64 = 885_098
    public static let sileroVADSHA256 =
        "2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987"

    /// The models this build needs beyond Whisper.
    ///
    /// The hashes and the sizes are the bytes the host serves at the revision named here. The
    /// small files are hashed by this build rather than quoted from the host, because the host
    /// publishes a hash only for files it stores through its large-file service. Pinning them
    /// here is the same guarantee: a substituted file is refused instead of installed.
    public static let catalog: [SupportingModel] = [
        SupportingModel(
            id: sileroVADID,
            displayName: "Silero VAD 6.2.0",
            detail: "Filters silence so a long call transcribes in segments instead of one pass "
                + "that can lose its place. Downloaded once, then used offline.",
            repository: "ggml-org/whisper-vad",
            revision: "9ffd54a1e1ee413ddf265af9913beaf518d1639b",
            installPath: "models/vad",
            versionLabel: "6.2.0, ggml",
            files: [
                SupportingModelFile(
                    path: sileroVADFileName,
                    bytes: sileroVADBytes,
                    sha256: sileroVADSHA256
                )
            ]
        ),
        SupportingModel(
            id: embeddingGemmaID,
            displayName: "EmbeddingGemma 300M",
            detail: "Turns transcript text into vectors so search can find a passage by meaning "
                + "rather than by keyword. Downloaded once, then used offline.",
            repository: "onnx-community/embeddinggemma-300m-ONNX",
            revision: "5090578d9565bb06545b4552f76e6bc2c93e4a66",
            installPath: "models/embeddinggemma",
            versionLabel: "300M, q4, 256 dimensions",
            files: [
                SupportingModelFile(
                    path: "config.json",
                    bytes: 1_765,
                    sha256: "6e1f06404b7163e0325ed2ea3e6781cde50f4a50b31780a95ad0d30e8404d77b"
                ),
                SupportingModelFile(
                    path: "tokenizer.json",
                    bytes: 20_323_312,
                    sha256: "4dda02faaf32bc91031dc8c88457ac272b00c1016cc679757d1c441b248b9c47"
                ),
                SupportingModelFile(
                    path: "tokenizer_config.json",
                    bytes: 1_156_830,
                    sha256: "3ca953eea6c3c9fcda9cf3df22949ff18b216f7c74bd6459230f3f1013953f3a"
                ),
                SupportingModelFile(
                    path: "onnx/model_q4.onnx",
                    bytes: 519_322,
                    sha256: "ad1dfee81a70f7944b9b9d1cc6e48075b832881cf33fab2f2b248be78f3f0043"
                ),
                SupportingModelFile(
                    path: "onnx/model_q4.onnx_data",
                    bytes: 196_725_760,
                    sha256: "599962c3143b040de2dd05e5975be3e9091dd067cacc6a8f7186e3203bab9e02"
                ),
            ]
        ),
        SupportingModel(
            id: callBriefID,
            displayName: "Qwen3 4B Instruct 2507",
            detail: "Writes the brief of a finished call: what it was about, what was agreed, who "
                + "owes what. It is the one model here that reads, so it is the largest. "
                + "Downloaded once, then used offline.",
            repository: "unsloth/Qwen3-4B-Instruct-2507-GGUF",
            revision: "a06e946bb6b655725eafa393f4a9745d460374c9",
            installPath: "models/call-brief",
            versionLabel: "4B, Q4_K_M",
            files: [
                SupportingModelFile(
                    path: "Qwen3-4B-Instruct-2507-Q4_K_M.gguf",
                    bytes: 2_497_281_120,
                    sha256: "3605803b982cb64aead44f6c1b2ae36e3acdb41d8e46c8a94c6533bc4c67e597"
                )
            ]
        )
    ]
}

/// What Call Recorder can say about the installed copy of a supporting model.
public enum SupportingModelDecision: Equatable, Sendable {
    case upToDate
    /// The host publishes something other than what is installed: a newer revision, or a copy
    /// that no longer matches. Both are answered by downloading the published copy again.
    case updateAvailable(SupportingModelUpdate)
    /// The check could not reach a verdict, so the installed copy is left alone.
    case cannotVerify(reason: String)

    public var isUpdateAvailable: Bool {
        if case .updateAvailable = self { return true }
        return false
    }

    public var hasVerdict: Bool {
        if case .cannotVerify = self { return false }
        return true
    }

    public var reason: String? {
        if case .cannotVerify(let reason) = self { return reason }
        return nil
    }
}

public struct SupportingModelUpdate: Equatable, Sendable {
    public let revision: String
    public let files: [SupportingModelFile]

    public init(revision: String, files: [SupportingModelFile]) {
        self.revision = revision
        self.files = files
    }

    public var totalBytes: Int64 {
        files.reduce(0) { $0 + $1.bytes }
    }
}

public enum SupportingModelChecker {
    /// Compares what is installed with what the host publishes.
    ///
    /// A verdict needs a hash on both sides. A host that stops publishing hashes, or a copy
    /// installed before Call Recorder recorded one, is reported as unknown rather than silently
    /// treated as current.
    public static func decision(
        model: SupportingModel,
        installed: InstalledSupportingModel?,
        remote: ModelHostMetadata,
        installedBlobIDs: [String: String] = [:]
    ) -> SupportingModelDecision {
        guard let installed, !installed.files.isEmpty else {
            return .cannotVerify(reason: "Call Recorder has not verified this model copy yet.")
        }
        var remoteFiles: [SupportingModelFile] = []
        for file in model.files {
            guard let published = remote.files[file.path] else {
                return .cannotVerify(reason: "The host does not publish " + file.path + " any more.")
            }
            if !published.sha256.isEmpty {
                remoteFiles.append(
                    SupportingModelFile(
                        path: file.path,
                        bytes: published.bytes,
                        sha256: published.sha256.lowercased()
                    )
                )
                continue
            }
            // A small file carries no SHA-256 in the host's listing. What it carries is the name
            // the file has in the host's repository, which is a hash of the contents too, so the
            // copy on disk can be checked against it instead of the check giving up.
            guard let blobID = published.blobID, !blobID.isEmpty else {
                return .cannotVerify(
                    reason: "The host does not publish a hash for " + file.path + "."
                )
            }
            remoteFiles.append(
                SupportingModelFile(
                    path: file.path,
                    bytes: published.bytes,
                    sha256: "",
                    blobID: blobID.lowercased()
                )
            )
        }
        let installedByPath = Dictionary(
            installed.files.map { ($0.path, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var sameFiles = true
        for file in remoteFiles {
            guard let copy = installedByPath[file.path] else {
                sameFiles = false
                break
            }
            if !file.sha256.isEmpty {
                sameFiles = copy.sha256.lowercased() == file.sha256
            } else if let blobID = file.blobID {
                // The name of the file in the host's repository, computed from the bytes on disk.
                // Without it the copy cannot be judged, and saying so is better than calling it
                // either current or out of date.
                guard let onDisk = installedBlobIDs[file.path]?.lowercased() else {
                    return .cannotVerify(
                        reason: "Call Recorder could not read " + file.path + " to check it."
                    )
                }
                sameFiles = onDisk == blobID
            } else {
                sameFiles = false
            }
            if !sameFiles { break }
        }
        if installed.revision == remote.revision, sameFiles { return .upToDate }
        return .updateAvailable(
            SupportingModelUpdate(revision: remote.revision, files: remoteFiles)
        )
    }
}
