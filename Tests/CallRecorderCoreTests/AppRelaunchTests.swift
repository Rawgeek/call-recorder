import Foundation
import Testing
@testable import CallRecorderCore

/// The waiting shell is the whole mechanism, so the checks are on the shell: what it waits for, how
/// it is handed the path it opens, and what it leaves behind when the open fails.
@Suite("App relaunch")
struct AppRelaunchTests {
    @Test("the waiter watches this process and is handed the path to open")
    func waiterWatchesTheProcessAndReadsThePathFromTheEnvironment() {
        let script = AppRelaunch.script(processID: 4242)

        // The wait is on the process, not on a length of time: the swap runs while the app quits,
        // so a process that is gone is a bundle that has already been replaced.
        #expect(script.hasPrefix("while "))
        #expect(script.contains("/bin/kill -0 4242"))
        #expect(script.contains("/usr/bin/open"))
        // The path arrives in the environment, so a folder named with a space, a quote, or a `$`
        // cannot break the command that opens it. Nothing of this Mac's own layout is in the text.
        #expect(script.contains("$" + AppRelaunch.applicationPathVariable))
        #expect(!script.contains("/Applications"))
        // A relaunch that failed writes where the app's other update trouble is already read.
        #expect(script.contains("$" + AppRelaunch.logPathVariable))
    }

    @Test("the waiter is a script the shell accepts")
    func waiterIsAValidShellScript() throws {
        // `-n` reads the script and runs none of it, which is the point: the check is the syntax.
        let result = try ProcessRunner.run(
            executable: URL(filePath: "/bin/sh"),
            arguments: ["-n", "-c", AppRelaunch.script(processID: 1234)]
        )
        #expect(result.exitCode == 0, "\(result.standardError)")
    }

    @Test("a waiter whose open fails leaves the reason in the log")
    func waiterLogsAnOpenThatFailed() async throws {
        // Given a directory holding nothing that can be opened, and a process number no process
        // can hold, so the wait ends at once rather than waiting for this test to end.
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "app-relaunch-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appending(path: "app-update.log")
        let missing = directory.appending(path: "Nothing Here.app", directoryHint: .isDirectory)

        // When
        let started = AppRelaunch.schedule(bundle: missing, log: log, processID: 4_000_000)

        // Then the shell runs, and the line it leaves is the one the app could not write itself:
        // by the time the open is attempted, the app is gone.
        #expect(started)
        let written = try await waitForText(at: log)
        #expect(written.contains("did not open again"))
    }

    /// Waits for the shell to write, because the shell outlives the call that started it.
    private func waitForText(at url: URL, seconds: Double = 30) async throws -> String {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty {
                return text
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        Issue.record("the waiting shell wrote nothing to \(url.lastPathComponent)")
        return ""
    }
}
