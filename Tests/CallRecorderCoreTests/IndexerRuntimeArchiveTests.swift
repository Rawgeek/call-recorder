import Foundation
import Testing
@testable import CallRecorderApp

/// What the app does with the archive an earlier run left behind.
///
/// The archive is kept between launches, and an update can ship a different one. Presence alone
/// was treated as enough, and after one update the shim was handed the previous version's file,
/// refused it, and left the runtime missing until someone pressed Retry. The hash decides.
@Suite("Indexer runtime archive")
struct IndexerRuntimeArchiveTests {
    private func makeArchive(_ contents: String) throws -> (URL, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "runtime-archive-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let archive = directory.appending(path: "runtime.zip")
        try Data(contents.utf8).write(to: archive)
        return (directory, archive)
    }

    @Test("an archive that matches the recorded hash is kept")
    func matchingArchiveIsKept() async throws {
        let (directory, archive) = try makeArchive("the runtime")
        defer { try? FileManager.default.removeItem(at: directory) }
        let hash = await ModelManager.sha256(of: archive)
        #expect(await IndexerRuntimeInstaller.archive(archive, matches: hash))
    }

    @Test("an archive from an earlier version is refused")
    func earlierArchiveIsRefused() async throws {
        let (directory, archive) = try makeArchive("the runtime")
        defer { try? FileManager.default.removeItem(at: directory) }
        let other = directory.appending(path: "other.zip")
        try Data("another runtime".utf8).write(to: other)
        let otherHash = await ModelManager.sha256(of: other)
        #expect(await IndexerRuntimeInstaller.archive(archive, matches: otherHash) == false)
    }

    @Test("an archive that is not there is not an archive")
    func missingArchiveIsRefused() async {
        let missing = FileManager.default.temporaryDirectory
            .appending(path: "absent-\(UUID().uuidString).zip")
        #expect(await IndexerRuntimeInstaller.archive(missing, matches: "any") == false)
        #expect(await IndexerRuntimeInstaller.archive(missing, matches: nil) == false)
    }
}
