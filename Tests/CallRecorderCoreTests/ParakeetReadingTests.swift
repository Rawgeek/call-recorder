import CallRecorderCore
import Foundation
import Testing
@testable import CallRecorderApp

/// A reading of a real file by the engine a call is now read with.
///
/// The model is a download of hundreds of megabytes, so this suite steps aside on a Mac that has
/// not installed it rather than failing there: what it proves needs the bytes, and a suite that
/// cannot run without them would fail for the wrong reason on every machine that never switched
/// engines. The file it reads is made on this Mac, so no recording of anybody's is needed.
@Suite("Reading a recording with Parakeet")
struct ParakeetReadingTests {
    private static let spokenSentence = "The new card lands on the first of October."

    private var repository: URL {
        ParakeetModel.repository(in: Self.applicationDirectory)
    }

    private static var applicationDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(
                path: "Library/Application Support/CallRecorder",
                directoryHint: .isDirectory
            )
    }

    /// A file of spoken words, written by the system voice.
    private func spokenFile(_ sentence: String) throws -> URL {
        let url = URL(filePath: NSTemporaryDirectory())
            .appending(path: "parakeet-reading-" + UUID().uuidString + ".aiff")
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/say")
        process.arguments = ["-o", url.path, sentence]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: url.path)
        else { throw VoiceFailed() }
        return url
    }

    private struct VoiceFailed: Error {}

    /// A file of nothing, made the way a recording of a quiet room is made.
    private func silence(seconds: Int) throws -> URL {
        let url = URL(filePath: NSTemporaryDirectory())
            .appending(path: "parakeet-silence-" + UUID().uuidString + ".wav")
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = [
            "ffmpeg", "-v", "error", "-y", "-f", "lavfi",
            "-i", "anullsrc=r=16000:cl=mono", "-t", String(seconds), url.path,
        ]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw VoiceFailed() }
        return url
    }

    @Test("a spoken sentence comes back as the words that were said, with the times they were said at")
    func aSpokenSentenceComesBack() async throws {
        guard ParakeetModel.isComplete(at: repository) else { return }
        let audio = try spokenFile(Self.spokenSentence)
        defer { try? FileManager.default.removeItem(at: audio) }

        let engine = ParakeetEngine(repository: repository)
        let transcript = try await engine.transcribe(audio: audio, language: "auto")

        print("PARAKEET READING:", transcript.text)
        let words = transcript.text.lowercased()
        #expect(words.contains("card"))
        #expect(words.contains("october"))
        #expect(!transcript.segments.isEmpty)
        // Every turn holds a time, and no turn ends before it starts.
        #expect(transcript.segments.allSatisfy { $0.endMs >= $0.startMs })
        #expect(transcript.segments.contains { $0.endMs > $0.startMs })
        // Nothing was named, so the language is read off the words themselves, and these are
        // English words.
        #expect(transcript.language == "en")
    }

    @Test("a language the setting names is held to, and a reading in it still comes back")
    func aNamedLanguageIsHeldTo() async throws {
        guard ParakeetModel.isComplete(at: repository) else { return }
        let audio = try spokenFile(Self.spokenSentence)
        defer { try? FileManager.default.removeItem(at: audio) }

        let engine = ParakeetEngine(repository: repository)
        let transcript = try await engine.transcribe(audio: audio, language: "en")

        #expect(transcript.text.lowercased().contains("card"))
        #expect(transcript.language == "en")
    }

    @Test("a model that is not on disk is refused rather than read from")
    func aMissingModelIsRefused() async throws {
        let absent = URL(filePath: NSTemporaryDirectory())
            .appending(path: "parakeet-absent-" + UUID().uuidString, directoryHint: .isDirectory)
        let engine = ParakeetEngine(repository: absent)

        await #expect(throws: ParakeetEngineError.self) {
            try await engine.transcribe(audio: URL(filePath: "/dev/null"), language: "auto")
        }
    }

    @Test("a recording that holds nothing reads as no words rather than as a fault")
    func silenceReadsAsNoWords() async throws {
        guard ParakeetModel.isComplete(at: repository) else { return }
        let audio = try silence(seconds: 30)
        defer { try? FileManager.default.removeItem(at: audio) }

        let engine = ParakeetEngine(repository: repository)
        let transcript = try await engine.transcribe(audio: audio, language: "auto")

        // A muted microphone and a room with nobody in it have to land on the app's own answer for
        // a call with no speech, which is a transcript with no turns. Throwing here would mark a
        // call failed for the one thing it cannot do anything about.
        #expect(transcript.segments.isEmpty)
        #expect(transcript.text.isEmpty)
        #expect(transcript.language == "unknown")
    }
}
