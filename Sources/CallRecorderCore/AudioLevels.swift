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

    /// The quietest level a level meter draws, and the loudest.
    ///
    /// A meter that ran from digital silence to a clipped sample would spend its top three quarters
    /// on levels no microphone delivers and press the room tone and a voice into the first
    /// centimetre of the bar. The floor is below the room tone measured on the four recordings
    /// (-66 to -71 dBFS in one of them) and the ceiling is where speech peaks in the loudest of
    /// them (-16), so a bar at either end of its travel means something a person can act on: the
    /// microphone is hearing nothing at all, or it is hearing somebody clearly.
    public static let meterFloorDecibels: Double = -60
    public static let meterCeilingDecibels: Double = -6

    /// Where a level sits on a meter, from 0 at the floor to 1 at the ceiling.
    ///
    /// Digital silence has no decibel value and is drawn at the floor, which is where a stopped
    /// microphone belongs. A level outside the two ends is clamped rather than drawn past the end
    /// of the bar.
    public static func meterFraction(
        decibels: Double,
        floor: Double = meterFloorDecibels,
        ceiling: Double = meterCeilingDecibels
    ) -> Double {
        guard ceiling > floor else { return 1 }
        guard decibels.isFinite else { return decibels > 0 ? 1 : 0 }
        return min(1, max(0, (decibels - floor) / (ceiling - floor)))
    }
}
