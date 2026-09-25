import Darwin
import Foundation

/// Ends a model server an earlier build left behind.
///
/// The live transcript ran `whisper-server` and the brief ran `llama-server`, each as a child of
/// this app holding gigabytes of model. This build starts neither, so nothing is ended on quit: what
/// is left is a process from a build that crashed or that leaked, and it holds its model and its
/// port until the machine restarts or somebody notices. On 2026-09-25 a `llama-server` holding the
/// brief model was measured at 9 GB of footprint and still growing, on a Mac that was already
/// swapping, which is what this sweep exists to prevent.
///
/// Only those two programs are matched, and only when the command line names this app's own model
/// folder, so nothing else on the machine is touched.
enum OrphanedModelServers {
    static func endLeftovers(modelsDirectory: URL) {
        let folder = NSRegularExpression.escapedPattern(for: modelsDirectory.path)
        for program in ["whisper-server", "llama-server"] {
            for pid in processIdentifiers(matching: program + ".*" + folder) {
                kill(pid, SIGTERM)
            }
        }
    }

    private static func processIdentifiers(matching pattern: String) -> [pid_t] {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/pgrep")
        process.arguments = ["-f", pattern]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(whereSeparator: { $0.isNewline })
            .compactMap { pid_t($0) }
            .filter { $0 != getpid() }
    }
}
