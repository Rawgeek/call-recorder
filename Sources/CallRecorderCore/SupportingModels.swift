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
/// The embedding model is a dependency of transcript search, and it cannot be shipped inside the
/// app because it is larger than the app itself, so it is downloaded once and verified like
/// everything else. The transcription model is downloaded the same way.
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

    /// The model every recording is read with.
    ///
    /// Qwen3-ASR 1.7B at eight bits, run by MLX. Measured on this Mac on a seventy-minute Russian
    /// call: 8,547 words over the whole recording in 6.3 minutes through the app's own path -- the
    /// conversion to 16 kHz mono, then 359 pieces -- where the Neural Engine model that read it
    /// before answered about eight thousand words and whisper.cpp six and a half thousand for the
    /// same file, and where the library's own long-audio path lost the second half of the call to a
    /// token budget. The eight-bit copy is the one whose answers held every participant name.
    public static let qwen3ASRID = "qwen3-asr-1.7b-8bit"

    /// The folder the transcription model is read from.
    ///
    /// A revision is written into the path, so a model that was updated while a call was being
    /// read does not pull the files out from under the run.
    public static func qwenModel(in applicationDirectory: URL, revision: String? = nil) -> URL {
        guard let model = catalog.first(where: { $0.id == qwen3ASRID }) else {
            return applicationDirectory.appending(path: "models", directoryHint: .isDirectory)
        }
        return model.directory(in: applicationDirectory, revision: revision)
    }

    /// Names the revision that is installed, beside the model folders.
    ///
    /// The runtime that reads these files is handed a folder, not a revision, so the installed
    /// revision has to be written down where that runtime can read it. Without this, an app
    /// build and an installed model that drifted apart would fail as a load error rather than as
    /// a message.
    public static let installedMarkerName = "installed.json"

    /// The models this build needs beyond the transcription model.
    ///
    /// The hashes and the sizes are the bytes the host serves at the revision named here. The
    /// small files are hashed by this build rather than quoted from the host, because the host
    /// publishes a hash only for files it stores through its large-file service. Pinning them
    /// here is the same guarantee: a substituted file is refused instead of installed.
    public static let catalog: [SupportingModel] = [
        SupportingModel(
            id: qwen3ASRID,
            displayName: "Qwen3-ASR 1.7B",
            detail: "Reads a recording into words in Russian and English, including a call that "
                + "mixes them, and names the language it found. Downloaded once, then used offline.",
            repository: "mlx-community/Qwen3-ASR-1.7B-8bit",
            revision: "a8379a2e2f9e313c9292cdf1af4055ab56d50d55",
            installPath: "models",
            versionLabel: "1.7B, 8-bit, MLX",
            files: [
                SupportingModelFile(
                    path: "chat_template.json",
                    bytes: 1161,
                    sha256: "75a8cfca24f00de72d796fbfed6858fc9614ef3dabd8696684cc3bc03a9c58ff"
                ),
                SupportingModelFile(
                    path: "config.json",
                    bytes: 7188,
                    sha256: "1b76b3b6c655fc54595da025f7a96474ad9fa86363303fbdd61a7d8483ccfaf7"
                ),
                SupportingModelFile(
                    path: "generation_config.json",
                    bytes: 142,
                    sha256: "1da527824d81e07118facff437e03f2e24a23311e3bdeb2368973fe77e5f275c"
                ),
                SupportingModelFile(
                    path: "merges.txt",
                    bytes: 1671853,
                    sha256: "8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5"
                ),
                SupportingModelFile(
                    path: "model.safetensors.index.json",
                    bytes: 78968,
                    sha256: "0a5d0ec11188602242ff81a9969883d0fdeb98cd5d85cd1413089d897c201af5"
                ),
                SupportingModelFile(
                    path: "model.safetensors",
                    bytes: 2463307541,
                    sha256: "bf304b009cc7eca79283056f787b44c952d24ac22cec787b39732bba3c23c13c"
                ),
                SupportingModelFile(
                    path: "preprocessor_config.json",
                    bytes: 330,
                    sha256: "45e120a4eda2c20c5d7f2ea9354e63536bf35e27aa573fb7cdf78017b378770d"
                ),
                SupportingModelFile(
                    path: "tokenizer_config.json",
                    bytes: 12487,
                    sha256: "4942d005604266809309cabc9f4e9cb89ce855d59b14681fdc0e1cc62ea26c4c"
                ),
                SupportingModelFile(
                    path: "vocab.json",
                    bytes: 2776833,
                    sha256: "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910"
                ),
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
