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

    /// The Silero VAD model, which the transcriber refuses to run without.
    ///
    /// The app downloads it now, so a Mac that has transcribed a call has the file and one that
    /// has never run the app has only the copy this checkout carries. The suite runs against
    /// whichever is there.
    static let hasVADModel: Bool =
        developmentVADModel != nil || (try? Transcriber.resolvedVADModel()) != nil

    /// The copy of the silence filter this checkout carries.
    ///
    /// The packaged app has no such file: the model is a download of under a megabyte. Tests that
    /// need real bytes rather than a recorded hash read this one.
    static let developmentVADModel: URL? = {
        let candidate = packageRoot.appending(path: "Resources/ggml-silero-v6.2.0.bin")
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }()

    /// The package this suite was built from, which the scripts it drives live in.
    static let packageRoot = URL(filePath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

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
