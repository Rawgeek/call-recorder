import CallRecorderCore
import Foundation
import Testing
@testable import CallRecorderApp

@Suite("Indexer client")
struct IndexerClientTests {
    @Test func anArchivedRuntimeNamesItsEntryPointInsteadOfAddressingIt() {
        // Given a bundle that ships the runtime as an archive: the entry point is inside it, and
        // there is no copy beside the shim. Naming it is the only way to ask for it.
        let layout = IndexerBundleLayout.resolve(
            bundledRuntime: URL(filePath: "/Applications/Call Recorder.app/Contents/Resources/indexer/bun"),
            canExecute: { _ in true },
            archive: URL(filePath: "/Applications/Call Recorder.app/Contents/Resources/indexer/runtime.zip"),
            script: nil
        )

        // Then
        #expect(layout == .archivedRuntime)
        #expect(layout.argumentPrefix == ["indexer.js"])
    }

    @Test func aBundleWithoutTheArchiveAddressesItsEntryPoint() {
        // Given a build from before the archive, where the file sits beside the runtime.
        let script = URL(filePath: "/Applications/old.app/Contents/Resources/indexer/indexer.js")
        let layout = IndexerBundleLayout.resolve(
            bundledRuntime: URL(filePath: "/Applications/old.app/Contents/Resources/indexer/bun"),
            canExecute: { _ in true },
            archive: nil,
            script: script
        )

        // Then
        #expect(layout == .unpackedRuntime(script: script))
        #expect(layout.argumentPrefix == [script.path])
    }

    @Test func aBundleThatCannotRunAnythingFallsBackToTheMachine() {
        // Given a runtime that is not executable, and no entry point at all.
        let layout = IndexerBundleLayout.resolve(
            bundledRuntime: URL(filePath: "/Applications/broken.app/indexer/bun"),
            canExecute: { _ in false },
            archive: nil,
            script: nil
        )

        // Then
        #expect(layout == .unavailable)
        #expect(layout.argumentPrefix.isEmpty)
    }

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
