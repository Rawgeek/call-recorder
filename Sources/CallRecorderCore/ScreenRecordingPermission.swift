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

    /// What the surface says when the permission is not granted, or nothing when it is.
    ///
    /// Nothing is returned once the permission is held, because a card that stayed after the
    /// problem was solved would be noise on the surface the user opens most.
    public static func notice(granted: Bool) -> (title: String, message: String)? {
        guard !granted else { return nil }
        return (
            "Screen Recording permission is needed",
            "macOS gives no other way to capture the other side of a call, so a recording made "
                + "without it holds only your microphone. Turn Call Recorder on in System "
                + "Settings, Privacy and Security, Screen Recording, then start the app again. "
                + "macOS only reads the grant at launch."
        )
    }
}
