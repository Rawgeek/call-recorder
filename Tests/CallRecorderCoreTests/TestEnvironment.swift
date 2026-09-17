import CallRecorderCore
import Foundation
@testable import CallRecorderApp

/// External tools some suites drive.
///
/// A few tests exercise the real capture and transcription path, which runs ffmpeg, ffprobe,
/// and a Python speaker script. A machine without those tools cannot run them, and without a
/// gate a missing tool would read as a failing feature. Each condition is evaluated once.
enum TestEnvironment {
    /// ffmpeg and ffprobe, the pair capture finalization runs.
    static let hasFFmpeg: Bool = {
        let locator = ToolLocator.standard
        return locator.locate("ffmpeg") != nil && locator.locate("ffprobe") != nil
    }()

    /// The bundled Silero VAD model, which the transcriber refuses to run without.
    static let hasBundledVADModel: Bool = (try? Transcriber.resolvedVADModel()) != nil

    /// Whether the machine is a desktop rather than a CI image.
    ///
    /// The speaker suite runs a real Python interpreter and waits on its standard output. On a
    /// CI image the interpreter is present but its pipes behave differently, so the suite is
    /// skipped there. The same behaviour is covered on any Mac, and by the app itself.
    static let canRunSpeakerScript = ProcessInfo.processInfo.environment["CI"] == nil

    /// Whether stopping a running command can be measured by wall-clock time here.
    ///
    /// The stop tests assert that a cancelled command ends within seconds. Delivering the
    /// signal needs threads to be free: on a small CI virtual machine the interpreter's pool is
    /// starved, and the assertion then measures the machine instead of the stop. The stop path
    /// itself is covered by the app on any desktop.
    static let canMeasureProcessStop = ProcessInfo.processInfo.environment["CI"] == nil
}
