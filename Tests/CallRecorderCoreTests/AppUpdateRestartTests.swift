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
    private func makeFixture(quits: QuitCounter) throws -> Fixture {
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
            // The check never reaches the network in these tests: what is being tested is what a
            // restart does with a version that is already checked.
            fetchReleases: { throw AppUpdateError.httpStatus(500) }
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
