import CryptoKit
import Foundation
import Testing
@testable import CallRecorderCore

struct SupportingModelTests {
    /// The model that turns text into vectors, named rather than indexed, so that adding a model to
    /// the catalog cannot quietly point these tests at a different one.
    private static let embeddingModel = SupportingModel.catalog.first {
        $0.id == SupportingModel.embeddingGemmaID
    }!

    /// The model every recording is read with.
    private static let transcriptionModel = SupportingModel.catalog.first {
        $0.id == SupportingModel.qwen3ASRID
    }!

    @Test func theEmbeddingModelIsPinnedFileByFile() {
        // Given / When
        let models = SupportingModel.catalog

        // Then
        // Every model the app downloads, in one list: the names are here so that adding one cannot
        // quietly point these tests at a different model.
        #expect(
            models.map(\.id) == [
                SupportingModel.qwen3ASRID,
                SupportingModel.embeddingGemmaID,
            ]
        )
        let model = Self.embeddingModel
        #expect(model.repository == "onnx-community/embeddinggemma-300m-ONNX")
        #expect(model.files.allSatisfy { $0.sha256.count == 64 && $0.bytes > 0 })
        #expect(Set(model.files.map(\.path)).count == model.files.count)
        // The two files the host stores through its large-file service, and the three it does not:
        // every one of them carries a hash this build pinned.
        #expect(model.files.map(\.path).contains("onnx/model_q4.onnx_data"))
        #expect(model.totalBytes > 200_000_000)
    }

    @Test func theTranscriptionModelIsPinnedFileByFile() {
        // Given / When
        let model = Self.transcriptionModel

        // Then it is the eight-bit copy of the model, every file pinned to a hash this build
        // checked against the host's own bytes, and the folder the script loads it from is the
        // folder the download writes.
        #expect(model.repository == "mlx-community/Qwen3-ASR-1.7B-8bit")
        #expect(model.installPath == "models")
        #expect(model.revision.count == 40)
        #expect(model.files.map(\.path).contains("model.safetensors"))
        #expect(model.files.map(\.path).contains("config.json"))
        #expect(model.files.allSatisfy { $0.sha256.count == 64 && $0.bytes > 0 })
        // Two and a half gigabytes of weights, and the files a tokenizer reads beside them.
        #expect(model.totalBytes > 2_000_000_000)
        #expect(model.totalBytes < 3_000_000_000)
    }

    @Test func aFileIsFetchedFromThePinnedRevision() {
        // Given
        let model = Self.embeddingModel

        // When
        let address = model.downloadURL(for: "onnx/model_q4.onnx")

        // Then
        #expect(
            address.absoluteString == "https://huggingface.co/onnx-community/embeddinggemma-300m-ONNX"
                + "/resolve/" + model.revision + "/onnx/model_q4.onnx"
        )
    }

    @Test func theInstalledCopyLivesWhereTheRuntimeLooksForIt() {
        // Given
        let model = Self.embeddingModel
        let root = URL(filePath: "/Users/someone/Library/Application Support/CallRecorder")

        // When
        let directory = model.directory(in: root)

        // Then the revision is in the path, because the runtime addresses the model by it.
        #expect(
            directory.path.hasSuffix(
                "models/embeddinggemma/onnx-community/embeddinggemma-300m-ONNX/" + model.revision
            )
        )
        #expect(directory.path.hasPrefix(root.path))
    }

    @Test func aMatchingCopyIsReportedAsCurrent() {
        // Given
        let model = Self.embeddingModel
        let installed = installedRecord(for: model, revision: model.revision)
        let remote = remoteMetadata(for: model, revision: model.revision)

        // When
        let decision = SupportingModelChecker.decision(
            model: model,
            installed: installed,
            remote: remote
        )

        // Then
        #expect(decision == .upToDate)
        #expect(decision.hasVerdict)
        #expect(!decision.isUpdateAvailable)
    }

    @Test func aNewerRevisionOnTheHostIsAnUpdate() {
        // Given
        let model = Self.embeddingModel
        let installed = installedRecord(for: model, revision: model.revision)
        let remote = remoteMetadata(for: model, revision: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")

        // When
        let decision = SupportingModelChecker.decision(
            model: model,
            installed: installed,
            remote: remote
        )

        // Then
        guard case .updateAvailable(let update) = decision else {
            Issue.record("expected an update, got \(decision)")
            return
        }
        #expect(update.revision == "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
        #expect(update.totalBytes == model.totalBytes)
    }

    @Test func aCopyThatNoLongerMatchesTheHostIsAnUpdate() {
        // Given the same revision, but a file whose bytes differ from the published ones.
        let model = Self.embeddingModel
        var files = model.files.map {
            InstalledSupportingFile(path: $0.path, bytes: $0.bytes, sha256: $0.sha256)
        }
        files[0] = InstalledSupportingFile(path: files[0].path, bytes: 12, sha256: String(repeating: "0", count: 64))
        let installed = InstalledSupportingModel(
            modelID: model.id,
            revision: model.revision,
            installedAt: Date(),
            files: files
        )

        // When
        let decision = SupportingModelChecker.decision(
            model: model,
            installed: installed,
            remote: remoteMetadata(for: model, revision: model.revision)
        )

        // Then
        #expect(decision.isUpdateAvailable)
    }

    @Test func anUnrecordedCopyIsNotCalledCurrent() {
        // Given / When
        let decision = SupportingModelChecker.decision(
            model: Self.embeddingModel,
            installed: nil,
            remote: remoteMetadata(for: Self.embeddingModel, revision: "whatever")
        )

        // Then
        #expect(!decision.hasVerdict)
        #expect(decision.reason == "Call Recorder has not verified this model copy yet.")
    }

    @Test func aFileTheHostStopsPublishingIsNotAVerdict() {
        // Given a host answer that is missing one of the files the app needs.
        let model = Self.embeddingModel
        let complete = remoteMetadata(for: model, revision: model.revision)
        var files = complete.files
        files["onnx/model_q4.onnx_data"] = nil
        let remote = ModelHostMetadata(revision: complete.revision, files: files)

        // When
        let decision = SupportingModelChecker.decision(
            model: model,
            installed: installedRecord(for: model, revision: model.revision),
            remote: remote
        )

        // Then
        #expect(!decision.hasVerdict)
        #expect(decision.reason?.contains("onnx/model_q4.onnx_data") == true)
    }

    @Test func theManifestSurvivesARoundTripAndAReinstall() throws {
        // Given
        let root = FileManager.default.temporaryDirectory
            .appending(path: "supporting-manifest-\(UUID().uuidString)", directoryHint: .isDirectory)
        let url = root.appending(path: "components.json")
        let model = Self.embeddingModel
        var manifest = SupportingModelManifest()
        manifest.record(installedRecord(for: model, revision: model.revision))

        // When
        try manifest.write(to: url)
        let reloaded = SupportingModelManifest.load(from: url)

        // Then the record is read back whole. The date is compared to the second, because the
        // manifest stores it as ISO-8601 and that drops the fraction the two values were written
        // with.
        #expect(reloaded.record(for: model.id)?.files == manifest.record(for: model.id)?.files)
        #expect(reloaded.record(for: model.id)?.revision == model.revision)
        #expect(
            Int(reloaded.record(for: model.id)?.installedAt.timeIntervalSince1970 ?? 0)
                == Int(manifest.record(for: model.id)?.installedAt.timeIntervalSince1970 ?? -1)
        )

        // And when the record is removed it stays removed.
        var emptied = reloaded
        emptied.remove(model.id)
        try emptied.write(to: url)
        #expect(SupportingModelManifest.load(from: url).record(for: model.id) == nil)

        try? FileManager.default.removeItem(at: root)
    }

    @Test func aMissingManifestReadsAsEmptyRatherThanFailing() {
        // Given / When
        let manifest = SupportingModelManifest.load(
            from: URL(filePath: "/tmp/definitely-not-written-\(UUID().uuidString).json")
        )

        // Then
        #expect(manifest.records.isEmpty)
    }

    // MARK: - Fixtures

    /// A record that says every file was verified at the given revision.
    private func installedRecord(
        for model: SupportingModel,
        revision: String
    ) -> InstalledSupportingModel {
        InstalledSupportingModel(
            modelID: model.id,
            revision: revision,
            installedAt: Date(),
            files: model.files.map {
                InstalledSupportingFile(path: $0.path, bytes: $0.bytes, sha256: $0.sha256)
            }
        )
    }

    /// What the host answers for the given revision, with the hashes this build pinned.
    private func remoteMetadata(
        for model: SupportingModel,
        revision: String
    ) -> ModelHostMetadata {
        var files: [String: RemoteModelFile] = [:]
        for file in model.files {
            files[file.path] = RemoteModelFile(
                fileName: file.path,
                bytes: file.bytes,
                sha256: file.sha256
            )
        }
        return ModelHostMetadata(revision: revision, files: files)
    }

    /// The bytes of the small file the tests below are about, and the name the host gives them.
    private static let smallFileBytes = Data("{\"hidden_size\": 768}\n".utf8)
    private static var smallFileName: String {
        ModelFileVerifier.gitBlobSHA1(of: smallFileBytes)
    }

    /// A model with one small file, of the kind a host does not hash with a SHA-256.
    ///
    /// The embedding model is exactly this shape: two of its five files are a config.json and a
    /// tokenizer configuration, and the host describes those by the name they have in its
    /// repository. The tests use a model of their own so the shape can be exercised without the
    /// host's answer for the real one.
    private func modelWithASmallFile() -> SupportingModel {
        SupportingModel(
            id: "small-file-model",
            displayName: "Small file model",
            detail: "",
            repository: "example/small",
            revision: String(repeating: "a", count: 40),
            installPath: "models/small",
            versionLabel: "1",
            files: [
                SupportingModelFile(
                    path: "config.json",
                    bytes: Int64(Self.smallFileBytes.count),
                    sha256: "",
                    blobID: Self.smallFileName
                )
            ]
        )
    }

    /// That model installed at its own revision, with nothing recorded about the file's Git name:
    /// a copy installed before the app knew to look for one.
    private func smallFileInstalledCopy(_ model: SupportingModel) -> InstalledSupportingModel {
        InstalledSupportingModel(
            modelID: model.id,
            revision: model.revision,
            installedAt: Date(),
            files: [
                InstalledSupportingFile(
                    path: "config.json",
                    bytes: Int64(Self.smallFileBytes.count),
                    sha256: String(repeating: "0", count: 64)
                )
            ]
        )
    }

    /// What the host answers for that file: no SHA-256, and the name it has in the repository.
    private func smallFileRemoteAnswer(revision: String) -> ModelHostMetadata {
        ModelHostMetadata(
            revision: revision,
            files: [
                "config.json": RemoteModelFile(
                    fileName: "config.json",
                    bytes: Int64(Self.smallFileBytes.count),
                    sha256: "",
                    blobID: Self.smallFileName
                )
            ]
        )
    }

    @Test func aSmallFileTheHostNamesIsCheckedByThatName() {
        // Given the shape the host publishes the embedding model's small files in: no SHA-256, and
        // the name the file has in the host's repository instead.
        let model = modelWithASmallFile()
        let installed = smallFileInstalledCopy(model)
        let remote = smallFileRemoteAnswer(revision: model.revision)

        // When the copy on disk is the published one
        let same = SupportingModelChecker.decision(
            model: model,
            installed: installed,
            remote: remote,
            installedBlobIDs: ["config.json": Self.smallFileName]
        )

        // Then it is current, which the check could not say at all before: it reported that the
        // host publishes no hash, over a file the host had published a hash for.
        #expect(same == .upToDate)

        // When the copy on disk is something else
        let differing = SupportingModelChecker.decision(
            model: model,
            installed: installed,
            remote: remote,
            installedBlobIDs: ["config.json": String(repeating: "f", count: 40)]
        )

        // Then the published copy is offered, and the offer carries the name, so the download can
        // check what arrives the same way.
        guard case .updateAvailable(let update) = differing else {
            Issue.record("expected an update, got \(differing)")
            return
        }
        #expect(update.files.map(\.path) == ["config.json"])
        #expect(update.files[0].blobID == Self.smallFileName)
        #expect(update.files[0].sha256.isEmpty)
    }

    @Test func aSmallFileThatCouldNotBeReadIsNotAVerdict() {
        // Given a copy whose small file could not be read back, which is the one case where the
        // name on disk is unknown.
        let model = modelWithASmallFile()

        // When
        let decision = SupportingModelChecker.decision(
            model: model,
            installed: smallFileInstalledCopy(model),
            remote: smallFileRemoteAnswer(revision: model.revision),
            installedBlobIDs: [:]
        )

        // Then the check says what it does not know, rather than calling the copy current or
        // offering an update it cannot justify.
        #expect(!decision.hasVerdict)
        #expect(decision.reason?.contains("config.json") == true)
    }

    @Test func aHostThatNamesNothingIsStillNotAVerdict() {
        // Given a file the host lists with neither a SHA-256 nor a name for it.
        let model = modelWithASmallFile()
        let remote = ModelHostMetadata(
            revision: model.revision,
            files: [
                "config.json": RemoteModelFile(
                    fileName: "config.json",
                    bytes: Int64(Self.smallFileBytes.count),
                    sha256: ""
                )
            ]
        )

        // When
        let decision = SupportingModelChecker.decision(
            model: model,
            installed: smallFileInstalledCopy(model),
            remote: remote,
            installedBlobIDs: ["config.json": Self.smallFileName]
        )

        // Then
        #expect(!decision.hasVerdict)
        #expect(decision.reason == "The host does not publish a hash for config.json.")
    }
}
