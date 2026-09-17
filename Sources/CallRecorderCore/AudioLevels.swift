import Foundation

/// How loud a piece of audio is, and what counts as somebody speaking.
///
/// The number here is a single threshold, so it has to be one a quiet room and a quiet speaker
/// both stay on the right side of. It was measured on four recordings in the library before it was
/// chosen, window by window, at the level a buffer arrives at.
public enum AudioLevels {
    /// The peak level at or above which a buffer counts as speech.
    ///
    /// -50 dBFS, where zero is the loudest a sample can be. Measured on the four recordings: the
    /// room tone of a microphone in a room where nobody is speaking sits at -66 to -71 dBFS in one
    /// recording and at -53 in another, while speech peaks in the quietest of them reach -42 and in
    /// the loudest -16. The threshold sits between the two bands with about 8 dB on either side.
    ///
    /// Eight decibels is not much, which is why the rule that reads this is written to fail open:
    /// it asks for a long silence, it only applies to a recording the app started by itself, and it
    /// does nothing at all when the level could not be measured.
    public static let speechThresholdDecibels: Double = -50

    /// The loudness of a peak amplitude, in decibels relative to full scale.
    ///
    /// Digital silence has no decibel value at all, and is reported as negative infinity rather
    /// than as a number a caller might compare against.
    public static func decibels(peak: Float) -> Double {
        let magnitude = Double(abs(peak))
        guard magnitude > 0 else { return -.infinity }
        return 20 * log10(magnitude)
    }

    /// Whether a buffer is loud enough to be somebody speaking.
    public static func isSpeech(
        peak: Float,
        thresholdDecibels: Double = speechThresholdDecibels
    ) -> Bool {
        decibels(peak: peak) >= thresholdDecibels
    }
}
