import Foundation
import Testing
@testable import CallRecorderApp
@testable import CallRecorderCore

/// Restarting to install a version that is waiting.
///
/// The checker is driven through its own start, which reads the folder a quit would have acted on:
/// a checked copy beside the running bundle is what puts it in the ready state. The two ways out of
/// a restart are what these tests are about, because one of them quits the app and the other must
/// not.
@Suite("App update restart")
@MainActor
struct AppUpdateRestartTests {
    /// How many times the app was asked to quit, kept where a closure can count it.
    @MainActor
    final class QuitCounter {
        private(set) var count = 0
        func record() { count += 1 }
    }

    private struct Fixture {
        let root: URL
        let applicationDirectory: URL
        let bundle: URL
        let stager: AppUpdateStager
        let checker: AppUpdateChecker
        let defaultsSuite: String

        func remove() {
            try? FileManager.default.removeItem(at: root)
            UserDefaults().removePersistentDomain(forName: defaultsSuite)
        }
    }

    /// A running copy and a checked copy waiting beside it, which is the state a restart acts on.
    private func makeFixture(
        quits: QuitCounter,
        fetchReleases: @escaping () async throws -> Data = { throw AppUpdateError.httpStatus(500) }
    ) throws -> Fixture {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appending(path: "app-update-restart-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let applicationDirectory = root.appending(path: "Application Support", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: applicationDirectory, withIntermediateDirectories: true)
        let bundle = root.appending(path: "Call Recorder.app", directoryHint: .isDirectory)
        try makeBundle(at: bundle, version: "0.1.7", build: 97)
        let downloaded = root.appending(path: "Downloaded 0.1.8.app", directoryHint: .isDirectory)
        try makeBundle(at: downloaded, version: "0.1.8", build: 98)

        let stager = AppUpdateStager(
            target: bundle,
            supportDirectory: applicationDirectory.appending(path: "Updates", directoryHint: .isDirectory)
        )
        try fileManager.createDirectory(at: stager.supportDirectory, withIntermediateDirectories: true)
        try fileManager.copyItem(at: downloaded, to: stager.stagedBundle)

        let suite = "app-update-restart-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let checker = AppUpdateChecker(
            bundle: try #require(Bundle(path: bundle.path)),
            applicationDirectory: applicationDirectory,
            defaults: defaults,
            requestTermination: { quits.record() },
            // The check never reaches the network: what is being tested is what a restart does with
            // a version that is already checked, and how a chosen step meets a check in flight.
            fetchReleases: fetchReleases
        )
        return Fixture(
            root: root,
            applicationDirectory: applicationDirectory,
            bundle: bundle,
            stager: stager,
            checker: checker,
            defaultsSuite: suite
        )
    }

    @Test("a restart installs the waiting version by quitting, and opens the app again")
    func restartQuitsAndOpensTheAppAgain() throws {
        // Given a copy waiting beside the running one.
        let quits = QuitCounter()
        let fixture = try makeFixture(quits: quits)
        defer { fixture.remove() }
        var opened: URL?
        fixture.checker.scheduleRelaunch = { bundle, _ in
            opened = bundle
            return true
        }
        fixture.checker.start()
        #expect(fixture.checker.state == .ready(version: "0.1.8"))

        // When the restart is pressed.
        fixture.checker.restartToApplyStaged()

        // Then the app was asked to quit, which is what installs the copy, and the shell that
        // opens it again was pointed at the bundle the swap replaces.
        #expect(quits.count == 1)
        #expect(opened?.path == fixture.bundle.path)
    }

    /// A check that stops until the test lets it answer, so a check can be held in flight.
    @MainActor
    final class PendingFetch {
        private var resume: CheckedContinuation<Void, Never>?
        private(set) var started = false

        func hold() async -> Data {
            started = true
            await withCheckedContinuation { continuation in
                resume = continuation
            }
            return Self.upToDate
        }

        func open() {
            resume?.resume()
            resume = nil
        }

        /// The release list that says this copy is the newest one.
        static let upToDate = Data(
            """
            [
              {
                "tag_name": "v0.1.7",
                "html_url": "https://example.test/releases/tag/v0.1.7",
                "draft": false,
                "prerelease": false,
                "published_at": "2026-09-01T10:00:00Z",
                "assets": []
              }
            ]
            """.utf8
        )
    }

    @Test("a step chosen while a check is running does not cut that check short")
    func aChosenStepLeavesARunningCheckAlone() async throws {
        // Given a check that has started and is waiting for its answer.
        let quits = QuitCounter()
        let pending = PendingFetch()
        let fixture = try makeFixture(quits: quits, fetchReleases: { await pending.hold() })
        defer { fixture.remove() }
        fixture.checker.start()
        fixture.checker.checkNow()
        try await waitUntil("the check to start") { pending.started }

        // When the step changes while that check is in flight.
        fixture.checker.setCheckInterval(AppUpdateInterval.everyThirtyMinutes.seconds)

        // Then the step is taken, and the check that was running finishes on its own: ending its
        // task would report the work it was doing as a failure.
        #expect(fixture.checker.checkInterval == 30 * 60)
        pending.open()
        try await waitUntil("the check to finish") { fixture.checker.state == .upToDate(version: "0.1.7") }
    }

    @Test("a step chosen while the app waits ends the wait that was running")
    func aChosenStepEndsTheWaitThatWasRunning() async throws {
        // Given an app that has settled and is waiting: its first check is twenty seconds away.
        let quits = QuitCounter()
        var checks = 0
        let fixture = try makeFixture(
            quits: quits,
            fetchReleases: {
                checks += 1
                return PendingFetch.upToDate
            }
        )
        defer { fixture.remove() }
        fixture.checker.start()

        // When a shorter step is chosen.
        fixture.checker.setCheckInterval(AppUpdateInterval.everyThirtyMinutes.seconds)

        // Then the check that follows arrives in seconds rather than after the wait that was
        // replaced. The wait is a real one, so this is given room: a busy machine can stretch two
        // seconds, and the wait it replaced was twenty.
        try await waitUntil("a check to follow the change") { checks >= 1 }
    }

    /// Waits for something a test cannot be told about, with a bound so a failure is a failure.
    ///
    /// The bound is there to catch work that never happens, not to measure how fast it happens:
    /// this suite shares one machine with every other test in the run, and the check it waits for
    /// is a task that the main actor has to get to. Ten seconds was read as a latency budget on a
    /// loaded runner and failed a check that did arrive, so the wait is generous. A check that
    /// never starts still fails the run, a minute later.
    private func waitUntil(
        _ what: String,
        seconds: Double = 60,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        Issue.record("waited \(Int(seconds)) seconds for \(what), and it did not happen")
    }

    @Test("a restart that cannot arrange an open leaves the version waiting and does not quit")
    func restartThatCannotOpenDoesNotQuit() throws {
        let quits = QuitCounter()
        let fixture = try makeFixture(quits: quits)
        defer { fixture.remove() }
        fixture.checker.scheduleRelaunch = { _, _ in false }
        fixture.checker.start()
        #expect(fixture.checker.state == .ready(version: "0.1.8"))

        // When the shell cannot be started at all.
        fixture.checker.restartToApplyStaged()

        // Then nothing quits: an app that is gone with nothing to open it again is the one outcome
        // this is not allowed to produce. The checked copy stays where the next quit installs it.
        #expect(quits.count == 0)
        #expect(FileManager.default.fileExists(atPath: fixture.stager.stagedBundle.path))
        guard case .failed(let message) = fixture.checker.state else {
            Issue.record("expected the row to say what happened, and it says \(fixture.checker.state)")
            return
        }
        #expect(message.contains("Quit the app"))
    }

    /// A few kilobytes that describe themselves the way a real bundle does, signed ad-hoc.
    private func makeBundle(at url: URL, version: String, build: Int) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: url.appending(path: "Contents/MacOS"),
            withIntermediateDirectories: true
        )
        let plist: [String: Any] = [
            "CFBundleIdentifier": "local.callrecorder.app",
            "CFBundleShortVersionString": version,
            "CFBundleVersion": String(build),
            "CFBundleExecutable": "Fake",
            "CFBundlePackageType": "APPL",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: url.appending(path: "Contents/Info.plist"))
        try fileManager.copyItem(
            at: URL(filePath: "/usr/bin/true"),
            to: url.appending(path: "Contents/MacOS/Fake")
        )
        let signed = try ProcessRunner.run(
            executable: AppBundleInstaller.codesign,
            arguments: ["--force", "--sign", "-", url.path]
        )
        #expect(signed.exitCode == 0, "\(signed.standardError)")
    }
}
