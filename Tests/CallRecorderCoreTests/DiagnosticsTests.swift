import CallRecorderCore
import Foundation
import Testing
@testable import CallRecorderApp

@Suite("Diagnostics")
struct DiagnosticsTests {
    @Test("export-safe errors redact credentials and transcript content")
    func exportedDiagnosticsRedactCredentialsAndContent() {
        // Given
        let error = "Authorization: Bearer hf_secret transcript=private words"

        // When
        let report = DiagnosticsReporter.redacted(error: error)

        // Then
        #expect(!report.contains("hf_secret"))
        #expect(!report.contains("private words"))
        #expect(report.contains("<redacted>"))
    }

    @Test("a backup is readable, private, and passes database integrity checks")
    func backupOpensAndPassesIntegrityChecks() async throws {
        // Given
        let root = FileManager.default.temporaryDirectory
            .appending(path: "call-recorder-backup-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CallStore(path: root.appending(path: "calls.db").path)
        try await store.migrate()
        let call = CallRecord.started(
            id: CallID(rawValue: UUID()),
            at: Date(timeIntervalSince1970: 1_800_000_000)
        )
        try await store.createCall(call)
        let backups = root.appending(path: "Backups", directoryHint: .isDirectory)

        // When
        let backup = try await store.createBackup(
            in: backups,
            at: Date(timeIntervalSince1970: 1_800_000_120)
        )

        // Then
        let report = try CallStore.integrityReport(at: backup)
        #expect(report.isHealthy)
        let reopened = try CallStore(path: backup.path)
        #expect(try await reopened.call(id: call.id) == call)
        let attributes = try FileManager.default.attributesOfItem(atPath: backup.path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(permissions.intValue & 0o777 == 0o600)
    }

    @Test("creating a verified backup retains the newest three")
    func backupRetentionKeepsNewestThree() async throws {
        // Given
        let root = FileManager.default.temporaryDirectory
            .appending(path: "call-recorder-retention-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CallStore(path: root.appending(path: "calls.db").path)
        try await store.migrate()
        let backups = root.appending(path: "Backups", directoryHint: .isDirectory)

        // When
        var created: [URL] = []
        for seconds in [1_800_000_000.0, 1_800_000_060.0, 1_800_000_120.0, 1_800_000_180.0] {
            created.append(
                try await store.createBackup(
                    in: backups,
                    at: Date(timeIntervalSince1970: seconds)
                )
            )
        }

        // Then
        let retained = try FileManager.default.contentsOfDirectory(
            at: backups,
            includingPropertiesForKeys: nil
        )
        let databases = retained.filter { $0.pathExtension == "db" }
        #expect(databases.count == 3)
        #expect(!retained.contains { $0.lastPathComponent.hasSuffix("-wal") })
        #expect(!retained.contains { $0.lastPathComponent.hasSuffix("-shm") })
        #expect(!FileManager.default.fileExists(atPath: created[0].path))
        #expect(FileManager.default.fileExists(atPath: created[3].path))
    }

    @Test("diagnostics export is private, redacted, and excludes meeting content")
    func diagnosticsExportIsSafe() async throws {
        // Given
        let root = FileManager.default.temporaryDirectory
            .appending(path: "call-recorder-diagnostics-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CallStore(path: root.appending(path: "calls.db").path)
        try await store.migrate()
        let callID = CallID(rawValue: UUID())
        try await store.createCall(.started(id: callID, at: Date(timeIntervalSince1970: 1_800_000_000)))
        try await store.updateCall(
            id: callID,
            endedAt: Date(timeIntervalSince1970: 1_800_000_060),
            audioPath: "/private/call.m4a",
            status: .metadata
        )
        try await store.setParticipants([], for: callID)
        _ = try #require(try await store.claimNextProcessingJob(executableOnly: true))
        _ = try await store.failProcessingJob(
            callID: callID,
            stage: .queued,
            summary: "Processing failed.",
            details: "transcript=private words token=secret"
        )

        // When
        let archive = try await DiagnosticsReporter.exportBundle(
            store: store,
            appVersion: "test",
            modelVersions: ["whisper-medium"],
            to: root,
            includeUnifiedLogs: false
        )

        // Then
        let listing = try ProcessRunner.runChecked(
            executable: URL(filePath: "/usr/bin/unzip"),
            arguments: ["-Z1", archive.path]
        ).standardOutput
        let report = try ProcessRunner.runChecked(
            executable: URL(filePath: "/usr/bin/unzip"),
            arguments: ["-p", archive.path, "diagnostics.json"]
        ).standardOutput
        #expect(listing.contains("diagnostics.json"))
        #expect(!listing.contains("transcript"))
        #expect(!listing.contains("call.m4a"))
        #expect(!report.contains("private words"))
        #expect(!report.contains("token=secret"))
        #expect(report.contains("<redacted>"))
        for forbidden in [
            "participant_voice_samples",
            "pending_speaker_clusters",
            "speaker_assignments",
            "local.callrecorder.app.voiceprints",
            "embedding-key-v1",
        ] {
            #expect(!report.contains(forbidden))
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: archive.path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(permissions.intValue & 0o777 == 0o600)
    }
}
