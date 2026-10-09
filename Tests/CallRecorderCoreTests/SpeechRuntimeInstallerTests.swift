import Foundation
import Testing
@testable import CallRecorderApp

/// The lines a stub run reported, readable after the run has finished.
private final class ReportedLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        lines.append(line)
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }
}

/// The install the Models row runs, against environments with and without a pip.
///
/// An environment made by uv holds the interpreter and the packages but no pip, and every install
/// there answered "No module named pip" — a broken-looking failure of an environment that was one
/// command from working (measured on this Mac on 2026-10-08). The stub interpreters below are real
/// processes, so the sequence the installer runs is the sequence that is checked.
@Suite("Speech runtime installer")
struct SpeechRuntimeInstallerTests {
    /// A stand-in interpreter: answers the pip question, makes a pip when asked, and writes down
    /// every call it was given.
    private func stubPython(
        in directory: URL,
        pipInitially: Bool,
        ensurepipWorks: Bool = true
    ) throws -> (python: URL, log: URL) {
        let python = directory.appending(path: "python")
        let log = directory.appending(path: "calls.txt")
        let marker = directory.appending(path: "pip-exists")
        if pipInitially { try Data().write(to: marker) }
        let ensurepipLines = ensurepipWorks
            ? "touch \"\(marker.path)\"\nexit 0"
            : "echo \"ensurepip is not available\" >&2\nexit 1"
        let script = """
        #!/bin/sh
        echo "$@" >> "\(log.path)"
        if [ "$1" = "-m" ] && [ "$2" = "pip" ]; then
          if [ -f "\(marker.path)" ]; then
            echo "pip 25.0.1"
            exit 0
          fi
          echo "No module named pip" >&2
          exit 1
        fi
        if [ "$1" = "-m" ] && [ "$2" = "ensurepip" ]; then
          \(ensurepipLines)
        fi
        exit 0
        """
        try script.write(to: python, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: python.path
        )
        return (python, log)
    }

    private func scratch() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "speech-installer-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test("an environment with a pip installs without being changed")
    func aWorkingPipIsLeftAlone() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (python, log) = try stubPython(in: directory, pipInitially: true)

        let outcome = SpeechRuntimeInstaller.run(python: python) { _ in }

        guard case .success = outcome else {
            Issue.record("expected the install to succeed, got \(outcome)")
            return
        }
        let calls = try String(contentsOf: log, encoding: .utf8)
        #expect(!calls.contains("ensurepip"))
        #expect(calls.contains("-m pip install --upgrade mlx==0.32.2 mlx-audio==0.5.6"))
    }

    @Test("an environment made without pip is given one, then installed into")
    func aMissingPipIsBootstrapped() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (python, log) = try stubPython(in: directory, pipInitially: false)

        let outcome = SpeechRuntimeInstaller.run(python: python) { _ in }

        guard case .success = outcome else {
            Issue.record("expected the install to succeed, got \(outcome)")
            return
        }
        let calls = try String(contentsOf: log, encoding: .utf8)
        let lines = calls.split(separator: "\n").map(String.init)
        // The bootstrap comes before the install, and the install is the same one every other
        // environment gets.
        let bootstrapIndex = try #require(lines.firstIndex(of: "-m ensurepip --upgrade"))
        let installIndex = try #require(
            lines.firstIndex(of: "-m pip install --upgrade mlx==0.32.2 mlx-audio==0.5.6")
        )
        #expect(bootstrapIndex < installIndex)
    }

    @Test("an environment that can make no pip reports why rather than pretending")
    func aFailedBootstrapNamesTheFault() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (python, log) = try stubPython(
            in: directory,
            pipInitially: false,
            ensurepipWorks: false
        )
        let said = ReportedLines()

        let outcome = SpeechRuntimeInstaller.run(python: python) { said.append($0) }

        guard case .failure(let message) = outcome else {
            Issue.record("expected a failure, got \(outcome)")
            return
        }
        #expect(message.contains("ensurepip is not available"))
        // Nothing was asked of a pip that is not there.
        let calls = try String(contentsOf: log, encoding: .utf8)
        #expect(!calls.contains("pip install"))
        #expect(said.all.contains { $0.contains("no pip") })
    }

    @Test("the pip question is answered by the environment itself")
    func thePipQuestionIsReal() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let other = directory.appending(path: "other", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let (withPip, _) = try stubPython(in: directory, pipInitially: true)
        let (withoutPip, _) = try stubPython(in: other, pipInitially: false)

        #expect(SpeechRuntimeInstaller.hasPip(python: withPip))
        #expect(!SpeechRuntimeInstaller.hasPip(python: withoutPip))
    }
}
