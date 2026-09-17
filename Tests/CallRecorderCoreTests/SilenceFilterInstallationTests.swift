import Foundation
import Testing
@testable import CallRecorderApp
@testable import CallRecorderCore

/// The silence filter is a download now, and the app finds it the way it finds every other
/// downloaded model: the manifest names the revision, and the bytes are checked before whisper.cpp
/// is handed the path. A file that does not match is not used, and one that was never recorded is
/// not treated as installed.
struct SilenceFilterInstallationTests {
    @Test func theInstalledFilterIsFoundAtTheRevisionTheManifestRecords() throws {
        // Given a copy installed where the manifest says it is.
        let fixture = try SilenceFilterFixture()
        defer { fixture.cleanUp() }

        // When / Then
        #expect(
            Transcriber.installedVADModel(applicationDirectory: fixture.root)?.path
                == fixture.destination.path
        )
        #expect(
            try Transcriber.resolvedVADModel(applicationDirectory: fixture.root).path
                == fixture.destination.path
        )
    }

    @Test func aFileWhoseBytesDoNotMatchThePinnedOnesIsNotUsed() throws {
        // Given a file at the right path holding something else.
        let fixture = try SilenceFilterFixture(contentsOfModel: nil)
        defer { fixture.cleanUp() }

        // When / Then
        #expect(Transcriber.installedVADModel(applicationDirectory: fixture.root) == nil)
    }

    @Test func aCopyTheManifestDoesNotRecordIsNotInstalled() throws {
        // Given a file in place that nothing has verified.
        let fixture = try SilenceFilterFixture(record: false)
        defer { fixture.cleanUp() }

        // When / Then
        #expect(Transcriber.installedVADModel(applicationDirectory: fixture.root) == nil)
    }
}

/// One Application Support folder holding the silence filter at the revision the catalog pins.
private struct SilenceFilterFixture {
    let root: URL
    let destination: URL

    /// - Parameters:
    ///   - contentsOfModel: The bytes to install, or nil to write a file that is not the model.
    ///   - record: Whether the manifest names the installed copy.
    init(contentsOfModel: URL? = TestEnvironment.developmentVADModel, record: Bool = true) throws {
        let filter = try #require(
            SupportingModel.catalog.first { $0.id == SupportingModel.sileroVADID }
        )
        let file = try #require(filter.files.first)
        root = FileManager.default.temporaryDirectory
            .appending(path: "silence-filter-\(UUID().uuidString)", directoryHint: .isDirectory)
        destination = filter
            .directory(in: root, revision: filter.revision)
            .appending(path: file.path)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if let contentsOfModel {
            try FileManager.default.copyItem(at: contentsOfModel, to: destination)
        } else {
            try Data(repeating: 0, count: 16).write(to: destination)
        }
        guard record else { return }
        var manifest = SupportingModelManifest()
        manifest.record(
            InstalledSupportingModel(
                modelID: filter.id,
                revision: filter.revision,
                installedAt: Date(),
                files: filter.files.map {
                    InstalledSupportingFile(path: $0.path, bytes: $0.bytes, sha256: $0.sha256)
                }
            )
        )
        try manifest.write(to: SupportingModelManifest.defaultURL(in: root))
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}
