import Darwin
import Foundation

public struct ToolLocator: Sendable {
    public let searchDirectories: [URL]

    public init(searchDirectories: [URL]) {
        self.searchDirectories = searchDirectories
    }

    public static var standard: ToolLocator {
        var directories = [URL(filePath: "/opt/homebrew/bin"), URL(filePath: "/usr/local/bin")]
        directories.append(
            FileManager.default.homeDirectoryForCurrentUser
                .appending(path: ".bun/bin", directoryHint: .isDirectory)
        )
        if let resources = Bundle.main.resourceURL {
            directories.insert(resources.appending(path: "bin", directoryHint: .isDirectory), at: 0)
        }
        return ToolLocator(searchDirectories: directories)
    }

    public func locate(_ name: String) -> URL? {
        guard !name.isEmpty, URL(filePath: name).lastPathComponent == name else { return nil }
        return searchDirectories
            .map { $0.appending(path: name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}

public struct ProcessResult: Equatable, Sendable {
    public let exitCode: Int32
    public let standardOutput: String
    public let standardError: String
}

public struct ProcessRunnerError: LocalizedError, Equatable, Sendable {
    public let exitCode: Int32
    public let standardError: String

    public var errorDescription: String? {
        let message = standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "Process exited with code \(exitCode)." : message
    }
}

public enum ProcessRunner {
    public static func run(
        executable: URL,
        arguments: [String],
        cancellation: ProcessCancellation? = nil
    ) throws -> ProcessResult {
        let temporaryDirectory = FileManager.default.temporaryDirectory
        let outputURL = temporaryDirectory.appending(path: "call-recorder-\(UUID().uuidString).stdout")
        let errorURL = temporaryDirectory.appending(path: "call-recorder-\(UUID().uuidString).stderr")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        defer {
            try? FileManager.default.removeItem(at: outputURL)
            try? FileManager.default.removeItem(at: errorURL)
        }

        let output = try FileHandle(forWritingTo: outputURL)
        let error = try FileHandle(forWritingTo: errorURL)
        defer {
            try? output.close()
            try? error.close()
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = error
        try process.run()
        // A command that has to be stoppable cannot be waited on with waitUntilExit: that call
        // returns when the process ends and there is nothing left to ask. The flag is polled
        // instead, and the process is ended the moment it is set.
        if let cancellation {
            while process.isRunning, !cancellation.isCancelled {
                Thread.sleep(forTimeInterval: 0.1)
            }
            if cancellation.isCancelled {
                end(process)
            } else {
                process.waitUntilExit()
            }
        } else {
            process.waitUntilExit()
        }
        try output.synchronize()
        try error.synchronize()
        // A stopped command is not a failed one. Its exit status is an artefact of the signal, so
        // the caller is told the run was cancelled and never sees a code that reads like a fault.
        if cancellation?.isCancelled == true { throw CancellationError() }
        return ProcessResult(
            exitCode: process.terminationStatus,
            standardOutput: String(decoding: try Data(contentsOf: outputURL), as: UTF8.self),
            standardError: String(decoding: try Data(contentsOf: errorURL), as: UTF8.self)
        )
    }

    public static func runChecked(
        executable: URL,
        arguments: [String],
        cancellation: ProcessCancellation? = nil
    ) throws -> ProcessResult {
        let result = try run(executable: executable, arguments: arguments, cancellation: cancellation)
        guard result.exitCode == 0 else {
            throw ProcessRunnerError(exitCode: result.exitCode, standardError: result.standardError)
        }
        return result
    }

    /// Ends a process that has to stop, and gives it a moment to end on its own.
    ///
    /// SIGTERM first: ffmpeg, the reader script, and the speaker script all end on it. A command that
    /// ignores it is killed, because the point of the stop is that nothing is left running behind
    /// the surface the user pressed.
    public static func end(_ process: Process) {
        process.terminate()
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
    }
}

/// A one-shot flag a running command polls, so a surface can stop work that must not continue.
///
/// Transcribing a long call and analysing a room of voices are external processes, and the app
/// could not end one: a run that stopped making progress had to be killed from outside the app,
/// and the call stayed claimed by a stage that would never finish. The flag is written from the
/// interface and read on the threads that wait for those processes, which is why it carries a
/// lock instead of living in an actor.
public final class ProcessCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    /// Stops the caller by throwing when the work has been cancelled.
    public func checkCancelled() throws {
        if isCancelled { throw CancellationError() }
    }
}
