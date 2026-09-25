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
    /// The app's own Application Support folder, where models are installed.
    static let applicationDirectory = FileManager.default
        .homeDirectoryForCurrentUser
        .appending(
            path: "Library/Application Support/CallRecorder",
            directoryHint: .isDirectory
        )
    /// The Python environment the app runs the transcription model in.
    static let speechRuntimePython: URL? = {
        guard let python = SpeechRuntimeRequirement.python(applicationDirectory: applicationDirectory),
            FileManager.default.isExecutableFile(atPath: python.path)
        else { return nil }
        let probe = SpeechRuntimeRequirement.modules.map { "import \($0)" }.joined(separator: "; ")
        guard
            let outcome = try? ProcessRunner.run(executable: python, arguments: ["-c", probe]),
            outcome.exitCode == 0
        else { return nil }
        return python
    }()
    /// The transcription model as the app installs it: the revision folder holding a config.
    static let transcriptionModel: URL? = {
        guard let model = SupportingModel.catalog.first(where: { $0.id == SupportingModel.qwen3ASRID })
        else { return nil }
        let root = model.repositoryDirectory(in: applicationDirectory)
        let revisions = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        )) ?? []
        return revisions.first {
            FileManager.default.fileExists(atPath: $0.appending(path: "config.json").path)
        }
    }()
    /// The speech synthesiser macOS ships. The engine suite uses it to make audio worth reading,
    /// so the test does not depend on somebody's recording being in the checkout.
    static let speechSynthesiser = URL(filePath: "/usr/bin/say")
    /// Whether the transcription model can be run on this Mac at all: an interpreter holding the
    /// two modules, the model's files, ffmpeg, and the synthesiser.
    static let canRunTranscriptionModel = hasFFmpeg
        && speechRuntimePython != nil
        && transcriptionModel != nil
        && FileManager.default.isExecutableFile(atPath: speechSynthesiser.path)

    /// A recording a run of the suite was told to read, when one was named.
    ///
    /// The engine suite makes its own speech, so it runs anywhere. Reading a call of the user's own
    /// is the check that measures a real meeting, and it is asked for by name:
    ///
    ///   CALL_RECORDER_TRANSCRIBE_AUDIO=/path/to/track.m4a swift test --filter RealCallTests
    ///
    /// A file that is not there is a failure rather than a skip, so a mistyped path is answered
    /// instead of passing quietly.
    static let namedRecording: URL? = ProcessInfo.processInfo
        .environment["CALL_RECORDER_TRANSCRIBE_AUDIO"]
        .map { URL(filePath: $0) }

    /// Whether this run was told to read a recording of its own.
    static let canReadNamedRecording = canRunTranscriptionModel && namedRecording != nil

    /// Whether the speaker script can run here: an interpreter that holds what `diarize.py` reads.
    ///
    /// The transcription modules are not the speaker ones. 0.1.33 reads a call with a package that
    /// the speaker separation does not use, and the environment both run in has to hold both.
    static let speakerRuntimePython: URL? = {
        guard let python = speechRuntimePython else { return nil }
        let probe = "import pyannote.audio, torch"
        guard
            let outcome = try? ProcessRunner.run(executable: python, arguments: ["-c", probe]),
            outcome.exitCode == 0
        else { return nil }
        return python
    }()

    /// The speaker script as the app wires it, from the checkout this suite was built from.
    static let diarizationScript: URL? = {
        let url = packageRoot.appending(path: "Sources/CallRecorderApp/diarize.py")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }()

    /// A recording a run was told to take a whole call from, when one was named.
    ///
    /// The engine suite reads a recording and measures it. This one drives the same recording
    /// through every stage a finished call takes, so it is asked for by name as well:
    ///
    ///   CALL_RECORDER_PIPELINE_AUDIO=/path/to/system.m4a swift test --filter RealPipelineTests
    static let pipelineRecording: URL? = ProcessInfo.processInfo
        .environment["CALL_RECORDER_PIPELINE_AUDIO"]
        .map { URL(filePath: $0) }

    /// Whether this run was told to take a whole call from a recording of its own.
    static let canRunWholePipeline = canRunTranscriptionModel
        && pipelineRecording != nil
        && speakerRuntimePython != nil
        && diarizationScript != nil
        && ToolLocator.standard.locate("ffprobe") != nil
}
