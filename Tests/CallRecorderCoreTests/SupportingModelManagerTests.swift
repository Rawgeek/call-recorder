import CryptoKit
import Foundation
import Testing
@testable import CallRecorderApp
@testable import CallRecorderCore

/// The manager downloads, verifies, swaps, and records. These tests drive it against a host and a
/// file source they own, so nothing here touches the network or the models a Mac has installed.
@MainActor
struct SupportingModelManagerTests {
    @Test func downloadInstallsEveryVerifiedFileAndRecordsTheRevision() async throws {
        // Given
        let workspace = makeWorkspace()
        defer { workspace.cleanUp() }
        let manager = workspace.manager()

        // When
        manager.download(workspace.model)
        await waitForDownload(manager, workspace.model)

        // Then every file is in place at the revision the host published.
        #expect(manager.state(for: workspace.model).isInstalled)
        let directory = workspace.model.directory(in: workspace.root)
        for file in workspace.model.files {
            let url = directory.appending(path: file.path)
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
        #expect(manager.record(for: workspace.model)?.revision == workspace.model.revision)
        #expect(manager.installedBytes(for: workspace.model) == workspace.model.totalBytes)

        // And the revision is written where the runtime that reads the model can find it.
        let marker = workspace.root.appending(path: "models/sample/installed.json")
        let document = try JSONSerialization.jsonObject(with: Data(contentsOf: marker))
        let fields = try #require(document as? [String: Any])
        #expect(fields["revision"] as? String == workspace.model.revision)
        #expect(fields["model"] as? String == workspace.model.repository)
    }

    @Test func aFileThatDoesNotMatchItsPublishedHashIsNeverInstalled() async throws {
        // Given a host that serves one file with bytes other than the ones it published.
        let workspace = makeWorkspace(tamperingWith: "config.json")
        defer { workspace.cleanUp() }
        let manager = workspace.manager()

        // When
        manager.download(workspace.model)
        await waitForDownload(manager, workspace.model)

        // Then nothing was installed, and the failure is kept for the settings window to show.
        #expect(!manager.state(for: workspace.model).isInstalled)
        #expect(manager.failure(for: workspace.model) != nil)
        #expect(manager.record(for: workspace.model) == nil)
        let directory = workspace.model.directory(in: workspace.root)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        // The staging folder goes too, so a retry starts from nothing.
        let staging = directory
            .deletingLastPathComponent()
            .appending(path: directory.lastPathComponent + ".incoming", directoryHint: .isDirectory)
        #expect(!FileManager.default.fileExists(atPath: staging.path))
    }

    @Test func anUpdateInstallsTheNewRevisionAndKeepsTheOldOneToGoBack() async throws {
        // Given a freshly installed copy at the first revision.
        let workspace = makeWorkspace()
        defer { workspace.cleanUp() }
        let manager = workspace.manager()
        manager.download(workspace.model)
        await waitForDownload(manager, workspace.model)

        // When the host publishes a second revision and the update is applied.
        let second: String = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        workspace.host.answers[workspace.model.repository] = workspace.metadata(revision: second)
        await manager.checkForUpdates()
        #expect(manager.decision(for: workspace.model)?.isUpdateAvailable == true)
        manager.applyUpdate(workspace.model)
        await waitForDownload(manager, workspace.model)

        // Then the record names the new revision and the earlier one is still on disk.
        #expect(manager.record(for: workspace.model)?.revision == second)
        #expect(manager.canRevert(workspace.model))
        #expect(
            FileManager.default.fileExists(
                atPath: workspace.model.directory(in: workspace.root).path
            )
        )

        // And going back is one write: the runtime is pointed at the earlier revision again.
        try manager.revert(workspace.model)
        #expect(manager.record(for: workspace.model)?.revision == workspace.model.revision)
        let marker = workspace.root.appending(path: "models/sample/installed.json")
        let document = try JSONSerialization.jsonObject(with: Data(contentsOf: marker))
        let fields = try #require(document as? [String: Any])
        #expect(fields["revision"] as? String == workspace.model.revision)
    }

    @Test func aCopyInstalledBeforeRecordsExistedIsHashedOnceThenCalledCurrent() async throws {
        // Given files on disk with no record of what they are.
        let workspace = makeWorkspace()
        defer { workspace.cleanUp() }
        let directory = workspace.model.directory(in: workspace.root)
        for file in workspace.model.files {
            let url = directory.appending(path: file.path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try workspace.payloads[file.path]?.write(to: url)
        }
        let manager = workspace.manager()
        #expect(manager.state(for: workspace.model).isInstalled)
        #expect(manager.record(for: workspace.model) == nil)

        // When
        await manager.bootstrapManifest()
        await manager.checkForUpdates()

        // Then the copy is recorded at the revision its folder names, and the host agrees.
        #expect(manager.record(for: workspace.model)?.revision == workspace.model.revision)
        #expect(manager.decision(for: workspace.model) == .upToDate)

        // And the revision is written down where the runtime that reads this model looks for it.
        let marker = workspace.root.appending(path: "models/sample/installed.json")
        let document = try JSONSerialization.jsonObject(with: Data(contentsOf: marker))
        let fields = try #require(document as? [String: Any])
        #expect(fields["revision"] as? String == workspace.model.revision)
    }

    @Test func aSecondCopyOutsideTheManagedFolderIsReportedWithItsSize() async throws {
        // Given a stray copy where an earlier build cached one.
        let workspace = makeWorkspace()
        defer { workspace.cleanUp() }
        let stray = workspace.root.appending(path: "models/example/sample-model")
        try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: true)
        try Data(repeating: 3, count: 4_096).write(to: stray.appending(path: "leftover.bin"))
        let manager = workspace.manager()

        // When
        await manager.checkForUpdates()

        // Then
        #expect(manager.duplicateCopies(of: workspace.model).map(\.path) == [stray.path])
        #expect(manager.reclaimableBytes(for: workspace.model) == 4_096)
    }

    @Test func deletingRemovesEveryRevisionAndTheRecord() async throws {
        // Given
        let workspace = makeWorkspace()
        defer { workspace.cleanUp() }
        let manager = workspace.manager()
        manager.download(workspace.model)
        await waitForDownload(manager, workspace.model)

        // When
        try manager.delete(workspace.model)

        // Then
        #expect(!manager.state(for: workspace.model).isInstalled)
        #expect(manager.record(for: workspace.model) == nil)
        #expect(
            !FileManager.default.fileExists(
                atPath: workspace.model.repositoryDirectory(in: workspace.root).path
            )
        )
    }

    // MARK: - Fixtures

    /// A host the tests can change their mind on, between one check and the next.
    final class Host: SupportingModelHost, @unchecked Sendable {
        var answers: [String: ModelHostMetadata]

        init(answers: [String: ModelHostMetadata]) {
            self.answers = answers
        }

        func metadata(repository: String) async throws -> ModelHostMetadata {
            guard let answer = answers[repository] else { throw StubError.noAnswer(repository) }
            return answer
        }
    }

    enum StubError: Error {
        case noAnswer(String)
    }

    struct Workspace {
        let root: URL
        let model: SupportingModel
        let host: Host
        /// The bytes the host serves, by path inside the model.
        let payloads: [String: Data]
        /// A file the host serves with bytes other than the ones it published.
        var tampered: String?

        @MainActor
        func manager() -> SupportingModelManager {
            let payloads = payloads
            let tampered = tampered
            return SupportingModelManager(
                applicationDirectory: root,
                models: [model],
                host: host,
                downloadFile: { url in
                    let name = url.lastPathComponent
                    let path = payloads.keys.first { $0.hasSuffix(name) } ?? name
                    guard var data = payloads[path] else { throw StubError.noAnswer(name) }
                    if tampered == path { data = Data(repeating: 9, count: data.count) }
                    let target = FileManager.default.temporaryDirectory
                        .appending(path: "download-" + UUID().uuidString)
                    try data.write(to: target)
                    return target
                }
            )
        }

        func metadata(revision: String) -> ModelHostMetadata {
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

        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func makeWorkspace(
        tamperingWith tampered: String? = nil,
        weightsNamed weights: String? = nil
    ) -> Workspace {
        let revision = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        var payloads: [String: Data] = [
            "config.json": Data("{\"model\": \"sample\"}".utf8),
            "onnx/model_q4.onnx": Data(repeating: 7, count: 512),
        ]
        if let weights { payloads[weights] = Data(repeating: 9, count: 256) }
        let files = payloads.keys.sorted().map { path in
            SupportingModelFile(
                path: path,
                bytes: Int64(payloads[path]!.count),
                sha256: sha256Hex(payloads[path]!)
            )
        }
        let model = SupportingModel(
            id: "sample",
            displayName: "Sample Model",
            detail: "A model the tests own.",
            repository: "example/sample-model",
            revision: revision,
            installPath: "models/sample",
            versionLabel: "sample",
            files: files
        )
        var metadata: [String: RemoteModelFile] = [:]
        for file in files {
            metadata[file.path] = RemoteModelFile(
                fileName: file.path,
                bytes: file.bytes,
                sha256: file.sha256
            )
        }
        let root = FileManager.default.temporaryDirectory
            .appending(path: "supporting-manager-\(UUID().uuidString)", directoryHint: .isDirectory)
        return Workspace(
            root: root,
            model: model,
            host: Host(answers: [model.repository: ModelHostMetadata(revision: revision, files: metadata)]),
            payloads: payloads,
            tampered: tampered
        )
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    @Test func anInstalledCopyIsFoundAfterTheCatalogRenamesIt() async throws {
        // Given a model whose weights were downloaded under one repository and one file name.
        let workspace = makeWorkspace(weightsNamed: "old-name.weights")
        defer { workspace.cleanUp() }
        let manager = workspace.manager()
        manager.download(workspace.model)
        await waitForDownload(manager, workspace.model)

        // When the catalog renames both the repository and the file, at the revision that is
        // already on disk: the copy there is the copy a runtime has to be handed.
        let renamed = SupportingModel(
            id: workspace.model.id,
            displayName: workspace.model.displayName,
            detail: workspace.model.detail,
            repository: "example/sample-model-renamed",
            revision: workspace.model.revision,
            installPath: workspace.model.installPath,
            versionLabel: workspace.model.versionLabel,
            files: [
                SupportingModelFile(
                    path: "new-name.weights",
                    bytes: 256,
                    sha256: try #require(
                        workspace.model.files.first { $0.path.hasSuffix(".weights") }
                    ).sha256
                )
            ]
        )

        // Then the installed copy is found where it was left, and its own file names are the ones
        // read: the catalog describes what is published, not what is here.
        let directory = try #require(manager.installedDirectory(for: renamed))
        #expect(directory.path.contains("sample-model"))
        #expect(!directory.path.contains("renamed"))
        #expect(
            manager.installedFilePaths(of: renamed)
                == ["config.json", "old-name.weights", "onnx/model_q4.onnx"]
        )
        #expect(
            FileManager.default.fileExists(
                atPath: directory.appending(path: "old-name.weights").path
            )
        )
    }

    @Test func aModelWithNothingInstalledNamesNoFiles() {
        // Given a manager whose library is empty.
        let workspace = makeWorkspace(weightsNamed: "old-name.weights")
        defer { workspace.cleanUp() }
        let manager = workspace.manager()

        // Then there is no copy to read, and nothing to hand a runtime.
        #expect(manager.installedDirectory(for: workspace.model) == nil)
        #expect(manager.installedFilePaths(of: workspace.model).count == 3)
        #expect(!manager.state(for: workspace.model).isInstalled)
    }

    /// Waits for the download task the manager started to finish.
    private func waitForDownload(_ manager: SupportingModelManager, _ model: SupportingModel) async {
        for _ in 0..<400 {
            if !manager.state(for: model).isDownloading { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("the download never finished")
    }
}
