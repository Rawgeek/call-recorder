import Foundation
import Testing
@testable import CallRecorderCore

struct ToolLocatorTests {
    @Test func searchesOnlyConfiguredDirectoriesInOrder() {
        // Given
        let locator = ToolLocator(searchDirectories: [URL(filePath: "/usr/bin")])

        // When / Then
        #expect(locator.locate("true") == URL(filePath: "/usr/bin/true"))
        #expect(locator.locate("definitely-not-a-tool") == nil)
    }

    @Test func processRunnerPassesHostileTextAsOneLiteralArgument() throws {
        // Given
        let value = "Alice; $(not-executed) `still-literal`"

        // When
        let result = try ProcessRunner.run(
            executable: URL(filePath: "/usr/bin/printf"),
            arguments: ["%s", value]
        )

        // Then
        #expect(result.exitCode == 0)
        #expect(result.standardOutput == value)
    }

    @Test func checkedProcessReportsARealNonzeroExit() throws {
        // Given
        let executable = URL(filePath: "/usr/bin/false")

        // When / Then
        do {
            _ = try ProcessRunner.runChecked(executable: executable, arguments: [])
            Issue.record("Expected a nonzero process failure")
        } catch let error as ProcessRunnerError {
            #expect(error.exitCode == 1)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func aStoppedCommandEndsEarlyAndReportsCancellation() async throws {
        // Given a command that would run far past the test
        let cancellation = ProcessCancellation()
        let started = Date()

        // When it is stopped while it is still running
        let run = Task.detached {
            try ProcessRunner.run(
                executable: URL(filePath: "/bin/sleep"),
                arguments: ["30"],
                cancellation: cancellation
            )
        }
        try await Task.sleep(for: .milliseconds(300))
        cancellation.cancel()
        let outcome = await run.result

        // Then the call ends well before the command's own end, and it is told the run was
        // cancelled rather than failed: a stopped process exits on a signal, and its status
        // would otherwise read as a fault.
        #expect(throws: CancellationError.self) { try outcome.get() }
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test func aRunThatNobodyStopsReturnsItsOutput() throws {
        // Given a flag that nobody sets, so the poll loop has to let the command finish
        let cancellation = ProcessCancellation()

        // When
        let result = try ProcessRunner.runChecked(
            executable: URL(filePath: "/bin/echo"),
            arguments: ["still here"],
            cancellation: cancellation
        )

        // Then
        #expect(result.standardOutput == "still here\n")
        #expect(!cancellation.isCancelled)
    }
}
