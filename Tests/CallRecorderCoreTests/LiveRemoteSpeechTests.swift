import CallRecorderCore
import Foundation
import Testing
@testable import CallRecorderApp

/// The whole remote path, driven by the code a call is driven by.
///
/// The stubbed suites prove the request shape, the mapping, and the fallback. This one proves the
/// parts only a real endpoint can: the conversion to 16 kHz mono, the multipart upload, the
/// endpoint's actual answer, and the transcript files the app writes from it. It is skipped unless
/// a recording and an address are named.
@Suite("A call read by a remote endpoint", .enabled(if: TestEnvironment.canRunRemoteSpeech))
struct LiveRemoteSpeechTests {
    @Test("a real recording becomes a timed transcript", .timeLimit(.minutes(15)))
    func readsARecordingThroughTheEndpoint() async throws {
        let source = try #require(TestEnvironment.remoteSpeechRecording)
        let address = try #require(TestEnvironment.remoteSpeechURL)
        let ffmpeg = try #require(ToolLocator.standard.locate("ffmpeg"))
        try #require(FileManager.default.fileExists(atPath: source.path))

        let root = FileManager.default.temporaryDirectory
            .appending(path: "live-remote-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let track = root.appending(path: "system.m4a")
        try FileManager.default.copyItem(at: source, to: track)

        let engine = RemoteSpeechReader(
            configuration: RemoteSpeechConfiguration(
                baseURL: address,
                model: TestEnvironment.remoteSpeechModel,
                token: TestEnvironment.remoteSpeechToken ?? ""
            ),
            ffmpeg: ffmpeg
        )
        // The same request the Test connection button makes, against the same server.
        let check = try await engine.connectionReport()
        print("REMOTE CHECK \(check.summary)")
        #expect(check.status == 200)

        let started = Date()
        let record = try await Transcriber(
            language: "auto",
            includeTimestamps: true,
            engine: engine
        ).transcribe(
            callID: CallID(rawValue: UUID()),
            audio: track,
            modelID: "local default",
            participants: [],
            glossary: [],
            directory: root
        )
        let seconds = Date().timeIntervalSince(started)

        let words = record.text.split(whereSeparator: { $0.isWhitespace }).count
        print("REMOTE READ \(words) words in \(String(format: "%.1f", seconds))s")
        print("REMOTE MODEL \(record.model)")
        print("REMOTE TRANSCRIPT\n\(record.text)")

        #expect(words > 20, "the endpoint read speech and the app wrote it")
        #expect(record.model.contains("Remote endpoint"), "the metadata names the reader that answered")
        let document = try JSONDecoder().decode(
            NormalizedTranscript.self,
            from: Data(contentsOf: URL(filePath: record.jsonPath))
        )
        #expect(!document.segments.isEmpty)
        #expect(document.segments.allSatisfy { $0.startMs < $0.endMs })
        #expect(FileManager.default.fileExists(atPath: record.markdownPath))

        if let output = ProcessInfo.processInfo.environment["CALL_RECORDER_REMOTE_TRANSCRIPT_OUT"] {
            let markdown = try String(contentsOf: URL(filePath: record.markdownPath), encoding: .utf8)
            try markdown.write(
                to: URL(filePath: output),
                atomically: true,
                encoding: .utf8
            )
        }
    }
}
