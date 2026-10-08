import Foundation

/// What the app says when macOS has not granted the microphone.
///
/// Without the grant a recording does not fail. ScreenCaptureKit starts, the call's system audio
/// arrives, and the microphone track is simply empty: the file plays, the transcript is written,
/// and every word the person said is missing from both. Measured on this Mac on 2026-10-08, no
/// recording in the library holds a microphone track at all, and nothing on any surface had said
/// so. The card is drawn only while a microphone is connected, because a Mac with no audio input
/// records the other side by design, and the setting that governs that is a separate choice.
public enum MicrophonePermission {
    /// The pane that holds the switch, so the button lands on the right screen.
    public static let settingsURL =
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"

    /// The tool that forgets a permission record, and the arguments that forget this app's.
    ///
    /// The same shape as the Screen Recording record: a grant belongs to the exact copy of the app
    /// that asked for it, and this app replaces itself when it updates. A switch that is already on
    /// can belong to the copy that is gone, and the copy that is running is then refused in
    /// silence. Clearing the record is what puts the running copy in the pane with a switch of its
    /// own.
    public static let resetExecutable = URL(filePath: "/usr/bin/tccutil")

    /// What clears the microphone record this app's identifier holds.
    public static func resetArguments(bundleIdentifier: String) -> [String] {
        ["reset", "Microphone", bundleIdentifier]
    }

    /// The card the popover draws while the microphone is not granted.
    ///
    /// It says what a recording made now will actually hold, because that is the part nobody can
    /// guess: the call is saved, it plays, and only the other side is on it.
    public static func notice() -> (title: String, message: String) {
        (
            "Your side is not being recorded",
            "macOS has not granted the microphone to Call Recorder, so a recording holds only the "
                + "other side of the call: your own voice is missing from the audio, the "
                + "transcript, and the timeline. Turn Call Recorder on in System Settings, Privacy "
                + "and Security, Microphone. macOS keeps that grant for the exact copy of the app "
                + "that asked for it, so a new build can leave it behind: Reset Permission clears "
                + "the record and asks again for this copy."
        )
    }
}

