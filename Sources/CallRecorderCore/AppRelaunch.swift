import Foundation

/// Opens the app again once it has gone away.
///
/// A newer version takes the place of the running one at quit, which is the one moment nothing is
/// using the bundle. Asking for that version now is therefore a quit with an open after it, and the
/// open has to come from outside the app: nothing of the app is left when it is time to run it. A
/// short shell waits for this process to disappear and then asks the system to open the app again.
///
/// The path travels in the environment rather than in the script's text. An application can sit at
/// any path a person chose, with spaces, quotes, or a `$` in it, and nothing here should have to be
/// right about quoting one.
public enum AppRelaunch {
    /// The variable the waiting shell reads the application path from.
    public static let applicationPathVariable = "CALL_RECORDER_RELAUNCH_APP"

    /// The variable the waiting shell appends its own trouble to, so a relaunch that failed leaves
    /// a line where the app's other update trouble is already read.
    public static let logPathVariable = "CALL_RECORDER_RELAUNCH_LOG"

    /// How long the shell waits between looks at the process table.
    static let pollSeconds = 0.2

    /// The shell that waits for a process to end and then opens the app again.
    ///
    /// The wait is what makes the open safe rather than the pause after it: the swap runs while the
    /// app is quitting, so a process that is gone is a bundle that has already been replaced. The
    /// pause is for the system's own bookkeeping, which still counts the app as running for a
    /// moment after it is not.
    public static func script(processID: Int32) -> String {
        """
        while /bin/kill -0 \(processID) 2>/dev/null; do /bin/sleep \(pollSeconds); done
        /bin/sleep 1
        if ! /usr/bin/open -a "$\(applicationPathVariable)"; then
          stamp="$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)"
          /bin/echo "$stamp app update: the app did not open again after the restart" >> "$\(logPathVariable)"
        fi
        """
    }

    /// Starts the shell that will open the app again, and reports whether it started.
    ///
    /// A shell that cannot be started leaves the app to be opened by hand, so the caller is told
    /// rather than left with a quit and nothing after it.
    @discardableResult
    public static func schedule(
        bundle: URL,
        log: URL,
        processID: Int32 = ProcessInfo.processInfo.processIdentifier,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        let shell = Process()
        shell.executableURL = URL(filePath: "/bin/sh")
        shell.arguments = ["-c", script(processID: processID)]
        var variables = environment
        variables[applicationPathVariable] = bundle.path
        variables[logPathVariable] = log.path
        shell.environment = variables
        // The shell outlives the app, so it may not hold anything the app owns. A pipe would fill
        // and stop the shell the moment nobody is reading it, and an inherited file would keep
        // whatever it points at open for as long as the wait lasts.
        shell.standardInput = FileHandle.nullDevice
        shell.standardOutput = FileHandle.nullDevice
        shell.standardError = FileHandle.nullDevice
        do {
            try shell.run()
            return true
        } catch {
            return false
        }
    }
}
