import CallRecorderCore
import Foundation
import Testing
@testable import CallRecorderApp

@Suite("Transcript promoter")
struct TranscriptPromoterTests {
    @Test("retry reuses the identical transcript copied before database commit")
    func retryReusesCopiedTranscript() throws {
        // Given
        let fixture = try PromotionFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let promoter = TranscriptPromoter(outputRoot: fixture.outputRoot)
        let first = try promoter.promote(source: fixture.source, baseName: "2027-01-15T15-00-00")

        // When
        let retried = try promoter.promote(
            source: fixture.source,
            baseName: "2027-01-15T15-00-00"
        )

        // Then
        #expect(retried == first)
        #expect(FileManager.default.fileExists(atPath: fixture.source.path))
    }

    @Test("different existing transcript receives a collision suffix")
    func preservesDifferentExistingTranscript() throws {
        // Given
        let fixture = try PromotionFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let occupied = fixture.outputRoot.appending(path: "2027-01-15T15-00-00.md")
        try Data("another call".utf8).write(to: occupied)

        // When
        let destination = try TranscriptPromoter(outputRoot: fixture.outputRoot)
            .promote(source: fixture.source, baseName: "2027-01-15T15-00-00")

        // Then
        #expect(destination.lastPathComponent == "2027-01-15T15-00-00-2.md")
        #expect(try Data(contentsOf: occupied) == Data("another call".utf8))
    }

    @Test("normalized JSON is preserved privately for post-cleanup speaker review")
    func preservesPrivateMetadata() throws {
        let fixture = try PromotionFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let json = fixture.source.deletingLastPathComponent().appending(path: "transcript.json")
        try Data(#"{"segments":[]}"#.utf8).write(to: json)
        let callID = CallID(rawValue: UUID())

        let destination = try TranscriptPromoter(outputRoot: fixture.outputRoot)
            .preserveMetadata(source: json, callID: callID)

        #expect(destination == fixture.outputRoot.appending(path: "\(callID.rawValue.uuidString).json"))
        #expect(try Data(contentsOf: destination) == Data(#"{"segments":[]}"#.utf8))
        let permissions = try #require(
            FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions]
                as? NSNumber
        )
        #expect(permissions.intValue & 0o777 == 0o600)
    }
}

private struct PromotionFixture {
    let root: URL
    let outputRoot: URL
    let source: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "transcript-promoter-\(UUID().uuidString)", directoryHint: .isDirectory)
        outputRoot = root.appending(path: "Recordings", directoryHint: .isDirectory)
        source = outputRoot.appending(path: "working/transcript.md")
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("meeting transcript".utf8).write(to: source)
    }
}
