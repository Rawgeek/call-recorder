import CallRecorderCore
import Foundation
import Observation
import OSLog

enum AppUpdateError: LocalizedError, Equatable {
    case notAnApplication
    case noArchiveForThisVersion(String)
    case httpStatus(Int)
    case digestMismatch(expected: String, found: String)
    case notWritable(String)
    case cannotRelaunch

    var errorDescription: String? {
        switch self {
        case .notAnApplication:
            "This copy of Call Recorder is not an application bundle, so it cannot replace itself."
        case .noArchiveForThisVersion(let version):
            "Release \(version) carries no archive for this Mac."
        case .httpStatus(let code):
            "The download failed with HTTP \(code)."
        case .digestMismatch(let expected, let found):
            "The downloaded update does not match the digest the release published. Expected "
                + "\(expected.prefix(12))… and got \(found.prefix(12))…."
        case .notWritable(let path):
            "Call Recorder cannot replace itself in \(path). Move the app to Applications and try again."
        case .cannotRelaunch:
            "Call Recorder could not arrange to open again, so the waiting version was left in "
                + "place. Quit the app to install it."
        }
    }
}

/// Keeps this copy of Call Recorder current with the releases of its repository.
///
/// The check runs at launch and every few hours after that. A newer release is downloaded, its
/// digest is compared with the one the release published, and the app inside it is unpacked beside
/// this copy and checked: same identifier, same version, valid signature, same signer. Only then
/// does it wait. The swap itself happens when the app quits, which is the one moment nothing is
/// using the bundle, and the next launch is the new version. The version that was working is kept,
/// so a release that turns out badly can be put back.
@MainActor
@Observable
final class AppUpdateChecker {
    enum State: Equatable {
        case idle
        case checking
        case upToDate(version: String)
        /// A newer release is known, and nothing has been fetched for it yet.
        case available(version: String)
        case downloading(version: String)
        /// Fetched, checked, and waiting for the app to quit.
        case ready(version: String)
        case failed(message: String)
        /// The app cannot replace itself here, so the release page is the way.
        case installByHand(version: String, page: URL)

        var isBusy: Bool {
            switch self {
            case .checking, .downloading: true
            default: false
            }
        }
    }

    /// The repository whose releases this build follows.
    static let repository = "Rawgeek/call-recorder"

    private(set) var state: State = .idle
    /// 0 to 1 while an archive is arriving, or nil when its size is not known yet.
    private(set) var progress: Double?
    private(set) var lastCheckedAt: Date?
    /// The version this copy is running.
    let installedVersion: String
    let installedBuild: Int
    /// The version the app installed by itself at the last quit, when it has done that.
    private(set) var appliedVersion: String?
    /// A version the user went back from. It is offered but never installed by itself again.
    private(set) var heldBackVersion: String?
    /// The release the last check offered, so a button can act on it without checking again.
    private(set) var offeredRelease: AppRelease?

    /// Whether the automatic pass installs what it finds. The app sets this from its settings.
    var automaticUpdatesEnabled: () -> Bool = { true }
    /// How long the automatic pass waits between checks while the app stays open.
    ///
    /// Read at the top of every wait, and written only through `setCheckInterval`, which also ends
    /// the wait that is already running: a person who asks for a check every half hour means the
    /// next one, not the one after the twelve hours the app was told to wait before.
    private(set) var checkInterval: TimeInterval = AppUpdateInterval.default.seconds
    /// How the app is quit when an update is installed early. The model sets this: quitting is the
    /// app's own business, and the updater has no other reason to know how it is done.
    var requestTermination: () -> Void = {}
    /// Opens the app again once this process has gone. `AppRelaunch.schedule` is the real one; a
    /// test supplies its own so a restart can be watched without opening anything.
    var scheduleRelaunch: (_ bundle: URL, _ log: URL) -> Bool = { bundle, log in
        AppRelaunch.schedule(bundle: bundle, log: log)
    }

    private let bundle: Bundle
    private let stager: AppUpdateStager?
    private let defaults: UserDefaults
    private let logURL: URL
    private let fetchReleases: () async throws -> Data
    private let logger = Logger(subsystem: "local.callrecorder.app", category: "updates")
    private var checking = false
    private var work: Task<Void, Never>?
    private var schedule: Task<Void, Never>?

    private static let appliedVersionKey = "app-update.applied-version"
    private static let appliedAtKey = "app-update.applied-at"
    private static let heldBackVersionKey = "app-update.held-back-version"
    private static let stagedIntentKey = "app-update.staged-intent"
    private static let lastCheckedKey = "app-update.last-checked"

    init(
        bundle: Bundle = .main,
        applicationDirectory: URL,
        defaults: UserDefaults = .standard,
        // How the app is quit, given rather than assumed: the updater runs inside an app whose
        // lifecycle it has no other reason to know about, and a restart that could not quit would
        // be a row that did nothing.
        requestTermination: @escaping () -> Void,
        fetchReleases: (() async throws -> Data)? = nil
    ) {
        self.requestTermination = requestTermination
        self.bundle = bundle
        self.defaults = defaults
        installedVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0"
        installedBuild = (bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? NSNumber)?.intValue
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String).flatMap(Int.init)
            ?? 0
        let updates = applicationDirectory.appending(path: "Updates", directoryHint: .isDirectory)
        stager = bundle.bundleURL.pathExtension == "app"
            ? AppUpdateStager(target: bundle.bundleURL, supportDirectory: updates)
            : nil
        logURL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Logs/CallRecorder/app-update.log")
        appliedVersion = defaults.string(forKey: Self.appliedVersionKey)
        heldBackVersion = defaults.string(forKey: Self.heldBackVersionKey)
        lastCheckedAt = defaults.object(forKey: Self.lastCheckedKey) as? Date
        let repository = Self.repository
        self.fetchReleases = fetchReleases ?? {
            var request = URLRequest(url: AppReleaseCatalog.url(repository: repository))
            request.setValue("CallRecorder", forHTTPHeaderField: "User-Agent")
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw AppUpdateError.httpStatus(http.statusCode)
            }
            return data
        }
    }

    /// The version waiting to be installed, when one is.
    var pendingVersion: String? {
        if case .ready(let version) = state { return version }
        return nil
    }

    /// The version kept from before the last automatic update, when there is one to go back to.
    var keptVersion: String? { stager?.backupVersion() }

    /// Whether the waiting copy is an older version being put back rather than a newer one.
    var isRestoringOlderVersion: Bool {
        guard case .ready(let version) = state else { return false }
        return !AppVersionOrder.isNewer(version, than: installedVersion)
    }

    /// Fetches the release the last check offered, because the user asked for it now.
    func prepareOfferedUpdate() {
        guard let offeredRelease else { return }
        Task { await fetchAndStage(offeredRelease) }
    }

    /// Shows the row as it looks with a checked copy waiting, for a rendered picture.
    ///
    /// The real state is reached by downloading a release, which a render cannot do: preview mode
    /// stops before the updater starts. Without this the one state that carries the button to
    /// install a waiting version would be the one state no picture can show. Only a render asks
    /// for it.
    func enterPreviewStaged(_ version: String) {
        state = .ready(version: version)
    }

    /// Puts back the state the render borrowed.
    func leavePreviewStaged() {
        state = .idle
    }

    // MARK: - Lifecycle

    /// Starts the automatic pass: one check after the app has settled, then one every few hours.
    func start() {
        guard let stager, schedule == nil else { return }
        // A swap that died between its two renames is repaired before anything else looks at the
        // folder, and nothing left behind by an earlier run is trusted.
        recoverInterruptedSwap(around: stager.target)
        refreshStaged()
        log("checking starts in 20 seconds; running \(installedVersion) (\(installedBuild))")
        beginSchedule(after: .seconds(20))
    }

    /// Takes the step the user chose.
    ///
    /// The wait that is already running was set for the old step, so it ends here and a new one
    /// starts: someone who moves the choice from a day to half an hour is asking for a check soon,
    /// not for one after the day they just walked away from. The check that follows runs two
    /// seconds after the change, and it is a single request, so the choice confirms itself.
    func setCheckInterval(_ seconds: TimeInterval) {
        guard seconds != checkInterval else { return }
        checkInterval = seconds
        // A check or a download that is already under way is left alone: ending that task would
        // report the work it was doing as a failure. The wait that follows it reads the new step,
        // which is the wait this is about.
        guard schedule != nil, !checking, work == nil else { return }
        log("a check now follows every \(Int(seconds / 60)) minutes")
        beginSchedule(after: .seconds(2))
    }

    /// The one loop that checks and waits, so nothing else has to know how the wait is spelled.
    private func beginSchedule(after delay: Duration) {
        schedule?.cancel()
        schedule = Task { [weak self] in
            try? await Task.sleep(for: delay)
            while !Task.isCancelled {
                await self?.check()
                let interval = self?.checkInterval ?? AppUpdateInterval.default.seconds
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    /// Runs a check because someone pressed the button.
    func checkNow() {
        Task { await check(manual: true) }
    }

    func cancel() {
        work?.cancel()
    }

    // MARK: - Checking

    private func check(manual: Bool = false) async {
        guard stager != nil, !checking else { return }
        checking = true
        defer { checking = false }
        if manual { state = .checking }
        log("checking \(Self.repository) for releases")
        do {
            let data = try await fetchReleases()
            let releases = try AppReleaseCatalog.parse(data)
            let decision = AppReleaseCatalog.decision(
                releases: releases,
                currentVersion: installedVersion
            )
            lastCheckedAt = Date()
            defaults.set(lastCheckedAt, forKey: Self.lastCheckedKey)
            switch decision {
            case .upToDate(let version):
                offeredRelease = nil
                state = .upToDate(version: version)
                log("up to date at \(version)")
            case .cannotVerify(let reason):
                state = .failed(message: reason)
                log("no verdict: \(reason)")
            case .update(let release):
                offeredRelease = release
                log("release \(release.version) is available")
                guard release.version != heldBackVersion else {
                    state = .available(version: release.version)
                    log("holding back \(release.version) after a rollback")
                    return
                }
                // A release that is already waiting is not fetched again. The check repeats every
                // few hours, and without this the copy that is waiting would be downloaded,
                // unpacked, and checked over again at every one of them, while the row that offers
                // to install it now would read as a download in progress instead.
                guard pendingVersion != release.version else {
                    log("release \(release.version) is already waiting to be installed")
                    return
                }
                if automaticUpdatesEnabled() {
                    await fetchAndStage(release)
                } else {
                    state = .available(version: release.version)
                }
            }
        } catch {
            state = .failed(message: error.localizedDescription)
            log("check failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Downloading and staging

    /// Fetches the release and leaves it waiting for the next quit.
    func fetchAndStage(_ release: AppRelease) async {
        guard work == nil else { return }
        guard let asset = release.asset else {
            state = .failed(message: AppUpdateError.noArchiveForThisVersion(release.version).localizedDescription)
            return
        }
        guard let stager else { return }
        if !FileManager.default.isWritableFile(atPath: stager.target.deletingLastPathComponent().path) {
            state = .installByHand(version: release.version, page: release.pageURL)
            log("cannot write beside \(stager.target.path); the release page is the way")
            return
        }
        state = .downloading(version: release.version)
        progress = 0
        work = Task { [weak self] in
            guard let self else { return }
            do {
                let archive = try await self.download(asset: asset, release: release)
                try await self.stageArchive(archive, release: release)
                self.progress = nil
                self.state = .ready(version: release.version)
                self.defaults.set("update", forKey: Self.stagedIntentKey)
                self.log("release \(release.version) is ready; it installs when the app quits")
            } catch is CancellationError {
                self.progress = nil
                self.state = .available(version: release.version)
            } catch {
                self.progress = nil
                self.state = .failed(message: error.localizedDescription)
                self.log("release \(release.version) could not be prepared: \(error.localizedDescription)")
            }
            self.work = nil
        }
    }

    /// Puts the kept copy back in the waiting place, at the user's request.
    func rollBackToKeptVersion() {
        guard let stager, !state.isBusy else { return }
        do {
            let version = try stager.stageRollback(
                expectingIdentifier: bundle.bundleIdentifier ?? "local.callrecorder.app",
                signer: AppBundleInstaller.signerAuthority(of: bundle.bundleURL)
            )
            heldBackVersion = installedVersion
            defaults.set(installedVersion, forKey: Self.heldBackVersionKey)
            defaults.set("rollback", forKey: Self.stagedIntentKey)
            state = .ready(version: version)
            log("kept version \(version) is staged; \(installedVersion) is held back")
        } catch {
            state = .failed(message: error.localizedDescription)
            log("the kept version could not be staged: \(error.localizedDescription)")
        }
    }

    /// Swaps in what is waiting. Called as the app terminates.
    func applyStagedOnExit() {
        guard let stager, case .ready(let version) = state else { return }
        do {
            let installed = try stager.applyStaged()
            defaults.set(installed, forKey: Self.appliedVersionKey)
            defaults.set(Date(), forKey: Self.appliedAtKey)
            defaults.set(nil, forKey: Self.stagedIntentKey)
            log(
                "installed \(installed) while quitting; the copy that was running is kept at "
                    + stager.backupBundle.path
            )
        } catch {
            log("the waiting update could not be installed: \(error.localizedDescription)")
        }
    }

    /// Installs the copy that is waiting now, and opens the app again.
    ///
    /// The swap belongs to the quit, so the open is arranged first and the quit comes second:
    /// a shell waits for this process to go away and then opens the app, which is the copy that
    /// was swapped in. When that shell cannot be started, the waiting version is left alone. A
    /// quit with nothing after it would leave the user with no app running, and the quit is the
    /// one thing here that cannot be taken back.
    func restartToApplyStaged() {
        guard stager != nil, case .ready(let version) = state else { return }
        guard scheduleRelaunch(bundle.bundleURL, logURL) else {
            state = .failed(message: AppUpdateError.cannotRelaunch.localizedDescription)
            log("the app could not be opened again, so \(version) is left waiting for a quit")
            return
        }
        log("installing \(version) now and opening the app again when this process ends")
        requestTermination()
    }

    // MARK: - Files

    private func download(asset: AppReleaseAsset, release: AppRelease) async throws -> URL {
        guard let stager else { throw AppUpdateError.notAnApplication }
        let destination = stager.archive(version: release.version)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: destination)
        var request = URLRequest(url: asset.downloadURL)
        request.setValue("CallRecorder", forHTTPHeaderField: "User-Agent")
        let download = ModelFileDownload(destination: destination) { [weak self] received, expected in
            Task { @MainActor [weak self] in
                self?.progress = DownloadByteCount(received: received, expected: expected).fraction
            }
        }
        let response = try await download.run(request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: destination)
            throw AppUpdateError.httpStatus(http.statusCode)
        }
        // The digest is the host's own promise about the file. A download that does not keep it is
        // thrown away, exactly as a model that fails its hash is.
        if let expected = asset.sha256 {
            let actual = try? ModelFileVerifier.sha256(of: destination)
            guard actual == expected else {
                try? FileManager.default.removeItem(at: destination)
                throw AppUpdateError.digestMismatch(expected: expected, found: actual ?? "nothing")
            }
        }
        return destination
    }

    private func stageArchive(_ archive: URL, release: AppRelease) async throws {
        guard let stager else { throw AppUpdateError.notAnApplication }
        let identifier = bundle.bundleIdentifier ?? "local.callrecorder.app"
        let signer = AppBundleInstaller.signerAuthority(of: bundle.bundleURL)
        try await Task.detached {
            try stager.stage(
                archive: archive,
                version: release.version,
                expectingIdentifier: identifier,
                signer: signer
            )
        }.value
    }

    /// Reads what the last run left waiting, and keeps only something worth installing.
    private func refreshStaged() {
        guard let stager else { return }
        let intent = defaults.string(forKey: Self.stagedIntentKey) ?? "update"
        guard let staged = stager.stagedVersion() else {
            if stager.backupVersion() == nil {
                defaults.set(nil, forKey: Self.stagedIntentKey)
            }
            return
        }
        let relevant = intent == "rollback"
            ? staged != installedVersion
            : AppVersionOrder.isNewer(staged, than: installedVersion)
        // A version the user went back from is never staged by itself again, and the copy a
        // completed swap left behind is that same version.
        guard relevant, staged != heldBackVersion else {
            stager.discardStaged()
            defaults.set(nil, forKey: Self.stagedIntentKey)
            return
        }
        do {
            try AppBundleInstaller.verify(
                stager.stagedBundle,
                expectingIdentifier: bundle.bundleIdentifier ?? "local.callrecorder.app",
                version: staged,
                signer: AppBundleInstaller.signerAuthority(of: bundle.bundleURL)
            )
            state = .ready(version: staged)
            log("a checked copy of \(staged) was left waiting by an earlier run")
        } catch {
            stager.discardStaged()
            defaults.set(nil, forKey: Self.stagedIntentKey)
            log("a waiting copy of \(staged) did not verify and was removed")
        }
    }

    /// Repairs the two-rename fallback if the app died in the middle of one.
    private func recoverInterruptedSwap(around target: URL) {
        let fileManager = FileManager.default
        let parent = target.deletingLastPathComponent()
        let prefix = ".\(target.lastPathComponent).previous-"
        let strays = (try? fileManager.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil))?
            .filter { $0.lastPathComponent.hasPrefix(prefix) } ?? []
        for stray in strays {
            if fileManager.fileExists(atPath: target.path) {
                // The swap finished; the aside is the copy that was replaced.
                try? fileManager.removeItem(at: stray)
            } else {
                try? fileManager.moveItem(at: stray, to: target)
                log("put back \(target.lastPathComponent) after an interrupted update")
            }
        }
    }

    private func log(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = Data("\(stamp) app update: \(message)\n".utf8)
        let fileManager = FileManager.default
        try? fileManager.createDirectory(
            at: logURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: logURL)
        }
    }
}
