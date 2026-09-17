import Foundation

/// The version of the whisper.cpp command line tool that Call Recorder transcribes with.
///
/// The tool is not shipped inside the app. It is found on PATH, which in practice means Homebrew,
/// so the version in use is the version that tool was installed at and it changes without the app
/// changing. Reading it is how the settings window can say which engine transcribed a call.
public enum WhisperCLIVersion {
    /// Reads the version out of the tool's own output.
    ///
    /// The tool prints backend initialisation to the same streams as its version line, so the line
    /// is found by its label rather than by position.
    public static func parse(_ output: String) -> String? {
        let newline = Character("\n")
        for line in output.split(separator: newline) {
            guard let range = line.range(of: "whisper.cpp version:") else { continue }
            let value = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }
            return value
        }
        return nil
    }

    /// Reads the version out of a Homebrew install path.
    ///
    ///     /opt/homebrew/Cellar/whisper.cpp/1.9.1/bin/whisper-cli  ->  1.9.1
    ///
    /// Asking the tool itself costs a process and loads its graphics back end, which took seconds
    /// for a string already written in the path. This answers at once, and the reading below
    /// replaces it when the tool has answered.
    public static func fromInstallPath(_ url: URL) -> String? {
        let components = url.resolvingSymlinksInPath().pathComponents
        guard let index = components.lastIndex(of: "whisper.cpp"), index + 1 < components.count
        else { return nil }
        let candidate = components[index + 1]
        // A source build sits in a folder called whisper.cpp too, and the component after it is
        // then a directory of sources rather than a version.
        guard candidate.first?.isNumber == true, candidate.contains(".") else { return nil }
        return candidate
    }

    /// Runs the tool and reads the version it reports.
    ///
    /// Starting the tool loads its graphics back end, which took fourteen seconds the first time
    /// on this machine. Call this off the main thread, once, and keep the answer.
    public static func read(from executable: URL) -> String? {
        // Older builds answer only the second form, and both are cheap once the back end is up.
        for arguments in [["--version"], ["--help"]] {
            guard let result = try? ProcessRunner.run(executable: executable, arguments: arguments)
            else { continue }
            if let version = parse(result.standardOutput) ?? parse(result.standardError) {
                return version
            }
        }
        return nil
    }
}
