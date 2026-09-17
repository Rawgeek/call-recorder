import Foundation
import Libsql
import Testing
@testable import CallRecorderCore

// A diagnosis that runs only when it is pointed at a copy of a real database.
//
// It writes: it settles and reopens speaker fragments and closes indexing jobs whose index is
// already built. Point it at a copy, never at the database the running app is using.
@Suite("Live database diagnosis", .enabled(if: ProcessInfo.processInfo.environment["CALL_RECORDER_DIAGNOSE_DB"] != nil))
struct LiveDatabaseDiagnosisTests {
    @Test("the live library's stuck state, reported and repaired")
    func repairsLiveLibrary() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["CALL_RECORDER_DIAGNOSE_DB"])
        let store = try await CallStore(path: path)
        let connection = try Database(path).connect()

        // The migrations a new build applies at launch, run first. A schema change that cannot be
        // applied to a real library is the one failure that would keep the app from starting, and
        // it is only visible against a library that was written by an older one.
        try await store.migrate()
        let migrations = try connection.query(
            "SELECT id FROM call_recorder_migrations ORDER BY applied_at"
        ).map { try $0.getString(0) }
        print("DIAGNOSE migrations applied: \(migrations.count)")
        print("DIAGNOSE newest migration: \(migrations.last ?? "none")")
        let overridesTableExists = try connection.query(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'speaker_line_overrides'"
        ).next() != nil
        print("DIAGNOSE line corrections table: \(overridesTableExists)")
        let requestColumns = try connection.query("PRAGMA table_info(speaker_review_requests)")
            .map { try $0.getString(1) }
        print("DIAGNOSE request columns: \(requestColumns.joined(separator: ","))")
        print("DIAGNOSE request has call_id: \(requestColumns.contains("call_id"))")
        let callColumns = try connection.query("PRAGMA table_info(calls)")
            .map { try $0.getString(1) }
        print("DIAGNOSE calls has system_audio: \(callColumns.contains("system_audio"))")
        print("DIAGNOSE integrity after migrate: \(try await store.integrityReport().isHealthy)")

        let before = try connection.query(
            "SELECT COUNT(*) FROM processing_jobs WHERE stage = 'indexing' AND execution_state = 'pending'"
        ).map { try $0.getInt(0) }
        print("DIAGNOSE indexing jobs queued before: \(before)")

        let settled = try await store.settleCompletedIndexingJobs()
        print("DIAGNOSE settled: \(settled)")

        let after = try connection.query(
            "SELECT COUNT(*) FROM processing_jobs WHERE execution_state != 'complete'"
        ).map { try $0.getInt(0) }
        print("DIAGNOSE jobs not complete after: \(after)")
        print("DIAGNOSE integrity healthy: \(try await store.integrityReport().isHealthy)")
    }
}
