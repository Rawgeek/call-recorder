import Foundation

/// The rules that keep automatic recording from producing a recording nobody wanted.
///
/// Automatic recording watches the microphone, and the microphone is opened by more than meetings.
/// A voice memo, a dictation, and a system assistant all take it, and every one of them used to
/// start a call. The other direction is worse: a call app can hold the microphone open after the
/// meeting ends, and a recorder that only stops when the microphone goes quiet records the empty
/// room. One known library recorded fifteen hours that way, in three recordings nobody asked for.
///
/// Three rules answer that, and each one is a backstop rather than a feature: a recording shorter
/// than the floor is thrown away, a recording longer than the ceiling is stopped, and an app that
/// is not a meeting never starts one. A recording a person starts and stops by hand is untouched by
/// all three, because every one of them is a guess about intent and a button press is not.
public enum AutomaticRecordingRails {
    /// How long a recording has to last before it is worth transcribing.
    ///
    /// Thirty seconds. A call that matters is longer, and the recordings this drops are the ones
    /// that open the microphone for a second: an app checking for a device, a notification that
    /// plays a sound, a window that samples the input once. Transcription costs minutes of
    /// processor time and the audio costs disk, so a recording that short is work spent on nothing.
    public static let defaultMinimumSeconds: Double = 30

    /// How long a recording may run before it is stopped.
    ///
    /// Three hours. The longest meeting in the library is under two, and a recording that passes
    /// this is a microphone that was left open rather than a call that ran long.
    public static let defaultMaximumMinutes: Double = 180

    /// How long a recording may hold nothing but room tone before it is stopped.
    ///
    /// Ten minutes. A conversation has pauses, and a long one is somebody listening, but ten
    /// minutes of continuous silence on both the microphone and the system audio is a call that
    /// ended and left its app holding the microphone. The library holds one recording that ran for
    /// hours on exactly that, so the rule is the backstop under the ceiling rather than a
    /// convenience.
    public static let defaultSilenceMinutes: Double = 10

    /// Whether a recording that has just stopped is too short to keep.
    ///
    /// A floor of zero turns the rule off, which is what a settings blob from before the rule
    /// means and what a person who wants every recording asks for.
    public static func isTooShort(
        recordedSeconds: TimeInterval,
        minimumSeconds: Double
    ) -> Bool {
        guard minimumSeconds > 0 else { return false }
        return recordedSeconds < minimumSeconds
    }

    /// Whether a recording has run long enough to be stopped.
    ///
    /// A ceiling of zero turns the rule off. The comparison is on the recorded time rather than on
    /// the wall clock, so a call that was paused for an hour is judged by what it holds.
    public static func hasReachedCeiling(
        recordedSeconds: TimeInterval,
        maximumMinutes: Double
    ) -> Bool {
        hasReached(recordedSeconds, minutes: maximumMinutes)
    }

    /// Whether a recording has been silent for long enough to be stopped.
    ///
    /// A limit of zero turns the rule off. The caller passes the silence it measured itself, and a
    /// rule with nothing to measure is a rule that does nothing: a measurement that could not be
    /// taken is not passed here as silence.
    public static func hasBeenSilent(
        silentFor: TimeInterval,
        maximumMinutes: Double
    ) -> Bool {
        hasReached(silentFor, minutes: maximumMinutes)
    }

    /// Whether a measurement has reached a limit given in minutes.
    ///
    /// A limit of zero is not in force, which is what a settings blob from before a rail existed
    /// means and what a person who turned a rail off asks for. The ceiling and the silence rule
    /// read this, so "off" has one meaning rather than two.
    private static func hasReached(_ value: TimeInterval, minutes: Double) -> Bool {
        guard minutes > 0 else { return false }
        return value >= minutes * 60
    }

    // MARK: - What the switches write

    /// The floor, as the switch writes it: the standard floor when it is on, and zero when it is
    /// off.
    ///
    /// A rail has one setting rather than a flag beside a number, so the switch and the number can
    /// never disagree about whether the rail is on. Zero is already the documented meaning of "off",
    /// and the settings pane binds its switch to this.
    public static func floorForSwitch(_ isOn: Bool) -> Double {
        isOn ? defaultMinimumSeconds : 0
    }

    /// The ceiling, as the switch writes it, by the same rule.
    public static func ceilingForSwitch(_ isOn: Bool) -> Double {
        isOn ? defaultMaximumMinutes : 0
    }

    /// The silence limit, as the switch writes it, by the same rule.
    public static func silenceForSwitch(_ isOn: Bool) -> Double {
        isOn ? defaultSilenceMinutes : 0
    }
}

/// Apps that take the microphone and are not a meeting.
///
/// Matched by prefix rather than by equality, because an app that uses the microphone often does it
/// from a helper process: the identifier carries a suffix, and a list of exact identifiers would
/// miss the process that actually holds the device.
///
/// The list is deliberately short. A meetings app that is not on it starts a recording, which is
/// what the app is for and costs a click to stop; an app wrongly on it loses a meeting, which is
/// the failure that cannot be undone. Every entry here is a device the person is talking *to*: a
/// voice recorder, a dictation service, or an assistant. None of them is a conversation with
/// somebody else.
public enum NonCallMicrophoneApps {
    /// Bundle identifiers that never start a recording, matched by prefix and without case.
    public static let bundleIdentifierPrefixes: [String] = [
        // The voice recorder, which is what most of these false starts were.
        "com.apple.voicememos",
        // Siri and the assistant daemon behind it.
        "com.apple.siri",
        "com.apple.assistantd",
        "com.apple.assistantservices",
        // Dictation and the speech recognition service it runs in.
        "com.apple.speechrecognitioncore",
        "com.apple.coreembeddedspeechrecognition",
        "com.apple.dictation",
        // A song being identified is not a meeting either.
        "com.apple.shazam",
    ]

    /// Whether an app is one of the ones that never starts a recording.
    ///
    /// A process whose identifier could not be read is not ignored. That is the honest reading:
    /// nothing is known about it, and a missed meeting costs more than a recording that has to be
    /// discarded.
    public static func isIgnored(bundleID: String?) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return false }
        let lowered = bundleID.lowercased()
        return bundleIdentifierPrefixes.contains { lowered.hasPrefix($0) }
    }
}
