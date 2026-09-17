import CallRecorderCore
import Foundation
import Testing
@testable import CallRecorderApp

/// A review card is where a person decides who a voice is, and a diarized turn can open with
/// seconds of room tone. The clip played back is the excerpt with that silence taken out. The
/// command is built in Core, so it is checked without running anything, and two tests run it.
@Suite("Speaker sample cut")
struct SpeakerSampleCutTests {
    @Test("the filter trims both ends and shortens the pauses inside a turn")
    func theFilterTrimsBothEnds() {
        // Given / When
        let filter = SpeakerSampleCut.silenceFilter

        // Then
        #expect(filter.hasPrefix("silenceremove=start_periods=1"))
        #expect(filter.contains("stop_periods=-1"))
        #expect(filter.contains("start_threshold=-40dB"))
        #expect(filter.contains("stop_silence=0.3"))
        // Forward and then backward, because the filter only trims what it meets first.
        #expect(filter.components(separatedBy: "areverse").count == 3)
    }

    @Test("the command cuts the excerpt out of the recording")
    func theCommandCutsTheExcerpt() throws {
        // Given / When
        let arguments = SpeakerSampleCut.arguments(
            audio: URL(filePath: "/tmp/call.m4a"),
            destination: URL(filePath: "/tmp/clip.m4a"),
            startMilliseconds: 1_500,
            endMilliseconds: 4_000
        )

        // Then
        let seek = try #require(arguments.firstIndex(of: "-ss"))
        #expect(arguments[seek + 1] == "1.500")
        let limit = try #require(arguments.firstIndex(of: "-t"))
        #expect(arguments[limit + 1] == "2.500")
        // Seeking before the input is the fast path, which is the whole point at this length.
        let input = try #require(arguments.firstIndex(of: "-i"))
        #expect(input > seek)
        #expect(arguments.contains("-af"))
        #expect(arguments.last == "/tmp/clip.m4a")
    }

    @Test("the plain command is the same cut with the silence left in")
    func thePlainCommandKeepsTheSilence() {
        // Given / When
        let arguments = SpeakerSampleCut.plainArguments(
            audio: URL(filePath: "/tmp/call.m4a"),
            destination: URL(filePath: "/tmp/clip.m4a"),
            startMilliseconds: 0,
            endMilliseconds: 2_000
        )

        // Then
        #expect(!arguments.contains("-af"))
        #expect(arguments.contains("-c:a"))
        #expect(arguments.last == "/tmp/clip.m4a")
    }

    @Test(
        "the silence around a turn is taken out of its clip",
        .enabled(if: TestEnvironment.hasFFmpeg)
    )
    func silenceIsRemovedFromTheClip() async throws {
        // Given a recording of two seconds of room tone and two seconds of speech.
        let fixture = try SampleFixture(lengths: [("silence", 2), ("tone", 2)])
        defer { fixture.cleanUp() }

        // When the whole of it is cut for review.
        let clip = try await fixture.builder.sample(
            callID: fixture.callID,
            startMilliseconds: 0,
            endMilliseconds: 4_000,
            audio: fixture.audio
        )

        // Then the clip holds the speech and is shorter than what it came from.
        let duration = try fixture.duration(of: clip)
        #expect(duration >= SpeakerSampleCut.minimumSeconds)
        #expect(duration < 3.9)
    }

    @Test(
        "an excerpt that is silence from end to end is still playable",
        .enabled(if: TestEnvironment.hasFFmpeg)
    )
    func silenceOnlyExcerptFallsBackToThePlainCut() async throws {
        // Given two seconds of room tone and nothing else.
        let fixture = try SampleFixture(lengths: [("silence", 2)])
        defer { fixture.cleanUp() }

        // When
        let clip = try await fixture.builder.sample(
            callID: fixture.callID,
            startMilliseconds: 0,
            endMilliseconds: 2_000,
            audio: fixture.audio
        )

        // Then the plain cut is what came back, because an empty clip would say nothing at all.
        let duration = try fixture.duration(of: clip)
        #expect(duration >= 1.5)
    }
}

/// A recording built for one test, and the builder that cuts clips out of it.
private struct SampleFixture {
    let root: URL
    let audio: URL
    let callID = CallID(rawValue: UUID())
    let builder: SpeakerSampleBuilder
    private let ffmpeg = URL(filePath: "/opt/homebrew/bin/ffmpeg")
    private let ffprobe = URL(filePath: "/opt/homebrew/bin/ffprobe")

    /// - Parameter lengths: One entry per part, named "silence" or "tone".
    init(lengths: [(kind: String, seconds: Int)]) throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "speaker-sample-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        audio = root.appending(path: "system-001.m4a")
        builder = SpeakerSampleBuilder(
            ffmpeg: URL(filePath: "/opt/homebrew/bin/ffmpeg"),
            ffprobe: URL(filePath: "/opt/homebrew/bin/ffprobe"),
            directory: root.appending(path: "clips", directoryHint: .isDirectory)
        )

        // One file per part, then one concatenation, because the tone and the room tone come from
        // different generators.
        var list = ""
        for (index, part) in lengths.enumerated() {
            let source = part.kind == "silence"
                ? "anullsrc=r=44100:cl=mono:d=\(part.seconds)"
                : "sine=frequency=440:duration=\(part.seconds)"
            let file = root.appending(path: "part-\(index).m4a")
            _ = try ProcessRunner.runChecked(
                executable: ffmpeg,
                arguments: [
                    "-v", "error", "-y",
                    "-f", "lavfi", "-i", source,
                    "-c:a", "aac", "-b:a", "96k",
                    file.path,
                ]
            )
            list += "file '" + file.path + "'\n"
        }
        let listURL = root.appending(path: "parts.txt")
        try Data(list.utf8).write(to: listURL)
        _ = try ProcessRunner.runChecked(
            executable: ffmpeg,
            arguments: [
                "-v", "error", "-y",
                "-f", "concat", "-safe", "0", "-i", listURL.path,
                "-c", "copy",
                audio.path,
            ]
        )
    }

    func duration(of url: URL) throws -> Double {
        let result = try ProcessRunner.runChecked(
            executable: ffprobe,
            arguments: [
                "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", url.path,
            ]
        )
        return Double(result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}
