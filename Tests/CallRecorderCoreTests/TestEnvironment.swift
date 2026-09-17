import CallRecorderCore
import Foundation

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

    /// A system Python that can run a small script, which is what the speaker suite needs.
    static let hasSystemPython: Bool = {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/python3")
        process.arguments = ["-c", "print(1)"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }()
}

