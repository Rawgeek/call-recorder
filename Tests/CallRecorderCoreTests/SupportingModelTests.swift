import CryptoKit
import Foundation
import Testing
@testable import CallRecorderCore

struct SupportingModelTests {
    @Test func theEmbeddingModelIsPinnedFileByFile() {
        // Given / When
        let models = SupportingModel.catalog

        // Then
        #expect(models.map(\.id) == [SupportingModel.embeddingGemmaID])
        let model = models[0]
        #expect(model.repository == "onnx-community/embeddinggemma-300m-ONNX")
        #expect(model.files.allSatisfy { $0.sha256.count == 64 && $0.bytes > 0 })
        #expect(Set(model.files.map(\.path)).count == model.files.count)
        // The two files the host stores through its large-file service, and the three it does not:
        // every one of them carries a hash this build pinned.
        #expect(model.files.map(\.path).contains("onnx/model_q4.onnx_data"))
        #expect(model.totalBytes > 200_000_000)
    }

    @Test func aFileIsFetchedFromThePinnedRevision() {
        // Given
        let model = SupportingModel.catalog[0]

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
        let model = SupportingModel.catalog[0]
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
        let model = SupportingModel.catalog[0]
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
        let model = SupportingModel.catalog[0]
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
        let model = SupportingModel.catalog[0]
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
            model: SupportingModel.catalog[0],
            installed: nil,
            remote: remoteMetadata(for: SupportingModel.catalog[0], revision: "whatever")
        )

        // Then
        #expect(!decision.hasVerdict)
        #expect(decision.reason == "Call Recorder has not verified this model copy yet.")
    }

    @Test func aFileTheHostStopsPublishingIsNotAVerdict() {
        // Given a host answer that is missing one of the files the app needs.
        let model = SupportingModel.catalog[0]
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
        let model = SupportingModel.catalog[0]
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
}
