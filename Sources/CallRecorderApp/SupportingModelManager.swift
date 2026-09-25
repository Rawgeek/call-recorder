import CallRecorderCore
import Foundation
import Observation
import OSLog

/// What a model host publishes, as the supporting-model manager needs to hear it.
///
/// The manager asks one question of a host, so a test can answer it without a network.
protocol SupportingModelHost: Sendable {
    func metadata(repository: String) async throws -> ModelHostMetadata
}

extension ModelHostClient: SupportingModelHost {}

/// Owns the models Call Recorder needs but does not offer a choice about.
///
/// The embedding model is the reason this exists. It is larger than the app, so it cannot ship
/// inside the bundle; it used to arrive as a side effect of the first search, downloaded by a
/// runtime that verified nothing and told the app nothing. Here it lands the way a speech model
/// does: fetched to a staging folder, checked against the bytes the host publishes, swapped in,
/// and recorded. A failure at any point leaves the working copy alone.
@MainActor
@Observable
final class SupportingModelManager {
    let models: [SupportingModel]
    private(set) var states: [String: ModelInstallState] = [:]
    private(set) var decisions: [String: SupportingModelDecision] = [:]
    /// How much of a download is done, from zero to one, while one is running.
    private(set) var progress: [String: Double] = [:]
    private(set) var checking = false
    private(set) var lastCheckedAt: Date?
    private(set) var statusMessage: String?
    private(set) var failingModels: [String: String] = [:]
    /// Model files found outside the folder Call Recorder manages, by model.
    private(set) var duplicateBytes: [String: Int64] = [:]

    /// Set by the app, so a download never replaces a file a transcription is reading.
    var isBusy: () -> Bool = { false }

    private let applicationDirectory: URL
    private let host: any SupportingModelHost
    private let downloadFile: @Sendable (URL) async throws -> URL
    private var manifest: SupportingModelManifest
    private var downloads: [String: Task<Void, Never>] = [:]
    private let logger = Logger(subsystem: "local.callrecorder.app", category: "components")

    init(
        applicationDirectory: URL,
        models: [SupportingModel] = SupportingModel.catalog,
        host: any SupportingModelHost = ModelHostClient(),
        downloadFile: @escaping @Sendable (URL) async throws -> URL = { url in
            let (temporary, response) = try await URLSession.shared.download(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
            else { throw ModelDownloadError.invalidResponse }
            return temporary
        }
    ) {
        self.models = models
        self.applicationDirectory = applicationDirectory
        self.host = host
        self.downloadFile = downloadFile
        self.manifest = SupportingModelManifest.load(from: Self.manifestURL(applicationDirectory))
        refresh()
    }

    static func manifestURL(_ applicationDirectory: URL) -> URL {
        SupportingModelManifest.defaultURL(in: applicationDirectory)
    }

    // MARK: - Reading state

    func state(for model: SupportingModel) -> ModelInstallState {
        states[model.id] ?? .notInstalled
    }

    func decision(for model: SupportingModel) -> SupportingModelDecision? {
        decisions[model.id]
    }

    func progress(for model: SupportingModel) -> Double? {
        progress[model.id]
    }

    func failure(for model: SupportingModel) -> String? {
        failingModels[model.id]
    }

    func record(for model: SupportingModel) -> InstalledSupportingModel? {
        manifest.record(for: model.id)
    }

    /// The installed record for a model named by id, for callers that hold only the name.
    func record(forID id: String) -> InstalledSupportingModel? {
        manifest.record(for: id)
    }

    /// The folder the installed copy lives in, which is the revision the record names.
    ///
    /// The catalog's repository is tried first, and then the folders beside it are searched for the
    /// revision the record names. A model whose repository was renamed by an update lives under the
    /// name it was downloaded with: the revision is what tells the copy apart from a stale one, and
    /// reading the copy that is already on disk is worth more than downloading the same bytes again
    /// under a name it never had.
    func installedDirectory(for model: SupportingModel) -> URL? {
        if let record = manifest.record(for: model.id) {
            let directory = model.directory(in: applicationDirectory, revision: record.revision)
            if Self.directoryExists(directory) { return directory }
            if let renamed = directoryHolding(revision: record.revision, of: model) { return renamed }
        }
        let pinned = model.directory(in: applicationDirectory)
        return Self.directoryExists(pinned) ? pinned : nil
    }

    /// The paths of the files the installed copy is made of.
    ///
    /// The installed record describes the copy that is on disk. The catalog describes the copy
    /// being published, and its file names change when the model does: reading the catalog's names
    /// against an older copy reports a model that is installed as one that is not.
    func installedFilePaths(of model: SupportingModel) -> [String] {
        manifest.record(for: model.id)?.files.map(\.path) ?? model.files.map(\.path)
    }

    /// A folder under the model's install path that holds the given revision, whichever repository
    /// directory it sits in.
    private func directoryHolding(revision: String, of model: SupportingModel) -> URL? {
        let root = applicationDirectory.appending(
            path: model.installPath,
            directoryHint: .isDirectory
        )
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return nil }
        for case let candidate as URL in enumerator {
            guard candidate.lastPathComponent == revision, Self.directoryExists(candidate) else {
                continue
            }
            return candidate
        }
        return nil
    }

    /// The disk space the installed copy occupies.
    func installedBytes(for model: SupportingModel) -> Int64 {
        if let record = manifest.record(for: model.id) { return record.totalBytes }
        guard let directory = installedDirectory(for: model) else { return 0 }
        return model.files.reduce(0) { total, file in
            total + Self.fileSize(directory.appending(path: file.path))
        }
    }

    func canRevert(_ model: SupportingModel) -> Bool {
        guard let previous = manifest.record(for: model.id)?.previousRevision else { return false }
        return Self.directoryExists(model.directory(in: applicationDirectory, revision: previous))
    }

    /// The folder an earlier build cached this model under.
    ///
    /// A hub client caches files under whichever folder it was pointed at, and an earlier build
    /// pointed it at the models folder itself, so that is where a second copy can be.
    private func earlierCacheDirectory(of model: SupportingModel) -> URL? {
        let owner = String(model.repository.prefix { $0 != "/" })
        guard !owner.isEmpty, owner.count < model.repository.count else { return nil }
        let name = String(model.repository.dropFirst(owner.count + 1))
        return applicationDirectory
            .appending(path: "models", directoryHint: .isDirectory)
            .appending(path: owner, directoryHint: .isDirectory)
            .appending(path: name, directoryHint: .isDirectory)
    }

    /// The files of a cached copy that is really there, which is what an earlier build left.
    ///
    /// The folder alone does not prove a copy exists. The app installs today's copy at
    /// `models/<repository>/<revision>`, so for the model whose install path is the models folder
    /// the two paths are the same folder -- and a row that read the folder alone reported the copy
    /// the app was reading with as a duplicate, sized it, and offered to move it to the Trash. The
    /// files decide: a cached copy holds the model's files in the folder itself, and a copy the app
    /// manages holds them one folder deeper, under the revision it was installed at.
    func cachedCopyFiles(of model: SupportingModel) -> [URL] {
        guard let directory = earlierCacheDirectory(of: model), Self.directoryExists(directory)
        else { return [] }
        let paths = Set(installedFilePaths(of: model) + model.files.map(\.path))
        return paths.sorted()
            .map { directory.appending(path: $0) }
            .filter { Self.isRegularFile($0) }
    }

    func reclaimableBytes(for model: SupportingModel) -> Int64 {
        duplicateBytes[model.id] ?? 0
    }

    /// Moves a cached copy's own files to the Trash. Recoverable on purpose: Call Recorder did not
    /// write them.
    ///
    /// Only the files are moved, never the folder: for a model installed under the models folder
    /// that folder is the app's own repository directory, and the copy inside it, under the
    /// revision, is the one being read from.
    func reclaimDuplicates(of model: SupportingModel) {
        let files = cachedCopyFiles(of: model)
        guard !files.isEmpty else { return }
        var moved = 0
        for file in files {
            do {
                try FileManager.default.trashItem(at: file, resultingItemURL: nil)
                moved += 1
            } catch {
                failingModels[model.id] = error.localizedDescription
            }
        }
        guard moved > 0 else { return }
        duplicateBytes[model.id] = nil
        removeEmptyDirectories(under: earlierCacheDirectory(of: model))
        statusMessage = "Moved the cached copy of " + model.displayName + " to the Trash."
    }

    /// Removes the folders the move emptied, and keeps any that still hold something.
    private func removeEmptyDirectories(under root: URL?) {
        guard let root, Self.directoryExists(root) else { return }
        guard
            let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isDirectoryKey]
            )
        else { return }
        let directories = enumerator.compactMap { $0 as? URL }.filter(Self.directoryExists)
        for directory in directories.sorted(by: { $0.path.count > $1.path.count }) {
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            guard contents.isEmpty else { continue }
            try? FileManager.default.removeItem(at: directory)
        }
    }

    // MARK: - Installing and updating

    func download(_ model: SupportingModel) {
        guard downloads[model.id] == nil, !state(for: model).isInstalled else { return }
        start(model, revision: model.revision, files: model.files, previousRevision: nil)
    }

    /// Starts a download only when the copy on disk is not usable.
    ///
    /// The silence filter is a dependency of every transcription and 865 KB, so the app fetches it
    /// without asking. Calling this while one is already running, or after it finished, does
    /// nothing.
    func downloadIfNeeded(_ model: SupportingModel) {
        guard !state(for: model).isInstalled else { return }
        download(model)
    }

    func cancel(_ model: SupportingModel) {
        downloads[model.id]?.cancel()
    }

    /// Applies a verified update, keeping the revision it replaces so the change can be undone.
    func applyUpdate(_ model: SupportingModel) {
        guard downloads[model.id] == nil else { return }
        guard case .updateAvailable(let update) = decisions[model.id] else { return }
        guard !isBusy() else {
            failingModels[model.id] = ModelDownloadError.busy.localizedDescription
            return
        }
        let installed = manifest.record(for: model.id)?.revision
        start(
            model,
            revision: update.revision,
            files: update.files,
            previousRevision: installed ?? model.revision
        )
    }

    /// Points the app back at the revision the last update replaced.
    ///
    /// Nothing moves: the earlier revision is still on disk, so going back is one write. Search
    /// treats vectors from another revision as unusable, which is what makes this safe.
    func revert(_ model: SupportingModel) throws {
        guard let record = manifest.record(for: model.id), let previous = record.previousRevision
        else { throw ModelUpdateError.noEarlierCopy }
        let directory = model.directory(in: applicationDirectory, revision: previous)
        guard Self.directoryExists(directory) else { throw ModelUpdateError.noEarlierCopy }
        var updated = manifest
        updated.record(
            InstalledSupportingModel(
                modelID: model.id,
                revision: previous,
                previousRevision: record.revision,
                installedAt: Date(),
                files: record.files
            )
        )
        try updated.write(to: Self.manifestURL(applicationDirectory))
        manifest = updated
        decisions[model.id] = nil
        writeMarker(for: model, revision: previous, files: record.files.map(\.path))
        statusMessage = "Restored the earlier copy of " + model.displayName + "."
    }

    /// Removes every copy this app installed, including the revision kept for a revert.
    func delete(_ model: SupportingModel) throws {
        downloads[model.id]?.cancel()
        let repository = model.repositoryDirectory(in: applicationDirectory)
        if Self.directoryExists(repository) {
            try FileManager.default.removeItem(at: repository)
        }
        let marker = markerURL(for: model)
        if FileManager.default.fileExists(atPath: marker.path) {
            try FileManager.default.removeItem(at: marker)
        }
        var updated = manifest
        updated.remove(model.id)
        try? updated.write(to: Self.manifestURL(applicationDirectory))
        manifest = updated
        decisions[model.id] = nil
        states[model.id] = .notInstalled
        statusMessage = model.displayName + " was removed. The next search downloads it again."
    }

    private func start(
        _ model: SupportingModel,
        revision: String,
        files: [SupportingModelFile],
        previousRevision: String?
    ) {
        states[model.id] = .downloading
        progress[model.id] = 0
        failingModels[model.id] = nil
        downloads[model.id] = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.install(
                    model,
                    revision: revision,
                    files: files,
                    previousRevision: previousRevision
                )
                self.states[model.id] = .installed
                self.decisions[model.id] = .upToDate
                self.progress[model.id] = nil
                self.statusMessage = model.displayName + " is installed and verified."
            } catch is CancellationError {
                self.states[model.id] =
                    self.manifest.record(for: model.id) == nil ? .notInstalled : .installed
                self.progress[model.id] = nil
            } catch {
                self.states[model.id] = .failed(error.localizedDescription)
                self.failingModels[model.id] = error.localizedDescription
                self.progress[model.id] = nil
                self.logger.error(
                    "component download failed for \(model.id, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
            self.downloads[model.id] = nil
        }
    }

    /// Downloads, verifies, and swaps one model.
    ///
    /// Everything is fetched into a staging folder beside the model. Only when every file has
    /// been checked is the folder moved into place, so an interrupted download can never leave a
    /// half-copy where the runtime would read it.
    private func install(
        _ model: SupportingModel,
        revision: String,
        files: [SupportingModelFile],
        previousRevision: String?
    ) async throws {
        let manager = FileManager.default
        let destination = model.directory(in: applicationDirectory, revision: revision)
        let staging = destination
            .deletingLastPathComponent()
            .appending(path: destination.lastPathComponent + ".incoming", directoryHint: .isDirectory)
        try manager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        _ = try? manager.removeItem(at: staging)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)

        let total = files.reduce(Int64(0)) { $0 + $1.bytes }
        var completed = Int64(0)
        do {
            for file in files {
                try Task.checkCancellation()
                let target = staging.appending(path: file.path)
                try manager.createDirectory(
                    at: target.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let downloaded = try await downloadFile(
                    model.downloadURL(for: file.path, revision: revision)
                )
                defer { _ = try? manager.removeItem(at: downloaded) }
                let verified = try await Task.detached {
                    try ModelFileVerifier.verify(
                        fileAt: downloaded,
                        expectedBytes: file.bytes,
                        sha256: file.sha256,
                        blobID: file.blobID
                    )
                }.value
                guard verified else { throw ModelDownloadError.verificationFailed }
                _ = try? manager.removeItem(at: target)
                try manager.moveItem(at: downloaded, to: target)
                completed += file.bytes
                progress[model.id] = total > 0 ? Double(completed) / Double(total) : nil
            }
        } catch {
            _ = try? manager.removeItem(at: staging)
            throw error
        }

        try Task.checkCancellation()
        // A copy already at this revision is replaced with the one just verified. A different
        // revision is a new folder, so the copy being used stays readable until this is recorded.
        if Self.directoryExists(destination) {
            let previous = destination
                .deletingLastPathComponent()
                .appending(
                    path: destination.lastPathComponent + ".previous",
                    directoryHint: .isDirectory
                )
            try ModelFileSwapper.swapIn(
                verified: staging,
                destination: destination,
                previous: previous
            )
        } else {
            try manager.moveItem(at: staging, to: destination)
        }

        let installed = InstalledSupportingModel(
            modelID: model.id,
            revision: revision,
            previousRevision: previousRevision,
            installedAt: Date(),
            files: files.map {
                InstalledSupportingFile(path: $0.path, bytes: $0.bytes, sha256: $0.sha256)
            }
        )
        var updated = manifest
        updated.record(installed)
        try? updated.write(to: Self.manifestURL(applicationDirectory))
        manifest = updated
        writeMarker(for: model, revision: revision, files: files.map(\.path))
        pruneRevisions(of: model, keeping: [revision, previousRevision].compactMap { $0 })
    }

    /// Removes revision folders no longer in use, so an update costs one model, not three.
    private func pruneRevisions(of model: SupportingModel, keeping revisions: [String]) {
        let root = model.repositoryDirectory(in: applicationDirectory)
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        for name in contents where !revisions.contains(name) && !name.hasSuffix(".previous") {
            _ = try? FileManager.default.removeItem(at: root.appending(path: name))
        }
    }

    /// Writes the revision where the runtime that reads this model can find it.
    private func writeMarker(for model: SupportingModel, revision: String, files: [String]) {
        let marker = markerURL(for: model)
        let document: [String: Any] = [
            "model": model.repository,
            "revision": revision,
            "files": files,
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: document,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        try? FileManager.default.createDirectory(
            at: marker.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: marker, options: .atomic)
    }

    private func markerURL(for model: SupportingModel) -> URL {
        applicationDirectory
            .appending(path: model.installPath, directoryHint: .isDirectory)
            .appending(path: SupportingModel.installedMarkerName)
    }

    // MARK: - Checking for updates

    /// Records hashes for a model that was installed before Call Recorder tracked it.
    ///
    /// Without this the first check would report the copy as unverifiable. Hashing 200 MB takes
    /// about a second, so it runs once, off the main thread, and every later check compares two
    /// short strings.
    func bootstrapManifest() async {
        forgetModelsThisBuildDoesNotHave()
        for model in models where state(for: model).isInstalled {
            guard manifest.record(for: model.id) == nil else { continue }
            guard let directory = installedDirectory(for: model) else { continue }
            let revision = directory.lastPathComponent
            var verified: [InstalledSupportingFile] = []
            var complete = true
            for file in model.files {
                let url = directory.appending(path: file.path)
                guard let bytes = Self.fileSize(url) as Int64?, bytes > 0,
                    let digest = try? ModelFileVerifier.sha256(of: url)
                else {
                    complete = false
                    break
                }
                verified.append(
                    InstalledSupportingFile(path: file.path, bytes: bytes, sha256: digest)
                )
            }
            guard complete else { continue }
            logger.notice(
                "recorded \(model.id, privacy: .public) at \(revision, privacy: .public)"
            )
            var updated = manifest
            updated.record(
                InstalledSupportingModel(
                    modelID: model.id,
                    revision: revision,
                    previousRevision: nil,
                    installedAt: Date(),
                    files: verified
                )
            )
            try? updated.write(to: Self.manifestURL(applicationDirectory))
            manifest = updated
            // The runtime that reads this model is handed a folder rather than a revision, so the
            // revision it was just recorded at is written where that runtime looks for it.
            writeMarker(for: model, revision: revision, files: model.files.map(\.path))
            refresh()
        }
    }

    /// Drops the records of models this build no longer downloads.
    ///
    /// The catalog decides what the app fetches, and a record of something that is no longer in it
    /// is a memory of a model the app cannot check, update, or offer again. 0.1.33 removed three:
    /// the whisper models, the speech filter, and the brief model, whose 4.9 GB would otherwise go
    /// on being listed as installed beside a copy nothing reads.
    private func forgetModelsThisBuildDoesNotHave() {
        let known = Set(models.map(\.id))
        let forgotten = manifest.records.keys.filter { !known.contains($0) }.sorted()
        guard !forgotten.isEmpty else { return }
        var updated = manifest
        for id in forgotten {
            updated.remove(id)
        }
        try? updated.write(to: Self.manifestURL(applicationDirectory))
        manifest = updated
        logger.notice(
            "forgot \(forgotten.joined(separator: ", "), privacy: .public): not in this build's catalog"
        )
    }

    func checkForUpdates() async {
        guard !checking else { return }
        checking = true
        defer {
            checking = false
            lastCheckedAt = Date()
        }
        var repositories: [String] = []
        for model in models where !repositories.contains(model.repository) {
            repositories.append(model.repository)
        }
        for repository in repositories {
            do {
                let metadata = try await host.metadata(repository: repository)
                for model in models where model.repository == repository {
                    guard state(for: model).isInstalled else {
                        decisions[model.id] = nil
                        continue
                    }
                    let installed = manifest.record(for: model.id)
                    let blobIDs = await installedBlobIDs(
                        model: model,
                        installed: installed,
                        remote: metadata
                    )
                    decisions[model.id] = SupportingModelChecker.decision(
                        model: model,
                        installed: installed,
                        remote: metadata,
                        installedBlobIDs: blobIDs
                    )
                }
            } catch {
                // A failed check leaves the previous verdict alone. Reporting every model as
                // unverifiable because the network blipped would be worse than saying nothing.
                statusMessage = "Could not reach the model host: " + error.localizedDescription
            }
        }
        measureDuplicates()
    }

    /// The names the installed copies have in the host's repository, for the files the host
    /// publishes without a SHA-256.
    ///
    /// Those are the small files, a config.json or a tokenizer configuration, and a host hashes
    /// them the way Git does instead. Reading them to compute the same hash takes milliseconds, and
    /// without it the update check could only report that it does not know whether the copy on disk
    /// is the published one.
    private func installedBlobIDs(
        model: SupportingModel,
        installed: InstalledSupportingModel?,
        remote: ModelHostMetadata
    ) async -> [String: String] {
        guard let installed, let directory = installedDirectory(for: model) else { return [:] }
        let wanted = model.files.filter { file in
            guard let published = remote.files[file.path] else { return false }
            return published.sha256.isEmpty
                && published.blobID?.isEmpty == false
                && installed.file(file.path) != nil
        }.map(\.path)
        guard !wanted.isEmpty else { return [:] }
        return await Task.detached {
            var ids: [String: String] = [:]
            for path in wanted {
                let url = directory.appending(path: path)
                if let digest = try? ModelFileVerifier.gitBlobSHA1(of: url) {
                    ids[path] = digest
                }
            }
            return ids
        }.value
    }

    /// Checks, then applies everything safe to apply at once.
    func performAutomaticPass() async {
        guard !isBusy() else {
            statusMessage = "Update check skipped while a call is being recorded or transcribed."
            return
        }
        await bootstrapManifest()
        await checkForUpdates()
        let pending = models.filter { decisions[$0.id]?.isUpdateAvailable == true }
        guard !pending.isEmpty else {
            if statusMessage?.hasPrefix("Could not reach") != true {
                statusMessage = "All components are current."
            }
            return
        }
        for model in pending where !isBusy() {
            applyUpdate(model)
            while downloads[model.id] != nil {
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    // MARK: - File work

    private func refresh() {
        for model in models {
            guard let directory = installedDirectory(for: model) else {
                states[model.id] = .notInstalled
                continue
            }
            let present = installedFilePaths(of: model).allSatisfy {
                FileManager.default.fileExists(atPath: directory.appending(path: $0).path)
            }
            states[model.id] = present ? .installed : .notInstalled
        }
        // Reading the file sizes of a stray copy is a filesystem walk, not a request, so the
        // settings window can show what it would reclaim without waiting for a check.
        measureDuplicates()
    }

    private func measureDuplicates() {
        for model in models {
            let files = cachedCopyFiles(of: model)
            guard !files.isEmpty else {
                duplicateBytes[model.id] = nil
                continue
            }
            duplicateBytes[model.id] = files.reduce(Int64(0)) { $0 + Self.fileSize($1) }
        }
    }

    private static func directoryExists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    private static func fileSize(_ url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return exists && !isDirectory.boolValue
    }
}
