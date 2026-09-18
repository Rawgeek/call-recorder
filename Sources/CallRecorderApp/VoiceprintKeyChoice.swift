import CallRecorderCore
import Foundation

/// Where this run of the app keeps the key that opens stored voice profiles.
///
/// The installed app keeps it in the login keychain. A development run does not. The keychain
/// decides whether a program may read one of its items by the program's signature, and every
/// rebuild is a new program to it: the read then waits on a password dialog that says nothing about
/// what asked for it, and a build nobody is sitting in front of waits for an answer that never
/// comes. Those runs keep the key in a file only this account can read, inside the app's own
/// folder, and no dialog appears. Nothing that ships is one of those runs: the choice is the
/// keychain unless the environment asks for a file, the run is a layout render, or the binary was
/// built and started from the command line, which has no bundle identifier.
enum VoiceprintKeyChoice {
    /// The variable that names the store outright, for a run that needs the other one.
    static let environmentKey = "CALL_RECORDER_VOICEPRINT_KEY"

    static func resolve(
        environment: [String: String],
        isPreview: Bool,
        bundleIdentifier: String?,
        applicationDirectory: URL
    ) -> VoiceprintKeyLocation {
        let file = VoiceprintKeyLocation.fileSeededFromKeychain(
            VoiceprintKeyStore.fileLocation(inApplicationDirectory: applicationDirectory)
        )
        switch environment[environmentKey]?.lowercased() {
        case "keychain":
            return .keychain
        case "file":
            return file
        default:
            break
        }
        // A render never reaches the keychain, and neither does a binary run from the build
        // directory: it has no bundle to be recognised by.
        return isPreview || bundleIdentifier == nil ? file : .keychain
    }

    static func forThisRun(applicationDirectory: URL) -> VoiceprintKeyLocation {
        let environment = ProcessInfo.processInfo.environment
        return resolve(
            environment: environment,
            // The same flag the model reads, said here because this runs off the main actor.
            isPreview: environment["CALL_RECORDER_PREVIEW"] == "1",
            bundleIdentifier: Bundle.main.bundleIdentifier,
            applicationDirectory: applicationDirectory
        )
    }
}
