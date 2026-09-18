import Foundation

/// The version of the llama.cpp server that writes call briefs.
///
/// Like the transcriber, it is not shipped inside the app: it is found on PATH and Homebrew
/// updates it on its own. The version decides how a model is loaded and what the server accepts,
/// so the settings window says which one is in use rather than leaving a failure to be explained
/// by an error message later.
public enum LlamaServerVersion {
    /// Reads the version out of the server's own output.
    ///
    /// The tool answers `--version` with a line like "version: 0.4.1 (build 10964, commit b3293)"
    /// followed by the compiler it was built with. The first word after the label is the version;
    /// the rest is build detail that changes more often than the version it belongs to.
    public static func parse(_ output: String) -> String? {
        for line in output.split(separator: "\n") {
            guard let range = line.range(of: "version:") else { continue }
            var value = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
            if let bracket = value.firstIndex(where: { $0 == "(" || $0 == " " }) {
                value = String(value[..<bracket])
            }
            guard !value.isEmpty else { continue }
            return value
        }
        return nil
    }

    /// Reads the version out of a Homebrew install path.
    ///
    ///     /opt/homebrew/Cellar/llama.cpp/0.4.1/bin/llama-server  ->  0.4.1
    ///
    /// The same reason the transcriber's version is read this way: it answers at once, so the row
    /// has something to show before the tool has been run at all.
    public static func fromInstallPath(_ url: URL) -> String? {
        let components = url.resolvingSymlinksInPath().pathComponents
        guard let index = components.lastIndex(of: "llama.cpp"), index + 1 < components.count
        else { return nil }
        let candidate = components[index + 1]
        guard candidate.first?.isNumber == true, candidate.contains(".") else { return nil }
        return candidate
    }

    /// Runs the tool and reads the version it reports.
    public static func read(from executable: URL) -> String? {
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
