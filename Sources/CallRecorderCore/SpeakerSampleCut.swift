import Foundation

/// Describes the cut that turns one speaker-review excerpt into a clip of just its speech.
///
/// A diarized turn can open with seconds of room tone, and a review card is where a person
/// decides who a voice is: silence is the part nothing can be judged from. The command is built
/// here so it can be checked without running ffmpeg, and the app runs it.
public enum SpeakerSampleCut {
    /// Silence quieter than this is taken out. Quiet speech sits near −40 dB, so the threshold
    /// clears the room tone around a call without eating the words inside it.
    public static let thresholdDecibels = 40
    /// A pause has to last this long before any of it is removed.
    public static let pauseSeconds = 0.5
    /// What is kept of a pause that is removed, so a turn still sounds like a turn.
    public static let keptPauseSeconds = 0.3
    /// A cut shorter than this came back empty, and the caller falls back to the plain cut.
    public static let minimumSeconds = 0.4

    /// The filter that removes the silence.
    ///
    /// `silenceremove` only trims what it meets first, so the clip is filtered forward and then
    /// backward: the forward pass takes the leading silence and shortens the pauses inside the
    /// turn, and the reversed pass does the same to the tail.
    public static var silenceFilter: String {
        let pass =
            "silenceremove=start_periods=1:start_duration=0.1"
            + ":start_threshold=-\(thresholdDecibels)dB"
            + ":stop_periods=-1:stop_duration=\(pauseSeconds)"
            + ":stop_threshold=-\(thresholdDecibels)dB"
            + ":stop_silence=\(keptPauseSeconds)"
        return "\(pass),areverse,\(pass),areverse"
    }

    /// The command that writes the excerpt with its silence removed.
    public static func arguments(
        audio: URL,
        destination: URL,
        startMilliseconds: Int,
        endMilliseconds: Int
    ) -> [String] {
        var arguments = baseArguments(
            audio: audio,
            destination: destination,
            startMilliseconds: startMilliseconds,
            endMilliseconds: endMilliseconds
        )
        arguments.append(contentsOf: ["-af", silenceFilter])
        arguments.append(contentsOf: encodingArguments)
        arguments.append(destination.path)
        return arguments
    }

    /// The command that writes the excerpt as it stands, for a clip the filter emptied out.
    public static func plainArguments(
        audio: URL,
        destination: URL,
        startMilliseconds: Int,
        endMilliseconds: Int
    ) -> [String] {
        baseArguments(
            audio: audio,
            destination: destination,
            startMilliseconds: startMilliseconds,
            endMilliseconds: endMilliseconds
        ) + encodingArguments + [destination.path]
    }

    private static func baseArguments(
        audio: URL,
        destination: URL,
        startMilliseconds: Int,
        endMilliseconds: Int
    ) -> [String] {
        let start = Double(startMilliseconds) / 1_000
        let duration = Double(max(0, endMilliseconds - startMilliseconds)) / 1_000
        return [
            "-v", "error", "-y",
            // Seeking before the input is the fast path, and the excerpt is short enough for its
            // accuracy to be irrelevant at this length.
            "-ss", String(format: "%.3f", start),
            "-t", String(format: "%.3f", duration),
            "-i", audio.path,
            "-map", "0:a:0",
        ]
    }

    private static let encodingArguments = ["-c:a", "aac", "-b:a", "96k"]
}
