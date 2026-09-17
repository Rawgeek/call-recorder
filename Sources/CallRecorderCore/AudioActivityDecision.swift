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

    /// Whether the process holding the microphone is also playing audio.
    ///
    /// A call is two-way: the app that takes the microphone is the app that plays the other person.
    /// An app that takes the microphone and plays nothing is dictation, a voice message, or a voice
    /// search, and starting a meeting for one of those is how a recording with one side and no
    /// speech is made. Whether the audio is loud is deliberately not part of this: an app holds the
    /// output open for as long as the call lasts, talking or not. The microphone answer is unchanged
    /// and still ends the recording, so a call that goes quiet is recorded to its end.
    public static func hasTwoWayCall(
        inputs: [Input],
        playingOutput: Set<Int32>,
        ownProcessID: Int32,
        ignoringNonCallApps: Bool
    ) -> Bool {
        inputs.contains { input in
            if input.processID == ownProcessID { return false }
            if ignoringNonCallApps, NonCallMicrophoneApps.isIgnored(bundleID: input.bundleID) {
                return false
            }
            return playingOutput.contains(input.processID)
        }
    }

    /// The process the microphone answer is about, for a log line that can name it.
    public static func holder(
        inputs: [Input],
        ownProcessID: Int32,
        ignoringNonCallApps: Bool
    ) -> Input? {
        inputs.first { input in
            if input.processID == ownProcessID { return false }
            if ignoringNonCallApps, NonCallMicrophoneApps.isIgnored(bundleID: input.bundleID) {
                return false
            }
            return true
        }
    }
}
