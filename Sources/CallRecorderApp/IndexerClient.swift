import CallRecorderCore
import Foundation

struct IndexerClient: Sendable {
    let executable: URL
    let argumentPrefix: [String]
    let database: URL
    let cache: URL

    static func standard(applicationDirectory: URL) -> IndexerClient? {
        let database = applicationDirectory.appending(path: "calls.db")
        let cache = applicationDirectory.appending(path: "models/embeddinggemma")
        if
            let bundledBun = Bundle.main.url(
                forResource: "bun",
                withExtension: nil,
                subdirectory: "indexer"
            ),
            let bundledScript = Bundle.main.url(
                forResource: "indexer",
                withExtension: "js",
                subdirectory: "indexer"
            ),
            FileManager.default.isExecutableFile(atPath: bundledBun.path)
        {
            return IndexerClient(
                executable: bundledBun,
                argumentPrefix: [bundledScript.path],
                database: database,
                cache: cache
            )
        }
        if let bundled = Bundle.main.url(
            forResource: "call-recorder-indexer",
            withExtension: nil,
            subdirectory: "bin"
        ), FileManager.default.isExecutableFile(atPath: bundled.path) {
            return IndexerClient(
                executable: bundled,
                argumentPrefix: [],
                database: database,
                cache: cache
            )
        }

        guard let bun = ToolLocator.standard.locate("bun") else { return nil }
        let configuredRoot = ProcessInfo.processInfo.environment["CALL_RECORDER_SOURCE_ROOT"]
            .map { URL(filePath: $0, directoryHint: .isDirectory) }
        let source = [configuredRoot, URL(filePath: FileManager.default.currentDirectoryPath)]
            .compactMap { $0 }
            .map { $0.appending(path: "mcp/src/index-call.ts") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
        guard let source else { return nil }
        return IndexerClient(
            executable: bun,
            argumentPrefix: [source.path],
            database: database,
            cache: cache
        )
    }

    /// Whether this build ships the runtime as an archive the shim unpacks.
    ///
    /// A source checkout has neither the archive nor the shim, and runs the entry point directly,
    /// so there is nothing to prepare.
    var hasArchivedRuntime: Bool {
        Bundle.main.url(forResource: "runtime", withExtension: "zip", subdirectory: "indexer") != nil
    }

    /// Unpacks the JavaScript runtime into Application Support when it is not there yet.
    ///
    /// The first indexing run or MCP start would do this anyway. Doing it at launch moves the wait
    /// to a quiet moment, and turns a failure into a sentence the app can show instead of a call
    /// that stops at the indexing stage.
    ///
    /// - Returns: A message naming the fault, or nil when the runtime is ready.
    func prepareRuntime() async -> String? {
        guard hasArchivedRuntime else { return nil }
        do {
            try await Task.detached {
                _ = try ProcessRunner.runChecked(
                    executable: executable,
                    arguments: ["--ensure-runtime"],
                    cancellation: nil
                )
            }.value
            return nil
        } catch {
            return "The transcript indexer could not prepare its runtime. "
                + error.localizedDescription
        }
    }

    func arguments(for callID: CallID) -> [String] {
        argumentPrefix + [
            "index",
            "--database", database.path,
            "--call-id", callID.rawValue.uuidString,
            "--cache", cache.path,
        ]
    }

    func index(
        callID: CallID,
        store: CallStore,
        cancellation: ProcessCancellation? = nil
    ) async throws {
        try await Task.detached {
            _ = try ProcessRunner.runChecked(
                executable: executable,
                arguments: arguments(for: callID),
                cancellation: cancellation
            )
        }.value
        // The subprocess commits index readiness on its own connection; sync it
        // through the long-lived store before the caller advances the stage.
        try await store.markIndexReady(for: callID)
    }
}
