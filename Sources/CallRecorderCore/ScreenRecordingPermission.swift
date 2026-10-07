import Foundation

/// What the app says about the one macOS permission it cannot work without.
///
/// System audio is captured through ScreenCaptureKit, and macOS gates that behind Screen
/// Recording. Without it the capture does not degrade: it throws, and what reaches the surface is
/// a ScreenCaptureKit error sentence that names no permission and no way to grant one. That is the
/// failure this app's user met first and most often, and the reason the sentence is written out
/// here rather than left to the framework.
///
/// The check is a preflight and not a request. `CGPreflightScreenCaptureAccess` reports what is
/// already true without raising a dialog, so the app can say what is wrong at launch. The prompt
/// itself only appears when macOS shows it, and the way out is System Settings, which the card
/// opens directly.
public enum ScreenRecordingPermission {
    /// The pane that holds the switch, so the button lands on the right screen.
    public static let settingsURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"

    /// The tool that forgets a permission record, and the arguments that forget this app's.
    ///
    /// A grant belongs to the exact copy of the app that asked for it. This app replaces itself
    /// when it updates, and a switch left on by the copy that is gone still reads as granted in
    /// System Settings while the copy that is running is denied: macOS answers its capture with
    /// "the user declined TCCs". The way out is to remove that record and ask again, which is
    /// what puts the running copy in the pane with a switch of its own.
    public static let resetExecutable = URL(filePath: "/usr/bin/tccutil")

    /// What clears the Screen Recording record this app's identifier holds.
    public static func resetArguments(bundleIdentifier: String) -> [String] {
        ["reset", "ScreenCapture", bundleIdentifier]
    }

    /// The one line a recording that could not start says, when the permission is the cause.
    ///
    /// The card above the recent list carries the instructions and the button. This is what the
    /// error line says, so a start that failed names the permission rather than the framework that
    /// found it missing.
    public static let refusal =
        "Screen Recording permission is off, so the other side of the call cannot be captured."

    /// What the surface says when the permission is not granted, or nothing when it is.
    ///
    /// Nothing is returned once the permission is held, because a card that stayed after the
    /// problem was solved would be noise on the surface the user opens most.
    ///
    /// The asked-again state is the card after the record was cleared and the permission
    /// requested afresh: what is left to do is turn the switch on, now that it is this copy's,
    /// and restart.
    public static func notice(
        granted: Bool,
        askedAgain: Bool = false
    ) -> (title: String, message: String)? {
        guard !granted else { return nil }
        guard !askedAgain else {
            return (
                "Screen Recording permission is needed",
                "The record macOS kept for an older copy of the app has been cleared, and this "
                    + "copy has asked again. Turn Call Recorder on in System Settings, Privacy and "
                    + "Security, Screen Recording — the switch there is this copy's now — then "
                    + "restart the app: macOS only reads the grant at launch."
            )
        }
        return (
            "Screen Recording permission is needed",
            "macOS gives no other way to capture the other side of a call, so a recording made "
                + "without it holds only your microphone. Turn Call Recorder on in System "
                + "Settings, Privacy and Security, Screen Recording, then start the app again. "
                + "macOS only reads the grant at launch, and it keeps that grant for the exact "
                + "copy of the app that asked for it: a switch that is already on after an update "
                + "belongs to a copy that is gone. Reset Permission clears that record and asks "
                + "again for this copy."
        )
    }
}
