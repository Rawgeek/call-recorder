import CryptoKit
import Foundation
import Testing
@testable import CallRecorderCore

/// The app ships its JavaScript runtime as one archive, and a script inside the bundle unpacks it.
///
/// That script is the path Call Recorder and Codex both start, so three things about it are worth
/// a test: it checks the archive before unpacking it, it unpacks once rather than once per start,
/// and a path it cannot create is reported instead of being mistaken for another process at work.
/// Each test builds a runtime of its own, so nothing here touches the runtime this Mac uses.
struct IndexerRuntimeShimTests {
    @Test func theFirstCallUnpacksTheArchiveAndForwardsEveryArgument() throws {
        // Given
        let fixture = try ShimFixture()
        defer { fixture.cleanUp() }

        // When
        let result = try fixture.run(arguments: ["indexer.js", "index", "--database", "/tmp/db"])

        // Then the entry point inside the unpacked runtime ran, with the arguments it was given.
        #expect(result.exitCode == 0)
        let entry = fixture.state.appending(path: "indexer.js").path
        #expect(result.standardOutput.contains("ARG " + entry))
        #expect(result.standardOutput.contains("ARG index"))
        #expect(result.standardOutput.contains("ARG --database"))
        #expect(result.standardOutput.contains("ARG /tmp/db"))
        #expect(
            FileManager.default.fileExists(atPath: fixture.state.appending(path: ".ready").path)
        )
    }

    @Test func theSecondCallReusesTheRuntimeItAlreadyUnpacked() throws {
        // Given a runtime that was already unpacked once.
        let fixture = try ShimFixture()
        defer { fixture.cleanUp() }
        _ = try fixture.run(arguments: ["indexer.js"])
        let marker = fixture.state.appending(path: "unpacked-once")
        try Data("kept".utf8).write(to: marker)

        // When the script is started again.
        let result = try fixture.run(arguments: ["mcp-server.js", "--tool", "list_calls"])

        // Then it used the copy that was already there: unpacking again would have replaced the
        // folder this file is in.
        #expect(result.exitCode == 0)
        #expect(FileManager.default.fileExists(atPath: marker.path))
        #expect(result.standardOutput.contains(fixture.state.appending(path: "mcp-server.js").path))
    }

    @Test func anArchiveThatDoesNotMatchItsRecordedHashIsRefused() throws {
        // Given an archive that was replaced after its hash was recorded.
        let fixture = try ShimFixture()
        defer { fixture.cleanUp() }
        try Data("not an archive".utf8).write(to: fixture.bundle.appending(path: "runtime.zip"))

        // When
        let result = try fixture.run(arguments: ["indexer.js"], tolerateFailure: true)

        // Then nothing was unpacked, and the reason names the check that failed.
        #expect(result.exitCode != 0)
        #expect(result.standardError.contains("does not match the hash recorded when the app"))
        #expect(!FileManager.default.fileExists(atPath: fixture.state.appending(path: "bun").path))
    }

    @Test func theRuntimeIsFetchedWhenTheAppDoesNotCarryOne() throws {
        // Given a bundle that carries the hash and where to fetch from, but no archive. That is
        // how the app ships now: the archive is 36 MB and most of what the app used to weigh.
        let fixture = try ShimFixture()
        defer { fixture.cleanUp() }
        _ = try fixture.moveArchiveOutOfTheBundle()

        // When
        let result = try fixture.run(arguments: ["indexer.js", "index"])

        // Then it was fetched, verified, and unpacked, and the archive was kept so the next start
        // does not fetch it again.
        #expect(result.exitCode == 0)
        #expect(
            FileManager.default.fileExists(atPath: fixture.state.appending(path: ".ready").path)
        )
        #expect(FileManager.default.fileExists(atPath: fixture.downloadedArchive.path))
    }

    @Test func anArchiveThatFailsItsHashAfterFetchingIsDiscarded() throws {
        // Given a release asset that is not the archive the app recorded a hash for.
        let fixture = try ShimFixture()
        defer { fixture.cleanUp() }
        let remote = try fixture.moveArchiveOutOfTheBundle()
        try Data("not the archive".utf8).write(to: remote)

        // When
        let result = try fixture.run(arguments: ["indexer.js"], tolerateFailure: true)

        // Then it stopped at the hash and removed what it fetched, so the next start fetches again
        // rather than repeating the same failure for ever.
        #expect(result.exitCode != 0)
        #expect(!FileManager.default.fileExists(atPath: fixture.downloadedArchive.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.state.appending(path: "bun").path))
    }

    @Test func aFetchedArchiveIsUnpackedAgainWithoutFetching() throws {
        // Given a runtime that was fetched and unpacked once.
        let fixture = try ShimFixture()
        defer { fixture.cleanUp() }
        _ = try fixture.moveArchiveOutOfTheBundle()
        _ = try fixture.run(arguments: ["indexer.js"])
        // The app's runtime is then lost, and the release is no longer reachable.
        try FileManager.default.removeItem(at: fixture.state)
        try FileManager.default.removeItem(at: fixture.bundle.appending(path: "runtime.url"))

        // When
        let result = try fixture.run(arguments: ["indexer.js"])

        // Then the kept archive was enough: a Mac that fetched it once can rebuild the runtime
        // without the network.
        #expect(result.exitCode == 0)
        #expect(FileManager.default.fileExists(atPath: fixture.state.appending(path: "bun").path))
    }

    @Test func aBundleWithNeitherArchiveNorSourceReportsWhatIsMissing() throws {
        // Given a bundle built before the archive was a download.
        let fixture = try ShimFixture()
        defer { fixture.cleanUp() }
        try FileManager.default.removeItem(at: fixture.bundle.appending(path: "runtime.zip"))

        // When
        let result = try fixture.run(arguments: ["indexer.js"], tolerateFailure: true)

        // Then the reason is a sentence rather than a silent failure.
        #expect(result.exitCode != 0)
        #expect(result.standardError.contains("no runtime archive and nothing to fetch"))
    }

    @Test func anArchiveWithNoRecordedHashIsRefused() throws {
        // Given a bundle that lost the file holding the hash.
        let fixture = try ShimFixture()
        defer { fixture.cleanUp() }
        try FileManager.default.removeItem(at: fixture.bundle.appending(path: "runtime.sha256"))

        // When
        let result = try fixture.run(arguments: ["indexer.js"], tolerateFailure: true)

        // Then
        #expect(result.exitCode != 0)
        #expect(result.standardError.contains("missing runtime.sha256"))
    }

    @Test func theLogFolderIsTheOneTheRunWasGiven() throws {
        // Given a run that names where its log goes.
        let fixture = try ShimFixture()
        defer { fixture.cleanUp() }
        let logs = fixture.root.appending(path: "logs", directoryHint: .isDirectory)

        // When
        let result = try fixture.run(arguments: ["indexer.js"])

        // Then the folder was made where it was asked for, and the expanding step did not leave a
        // folder named after the variable itself in the working directory.
        #expect(result.exitCode == 0)
        #expect(FileManager.default.fileExists(atPath: logs.path))
        let working = URL(filePath: FileManager.default.currentDirectoryPath)
        let strays = (try? FileManager.default.contentsOfDirectory(atPath: working.path)) ?? []
        #expect(strays.filter { $0.contains("${") }.isEmpty)
    }

    @Test func aRuntimeThatCannotBeCreatedIsReportedInsteadOfWaitedOn() throws {
        // Given a destination under a path that cannot be a folder.
        var fixture = try ShimFixture()
        defer { fixture.cleanUp() }
        fixture.state = URL(filePath: "/dev/null/call-recorder-\(UUID().uuidString)/runtime")

        // When
        let result = try fixture.run(arguments: ["indexer.js"], tolerateFailure: true)

        // Then it says what it could not create. A failed lock used to read as another process
        // holding it, which turned a fault here into a three-minute wait.
        #expect(result.exitCode != 0)
        #expect(result.standardError.contains("cannot create"))
    }
}

/// A runtime built for one test: a stand-in for bun that prints its arguments, two entry points,
/// and the archive and hash the shim reads.
private struct ShimFixture {
    let root: URL
    let bundle: URL
    var state: URL

    init() throws {
        let manager = FileManager.default
        root = manager.temporaryDirectory
            .appending(path: "indexer-runtime-\(UUID().uuidString)", directoryHint: .isDirectory)
        bundle = root.appending(path: "bundle", directoryHint: .isDirectory)
        state = root.appending(path: "state/runtime", directoryHint: .isDirectory)
        let source = root.appending(path: "source", directoryHint: .isDirectory)
        try manager.createDirectory(
            at: source.appending(path: "node_modules/sample", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try manager.createDirectory(at: bundle, withIntermediateDirectories: true)

        let script = "#!/bin/sh\nfor argument in \"$@\"; do echo \"ARG $argument\"; done\n"
        try Self.write(script, to: source.appending(path: "bun"), executable: true)
        try Self.write("// entry point\n", to: source.appending(path: "indexer.js"))
        try Self.write("// entry point\n", to: source.appending(path: "mcp-server.js"))
        try Self.write("// module\n", to: source.appending(path: "node_modules/sample/index.js"))

        // The archive holds its contents at the top level, which is the layout the app ships.
        let archive = bundle.appending(path: "runtime.zip")
        _ = try Self.run(
            executable: URL(filePath: "/bin/sh"),
            arguments: [
                "-c",
                "cd " + Self.quoted(source.path) + " && ditto -c -k --sequesterRsrc . "
                    + Self.quoted(archive.path),
            ]
        )
        let digest = SHA256.hash(data: try Data(contentsOf: archive))
            .map { String(format: "%02x", $0) }
            .joined()
        try Self.write(digest, to: bundle.appending(path: "runtime.sha256"))

        // The script the app installs as the folder's bun.
        let shim = TestEnvironment.packageRoot.appending(path: "scripts/indexer-runtime-shim.sh")
        try manager.createDirectory(at: bundle, withIntermediateDirectories: true)
        try manager.copyItem(at: shim, to: bundle.appending(path: "bun"))
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundle.appending(path: "bun").path)
    }

    func run(arguments: [String], tolerateFailure: Bool = false) throws -> ProcessResult {
        let assignments = [
            "CALL_RECORDER_RUNTIME_DIR=" + state.path,
            "CALL_RECORDER_LOG_DIR=" + root.appending(path: "logs").path,
            "CALL_RECORDER_RUNTIME_WAIT_SECONDS=5",
        ]
        let result = try Self.run(
            executable: URL(filePath: "/usr/bin/env"),
            arguments: assignments + [bundle.appending(path: "bun").path] + arguments
        )
        if !tolerateFailure, result.exitCode != 0 {
            Issue.record(
                "the shim stopped with \(result.exitCode): \(result.standardError)"
            )
        }
        return result
    }

    /// Where the shim keeps the archive it fetched, beside the runtime it unpacks.
    var downloadedArchive: URL {
        state.deletingLastPathComponent().appending(path: "runtime.zip")
    }

    /// Moves the archive out of the bundle and leaves a URL to it, which is how the shipped app is
    /// built: the archive travels as a release asset, and the bundle carries its hash and where to
    /// find it. The file URL stands in for the release here, so no test needs the network.
    ///
    /// - Returns: the file the bundle now points at, so a test can replace or damage it.
    @discardableResult
    func moveArchiveOutOfTheBundle() throws -> URL {
        let manager = FileManager.default
        let release = root.appending(path: "release", directoryHint: .isDirectory)
        try manager.createDirectory(at: release, withIntermediateDirectories: true)
        let destination = release.appending(path: "CallRecorder-runtime.zip")
        try manager.moveItem(at: bundle.appending(path: "runtime.zip"), to: destination)
        try Self.write("file://" + destination.path, to: bundle.appending(path: "runtime.url"))
        return destination
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    private static func write(
        _ text: String,
        to url: URL,
        executable: Bool = false
    ) throws {
        try Data(text.utf8).write(to: url)
        if executable {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: url.path
            )
        }
    }

    private static func quoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func run(executable: URL, arguments: [String]) throws -> ProcessResult {
        try ProcessRunner.run(executable: executable, arguments: arguments)
    }
}
