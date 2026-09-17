public enum AudioActivityDecision {
    /// One process that holds the microphone, and what it is.
    public struct Input: Equatable, Sendable {
        public let processID: Int32
        /// The app's bundle identifier, when it could be read.
        public let bundleID: String?

        public init(processID: Int32, bundleID: String?) {
            self.processID = processID
            self.bundleID = bundleID
        }
    }

    /// Whether anything that is not this app, and not a device the person talks to, holds the
    /// microphone.
    ///
    /// The recorder's own capture is not a meeting: it is the thing doing the recording, and
    /// counting it would make every recording restart itself. The ignored apps are the voice
    /// recorder, dictation, and the assistant, which take the microphone without a call behind it.
    /// - Parameter ignoringNonCallApps: Whether the ignore list applies. Turning it off returns the
    ///   decision to "any other process holds the microphone", which is how the app behaved before
    ///   the list existed.
    public static func hasExternalInput(
        inputs: [Input],
        ownProcessID: Int32,
        ignoringNonCallApps: Bool
    ) -> Bool {
        inputs.contains { input in
            if input.processID == ownProcessID { return false }
            if ignoringNonCallApps, NonCallMicrophoneApps.isIgnored(bundleID: input.bundleID) {
                return false
            }
            return true
        }
    }
}
