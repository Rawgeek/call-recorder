import CallRecorderCore
import Foundation
import OSLog

enum DiagnosticsReporter {
    enum Category: String {
        case capture
        case processing
        case database
        case models
        case indexing
        case recovery
    }

    static func redacted(error: String) -> String {
        let replacements = [
            (#"(?i)\b(transcript|prompt|audio|text)\s*=\s*.*$"#, "$1=<redacted>"),
            (#"(?i)(authorization\s*:\s*bearer\s+)[^\s]+"#, "$1<redacted>"),
            (#"\bhf_[A-Za-z0-9_-]+\b"#, "hf_<redacted>"),
            (#"(?i)\b(api[_-]?key|token|password|secret)\s*[:=]\s*[^\s,;]+"#, "$1=<redacted>"),
        ]
        return replacements.reduce(error) { value, replacement in
            guard let expression = try? NSRegularExpression(pattern: replacement.0) else {
                return value
            }
            return expression.stringByReplacingMatches(
                in: value,
                range: NSRange(value.startIndex..., in: value),
                withTemplate: replacement.1
            )
        }
    }

    static func record(
        _ error: any Error,
        context: String,
        state: String,
        category: Category
    ) -> String {
        let detail = redacted(error: String(reflecting: error))
        let diagnostics = """
            Timestamp: \(Date().ISO8601Format())
            Context: \(context)
            State: \(state)
            Error: \(detail)

            Stack trace:
            \(Thread.callStackSymbols.joined(separator: "\n"))
            """
        Logger(subsystem: "local.callrecorder.app", category: category.rawValue)
            .error("\(diagnostics, privacy: .public)")
        return diagnostics
    }

    static func exportBundle(
        store: CallStore,
        appVersion: String,
        modelVersions: [String],
        to directory: URL,
        includeUnifiedLogs: Bool = true
    ) async throws -> URL {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let work = directory.appending(
            path: ".diagnostics-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: work,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: work) }

        let events = try await store.recentProcessingEvents().map { event in
            ProcessingEvent(
                id: event.id,
                callID: event.callID,
                stage: event.stage,
                severity: event.severity,
                summary: redacted(error: event.summary),
                errorType: event.errorType.map { redacted(error: $0) },
                details: event.details.map { redacted(error: $0) },
                stderr: event.stderr.map { redacted(error: $0) },
                createdAt: event.createdAt
            )
        }
        let snapshot = DiagnosticsSnapshot(
            generatedAt: Date(),
            appVersion: appVersion,
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            modelVersions: modelVersions,
            integrity: try await store.integrityReport(),
            processingJobs: try await store.processingJobs(),
            processingEvents: events
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let report = work.appending(path: "diagnostics.json")
        try encoder.encode(snapshot).write(to: report, options: .atomic)
        var files = [report]

        if includeUnifiedLogs {
            let result = try ProcessRunner.run(
                executable: URL(filePath: "/usr/bin/log"),
                arguments: [
                    "show", "--last", "24h", "--style", "compact",
                    "--predicate", "subsystem == \"local.callrecorder.app\"",
                ]
            )
            let logs = work.appending(path: "unified.log")
            let output = result.exitCode == 0 ? result.standardOutput : result.standardError
            try Data(redacted(error: output).utf8).write(to: logs, options: .atomic)
            files.append(logs)
        }

        let stamp = Date().formatted(
            .iso8601.year().month().day().time(includingFractionalSeconds: false)
        ).replacingOccurrences(of: ":", with: "-")
        let suffix = UUID().uuidString.prefix(8)
        let archive = directory.appending(path: "CallRecorder-Diagnostics-\(stamp)-\(suffix).zip")
        _ = try ProcessRunner.runChecked(
            executable: URL(filePath: "/usr/bin/zip"),
            arguments: ["-j", "-q", archive.path] + files.map(\.path)
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: archive.path
        )
        return archive
    }
}

private struct DiagnosticsSnapshot: Codable {
    let generatedAt: Date
    let appVersion: String
    let operatingSystem: String
    let modelVersions: [String]
    let integrity: DatabaseIntegrityReport
    let processingJobs: [ProcessingJob]
    let processingEvents: [ProcessingEvent]
}
