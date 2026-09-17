import CallRecorderCore
import Foundation
import Testing
@testable import CallRecorderApp

@Suite("Indexer client")
struct IndexerClientTests {
    @Test("a successful index process synchronizes index_jobs ready through the same store")
    func successfulIndexSynchronizesStoreReadiness() async throws {
        // Given: a call whose index_jobs row is still pending in the long-lived store.
        let root = FileManager.default.temporaryDirectory
            .appending(path: "indexer-sync-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CallStore(path: root.appending(path: "calls.db").path)
        try await store.migrate()
        let callID = CallID(rawValue: UUID())
        try await store.createCall(
            .started(id: callID, at: Date(timeIntervalSince1970: 1_800_000_000))
        )
        try await store.saveTranscript(
            TranscriptRecord(
                callID: callID,
                language: "en",
                model: "fixture",
                text: "hello",
                markdownPath: root.appending(path: "call.md").path,
                jsonPath: root.appending(path: "call.json").path
            ),
            queueIndexing: false
        )
        #expect(try await store.indexIsReady(for: callID) == false)
        let client = IndexerClient(
            executable: URL(filePath: "/usr/bin/true"),
            argumentPrefix: [],
            database: root.appending(path: "calls.db"),
            cache: root.appending(path: "cache")
        )

        // When: the index subprocess exits 0 (the durable success contract).
        try await client.index(callID: callID, store: store)

        // Then: the same store now reports index readiness.
        #expect(try await store.indexIsReady(for: callID))
    }
}
