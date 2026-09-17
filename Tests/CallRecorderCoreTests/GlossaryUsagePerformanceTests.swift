import Foundation
import Testing
@testable import CallRecorderCore

/// Not a timing assertion. The check prints how long the scan takes so a regression that turns
/// the metadata refresh into a multi-second wait shows up in the test output.
@Suite("Glossary usage cost")
struct GlossaryUsagePerformanceTests {
    @Test func scanCostStaysSmall() async throws {
        let path = FileManager.default.temporaryDirectory
            .appending(path: "glossary-perf-\(UUID().uuidString).db").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try CallStore(path: path)
        try await store.migrate()
        for index in 0..<120 {
            _ = try await store.upsertGlossaryTerm(
                preferred: "Term\(index)",
                aliases: ["Alt term \(index)", "Домен \(index)"]
            )
        }
        let body = (0..<160).map {
            "**Sam**: line \($0) about Globex, RMA, Acme and ShipStation planning. "
        }.joined(separator: "\n\n")
        for index in 0..<20 {
            let callID = CallID(rawValue: UUID())
            try await store.createCall(
                .started(id: callID, at: Date(timeIntervalSince1970: 1_800_000_000 + Double(index)))
            )
            try await store.saveTranscript(
                TranscriptRecord(
                    callID: callID, language: "en", model: "medium",
                    text: "# Meeting Transcript\n\nParticipants: Sam\nGlossary: Globex\n\n" + body,
                    markdownPath: "/tmp/perf-\(index).md", jsonPath: "/tmp/perf-\(index).json"
                )
            )
        }

        let started = ContinuousClock.now
        let counts = try await store.glossaryUsageCounts()
        let elapsed = ContinuousClock.now - started
        let characters = Double(20 * body.count)
        print("glossary scan: \(elapsed) for \(Int(characters)) characters, \(counts.count) terms")
        #expect(counts.count == 120)
    }
}
