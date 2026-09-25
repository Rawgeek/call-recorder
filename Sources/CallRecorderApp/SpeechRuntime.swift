import CallRecorderCore
import Foundation
import Observation

/// What the speech runtime needs from a Python environment, and where it looks for one.
enum SpeechRuntimeRequirement {
    /// The modules the transcription script imports.
    static let modules = ["mlx", "mlx_audio"]
    /// What pip is asked for when they are missing, pinned to the versions this app was tested
    /// against.
    ///
    /// The script calls into `mlx_audio` for the model, the audio, and the pieces it answers with,
    /// and that library is under active development: its token budget is what lost a long call its
    /// second half before this app read the audio in pieces of its own. A version that changes the
    /// shape of an answer would change what a transcript says without this app changing at all, so
    /// the versions are pinned here and move when the app does.
    static let packages = ["mlx==0.32.2", "mlx-audio==0.5.6"]

    /// The versions those pins name, keyed by distribution name.
    ///
    /// Read out of the pins rather than written again, so a pin and the check that the installed
    /// copy matches it cannot drift apart. A pin that names no version is skipped: it asks for the
    /// library, not for one of its releases, and nothing there can be mismatched.
    static let expectedVersions: [String: String] = {
        var versions: [String: String] = [:]
        for pin in packages {
            let parts = pin.split(separator: "==", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            versions[distributionKey(parts[0])] = parts[1]
        }
        return versions
    }()

    /// A distribution name with the spellings pip and its metadata disagree about folded together.
    ///
    /// The same distribution is written `mlx-audio` in a pin and `mlx_audio` in its metadata, and
    /// a check that treated those as two names would report every environment as mismatched.
    static func distributionKey(_ name: String) -> String {
        name.lowercased().replacingOccurrences(of: "_", with: "-").replacingOccurrences(of: ".", with: "-")
    }

    /// The interpreter the app runs the speaker analysis and the transcription script with.
    ///
    /// One environment serves both, because both are the same kind of dependency: a Python module
    /// the app does not ship. The managed one is written beside the models; a person who keeps
    /// theirs somewhere else names it, and the app uses that instead.
    static func python(
        applicationDirectory: URL,
        defaults: UserDefaults = .standard
    ) -> URL? {
        configured(defaults: defaults) ?? managed(applicationDirectory: applicationDirectory)
    }

    /// The environment the app keeps beside its models, which it may create when it is missing.
    static func managed(applicationDirectory: URL) -> URL {
        applicationDirectory.appending(path: "python/bin/python3")
    }

    /// The interpreter a person named, in the speaker setup, for both jobs the app runs in Python.
    static func configured(
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        (defaults.string(forKey: "speaker-python") ?? environment["CALL_RECORDER_PYTHON"])
            .map { URL(filePath: $0) }
    }
}

/// Finds a Python on this Mac that can build the environment the model runs in.
///
/// The app carries no interpreter: it is four hundred megabytes, and the one a Mac already has is
/// the one to use. Two things have to be true of it. It has to be here, and it has to be 3.10 or
/// newer, which is what mlx and its audio library ask for; a Mac's own /usr/bin/python3 is older
/// than that, so the candidates are tried in order and the first that answers is the one used.
enum SpeechEnvironmentInterpreter {
    /// The interpreters to try, in the order they are preferred: a Homebrew Python first, because
    /// it is the one a person on this app's requirements list already installed.
    static let candidates = [
        "/opt/homebrew/bin/python3",
        "/usr/local/bin/python3",
        "/usr/bin/python3",
    ]

    /// The oldest interpreter the packages are published for.
    static let minimumVersion = (major: 3, minor: 10)

    /// The first interpreter that is here and new enough, or nil when none is.
    ///
    /// `probe` answers whether a named interpreter is new enough, so the search can be checked
    /// without a Mac holding every version.
    static func base(
        candidates: [String] = SpeechEnvironmentInterpreter.candidates,
        isExecutable: (URL) -> Bool = { FileManager.default.isExecutableFile(atPath: $0.path) },
        probe: (URL) -> Bool = SpeechEnvironmentInterpreter.isNewEnough
    ) -> URL? {
        for candidate in candidates {
            let url = URL(filePath: candidate)
            guard isExecutable(url) else { continue }
            if probe(url) { return url }
        }
        return nil
    }

    /// Whether the interpreter reports a version the packages can be installed into.
    static func isNewEnough(_ python: URL) -> Bool {
        let script =
            "import sys; print(sys.version_info >= (\(minimumVersion.major), \(minimumVersion.minor)))"
        guard
            let outcome = try? ProcessRunner.run(executable: python, arguments: ["-c", script]),
            outcome.exitCode == 0
        else { return false }
        return outcome.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) == "True"
    }
}

/// The Python environment the transcription model runs in.
///
/// The published weights run on MLX, which is a Python library rather than something this app can
/// link, so the app keeps an interpreter and two packages beside its models. The row that reports
/// this is the one place a person is told what is missing and given the button that fetches it:
/// the packages are a few hundred megabytes, and installing them without being asked would be a
/// download nobody agreed to.
@MainActor
@Observable
final class SpeechRuntime {
    enum State: Equatable {
        /// No interpreter was found where the app looks for one.
        case noPython
        /// An interpreter is here, but the modules are not.
        case missingModules
        /// The modules are here, at versions other than the ones this build reads with.
        case otherVersions(installed: [String: String])
        case installing
        case ready
        case failed(String)

        /// Whether a call can be read with what is here.
        ///
        /// Only the pinned versions count. A newer library is not ready: its answer is what a
        /// transcript is built from, and an answer whose shape changed would change a call's words
        /// without this app changing at all. The row says which versions are here and offers to
        /// put the pinned ones back.
        var isReady: Bool { self == .ready }
    }

    private(set) var state: State = .noPython
    /// 0 to 1 while pip runs, or nil when pip says nothing about how far along it is.
    private(set) var progress: Double?
    /// The last thing pip said, so a row can show the work rather than a spinner.
    private(set) var status: String?

    private(set) var python: URL?
    /// The environment the app keeps beside its models, which it may build when it is missing.
    private let managedPython: URL?
    private var work: Task<Void, Never>?

    init(python: URL?, managedPython: URL? = nil) {
        self.python = python
        self.managedPython = managedPython
        refresh()
    }

    /// Moves the runtime onto another environment.
    ///
    /// Choosing an environment in Speaker setup is a choice about both jobs the app runs in Python,
    /// so the row has to report the one that was chosen rather than the one this launch started
    /// with. The state goes back to the start so a row cannot show the old environment's answer
    /// while the new one is being read.
    func use(python: URL?) {
        self.python = python
        state = .noPython
        refresh()
    }

    /// Whether the interpreter this run looks for is the app's own, and may be built.
    ///
    /// An interpreter a person named is not: writing an environment at a path they chose, without
    /// asking, would put hundreds of megabytes somewhere they did not agree to. The distinction is
    /// what the row's button does — set the app's own environment up, or say that the chosen one is
    /// gone.
    var canBuildEnvironment: Bool {
        guard let managedPython, let python else { return false }
        return python.path == managedPython.path
    }

    /// Whether the environment can import what the script imports.
    func refresh() {
        guard let python, FileManager.default.isExecutableFile(atPath: python.path) else {
            state = .noPython
            return
        }
        if work != nil { return }
        work = Task { [weak self] in
            let result = await Task.detached { () -> State in
                SpeechRuntime.probe(python: python)
            }.value
            guard let self else { return }
            self.work = nil
            self.state = result
        }
    }

    /// Runs the interpreter and reports what it holds.
    ///
    /// Two questions, in one launch: can the modules be imported at all, and are they the versions
    /// this build reads with. The second is asked because the first is not enough to trust a
    /// reading: a library that installs cleanly and answers differently would change a call's
    /// words, and nothing else in the app would notice.
    nonisolated static func probe(python: URL) -> State {
        let imports = SpeechRuntimeRequirement.modules.map { "import \($0)" }.joined(separator: "; ")
        guard
            let outcome = try? ProcessRunner.run(executable: python, arguments: ["-c", imports]),
            outcome.exitCode == 0
        else { return .missingModules }

        let names = SpeechRuntimeRequirement.expectedVersions.keys.sorted()
            .map { "'\($0)'" }
            .joined(separator: ", ")
        // A distribution with no metadata answers null rather than failing the run: a library
        // installed from a source tree imports while its name is unknown, and an environment that
        // can read a call is not worth calling broken over a version nobody wrote down.
        let script = """
        import importlib.metadata as md, json
        found = {}
        for name in [\(names)]:
            try:
                found[name] = md.version(name)
            except Exception:
                found[name] = None
        print(json.dumps(found))
        """
        guard
            let versions = try? ProcessRunner.run(executable: python, arguments: ["-c", script]),
            versions.exitCode == 0,
            let data = versions.standardOutput.data(using: .utf8),
            let installed = try? JSONDecoder().decode([String: String?].self, from: data)
        else { return .ready }
        for (name, expected) in SpeechRuntimeRequirement.expectedVersions {
            let key = SpeechRuntimeRequirement.distributionKey(name)
            let entry = installed.first { SpeechRuntimeRequirement.distributionKey($0.key) == key }
            guard let found = entry?.value ?? nil else { continue }
            if found != expected {
                return .otherVersions(installed: [name: found])
            }
        }
        return .ready
    }

    /// Builds the environment when there is none, then installs the modules with its pip.
    ///
    /// The environment is made by the first Python on this Mac that is new enough, and it lives
    /// beside the models, so the app has one of its own to install into. pip is asked for the pinned
    /// versions, so this both installs what is missing and puts back what has been replaced since.
    /// The output is read as it arrives, because a few hundred megabytes is minutes of work and a
    /// spinner with no end in sight is not a report.
    func install() {
        guard let python, work == nil, !state.isReady else { return }
        state = .installing
        progress = nil
        status = "Starting"
        work = Task { [weak self] in
            guard let self else { return }
            let canBuild = self.canBuildEnvironment
            let outcome = await Task.detached { () -> SpeechRuntimeInstaller.Outcome in
                let report: @Sendable (String) -> Void = { line in
                    Task { @MainActor in self.read(line) }
                }
                if !FileManager.default.isExecutableFile(atPath: python.path) {
                    guard canBuild, let base = SpeechEnvironmentInterpreter.base() else {
                        return .failure(SpeechRuntime.missingInterpreterMessage(canBuild: canBuild))
                    }
                    switch SpeechRuntimeInstaller.createEnvironment(
                        python: python,
                        base: base,
                        onLine: report
                    ) {
                    case .success:
                        break
                    case .failure(let message):
                        return .failure(message)
                    }
                }
                return SpeechRuntimeInstaller.run(python: python, onLine: report)
            }.value
            self.work = nil
            switch outcome {
            case .success:
                // Asked again rather than assumed: what pip was told to install and what is now
                // importable at the pinned versions are two different things, and the row has to
                // report the second one.
                self.state = await Task.detached { SpeechRuntime.probe(python: python) }.value
                self.progress = 1
                self.status = "Installed"
            case .failure(let message):
                self.state = .failed(message)
                self.progress = nil
            }
        }
    }

    /// What a person is told when the app has no interpreter to install into.
    nonisolated static func missingInterpreterMessage(canBuild: Bool) -> String {
        canBuild
            ? "No Python \(SpeechEnvironmentInterpreter.minimumVersion.major)."
                + "\(SpeechEnvironmentInterpreter.minimumVersion.minor) or newer was found on this "
                + "Mac, and the transcription model needs one. Install Python from python.org or "
                + "with Homebrew, then try again."
            : "The Python environment chosen in Speaker setup is not there. Choose another in "
                + "Review Speakers, Speaker setup."
    }

    /// Turns one line of pip output into progress, when the line carries a number.
    private func read(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        status = trimmed
        if let percent = SpeechRuntime.percent(in: trimmed) {
            progress = percent
        }
    }

    /// The share pip reports, read out of a line like "Downloading mlx-0.32.2 (150.4 MB)".
    static func percent(in line: String) -> Double? {
        guard let match = line.firstMatch(of: /([0-9]{1,3})%/) else { return nil }
        guard let value = Double(match.1) else { return nil }
        return min(1, max(0, value / 100))
    }

}

/// The last lines of pip's output, kept so a failure can say what it was.
private final class PipOutputTail: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) {
        lock.lock()
        lines.append(line)
        if lines.count > 12 {
            lines.removeFirst(lines.count - 12)
        }
        lock.unlock()
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return lines.joined(separator: "\n")
    }
}

/// Runs pip for the speech runtime, outside the main actor and outside the class that owns it.
private enum SpeechRuntimeInstaller {
    enum Outcome: Sendable {
        case success
        case failure(String)
    }

    /// Makes the environment, with the interpreter's own venv module.
    ///
    /// The folder is the one the app looks for its interpreter in, which is why the environment is
    /// not created anywhere else: the path and the search have to agree, or a finished install
    /// would still read as missing.
    static func createEnvironment(
        python: URL,
        base: URL,
        onLine: @escaping @Sendable (String) -> Void
    ) -> Outcome {
        let directory = python.deletingLastPathComponent().deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return .failure("The environment folder could not be made: \(error.localizedDescription)")
        }
        onLine("Creating the Python environment with \(base.path)")
        do {
            let outcome = try ProcessRunner.run(
                executable: base,
                arguments: ["-m", "venv", directory.path]
            )
            guard outcome.exitCode == 0 else {
                return .failure(tail(of: outcome.standardError, or: "venv exited with code \(outcome.exitCode)"))
            }
        } catch {
            return .failure("The Python environment could not be created: \(error.localizedDescription)")
        }
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            return .failure("The environment was made without an interpreter at \(python.path).")
        }
        return .success
    }

    /// The last of what a command said, which is the part that names the fault.
    static func tail(of text: String, or fallback: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        return String(trimmed.suffix(600))
    }

    static func run(
        python: URL,
        onLine: @escaping @Sendable (String) -> Void
    ) -> Outcome {
        let process = Process()
        process.executableURL = python
        process.arguments = ["-m", "pip", "install", "--upgrade"] + SpeechRuntimeRequirement.packages
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let said = PipOutputTail()
        let handle: @Sendable (Data) -> Void = { data in
            guard let text = String(data: data, encoding: .utf8) else { return }
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                let trimmed = String(line)
                onLine(trimmed)
                said.append(trimmed)
            }
        }
        pipe.fileHandleForReading.readabilityHandler = { fileHandle in
            let data = fileHandle.availableData
            if data.isEmpty { return }
            handle(data)
        }
        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            return .failure(error.localizedDescription)
        }
        process.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil
        let rest = pipe.fileHandleForReading.readDataToEndOfFile()
        if !rest.isEmpty { handle(rest) }
        guard process.terminationStatus == 0 else {
            return .failure(
                tail(of: said.text, or: "pip exited with code \(process.terminationStatus)")
            )
        }
        return .success
    }
}
