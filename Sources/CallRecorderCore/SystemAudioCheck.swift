import Foundation

/// Whether a call's other side was recorded, judged from the two source files.
///
/// A call made through another app arrives on two tracks: the microphone, and the system audio the
/// other app plays. One call in the library lost the second track without anything saying so. It
/// recorded 275 seconds of microphone at 24 KB a second and 150 KB of system audio, 546 bytes a
/// second, and the transcript that came out held one side of a conversation. Every call that kept
/// both sides writes kilobytes a second on each track, so the gap between the two files tells an
/// empty stream from a quiet room. The files exist while a call is transcribed and the cleanup
/// removes them afterwards, which is why the answer is measured then and written down.
public enum SystemAudioCheck {
    /// Below this, a track is the shell of one rather than audio.
    static let floorBytes = 64 * 1024

    /// The share of the microphone's bytes a system track has to reach to count as recorded.
    static let microphoneShare = 20

    /// The state the two track sizes describe, or nil when they cannot tell.
    ///
    /// Nil means unknown rather than fine: a call with no system track at all may be a call made
    /// with one source on purpose, and a call this short holds too little to judge.
    public static func state(microphoneBytes: Int?, systemBytes: Int?) -> SystemAudioState? {
        guard let microphoneBytes, microphoneBytes >= floorBytes else { return nil }
        guard let systemBytes else { return nil }
        return systemBytes < max(floorBytes, microphoneBytes / microphoneShare)
            ? .missing
            : .captured
    }

    /// Reads the finalized sources a call keeps beside its transcript.
    public static func state(in directory: URL) -> SystemAudioState? {
        state(
            microphoneBytes: size(of: directory.appending(path: "microphone.m4a")),
            systemBytes: size(of: directory.appending(path: "system.m4a"))
        )
    }

    private static func size(of url: URL) -> Int? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        return (attributes[.size] as? NSNumber)?.intValue
    }
}
