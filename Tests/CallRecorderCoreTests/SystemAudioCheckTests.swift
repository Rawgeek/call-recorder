import CallRecorderCore
import Foundation
import Testing

@Suite("System audio check")
struct SystemAudioCheckTests {
    @Test("the call that lost its other side is named from its two tracks")
    func theAuditedCallIsMissing() {
        // The call of 17 September at 13:13 wrote 6.6 MB through the microphone and 150 KB
        // through the system track: 24,196 bytes a second against 546.
        #expect(
            SystemAudioCheck.state(microphoneBytes: 6_600_000, systemBytes: 150_000) == .missing
        )
    }

    @Test("a call that kept both sides is not flagged")
    func healthyCallIsCaptured() {
        // The calls still on disk write kilobytes a second on the system track.
        #expect(
            SystemAudioCheck.state(microphoneBytes: 21_000_000, systemBytes: 19_000_000) == .captured
        )
        #expect(
            SystemAudioCheck.state(microphoneBytes: 6_600_000, systemBytes: 4_000_000) == .captured
        )
    }

    @Test("a call with no system track at all is unknown, not a warning")
    func absentTrackIsUnknown() {
        // A call made with one source on purpose looks the same here as a call whose second track
        // was never written, so this check has nothing to say about it.
        #expect(SystemAudioCheck.state(microphoneBytes: 6_600_000, systemBytes: nil) == nil)
    }

    @Test("a call too short to judge is unknown")
    func shortCallIsUnknown() {
        #expect(SystemAudioCheck.state(microphoneBytes: 40_000, systemBytes: 1_000) == nil)
        #expect(SystemAudioCheck.state(microphoneBytes: nil, systemBytes: 4_000_000) == nil)
    }

    @Test("the two source files are read by name from the call's own folder")
    func readsTheFinalizedSources() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "system-audio-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(repeating: 0, count: 600_000)
            .write(to: directory.appending(path: "microphone.m4a"))
        try Data(repeating: 0, count: 2_000)
            .write(to: directory.appending(path: "system.m4a"))

        #expect(SystemAudioCheck.state(in: directory) == .missing)
    }
}
