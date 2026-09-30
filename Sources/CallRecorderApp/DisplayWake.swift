import Foundation
import IOKit.pwr_mgt

/// Asks the screen back, the way a key press does.
///
/// ScreenCaptureKit answers with no display at all when the display is asleep or off, and a capture
/// cannot start without one. Nothing but the user's own activity brings the screen back, and the
/// system counts this declaration as that activity: on 2026-09-28 at 17:04 an automatic recording
/// was refused with `noDisplay` because the screen had gone to sleep beside a running call, and the
/// call was not recorded. The declaration below is the difference between a recorded call and a
/// missing one.
enum DisplayWake {
    /// What the power log shows beside the declaration.
    static let reason = "Call Recorder is starting a recording"

    /// Declares that the user is active, which brings a sleeping display back.
    ///
    /// The declaration is an assertion the caller holds and releases, so the screen has the seconds
    /// it needs to come back. A Mac that refuses it answers nil, which is not a fault: the start
    /// then reports what it saw, exactly as it did before this existed.
    static func declareUserActivity() -> IOPMAssertionID? {
        var assertion: IOPMAssertionID = 0
        let result = IOPMAssertionDeclareUserActivity(
            reason as CFString,
            kIOPMUserActiveLocal,
            &assertion
        )
        guard result == kIOReturnSuccess, assertion != 0 else { return nil }
        return assertion
    }

    /// Ends a declaration this app made. A nil one is nothing to end.
    static func release(_ assertion: IOPMAssertionID?) {
        guard let assertion else { return }
        IOPMAssertionRelease(assertion)
    }
}
