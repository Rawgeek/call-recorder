import Foundation

/// How often the words on screen are replaced by a fresh summary.
///
/// Each option is a speed a person can read at: a summary a minute old is close to the words, and
/// one five minutes old is a chapter. Ninety seconds is the default because it is about a page of
/// speech — enough to be a summary rather than a paraphrase, recent enough to catch up from.
public enum LiveSummaryInterval: Double, CaseIterable, Codable, Sendable, Identifiable {
    case thirtySeconds = 30
    case oneMinute = 60
    case ninetySeconds = 90
    case threeMinutes = 180

    public var id: Double { rawValue }

    /// What the app ships with, and where a settings blob written before the choice existed lands.
    public static let `default` = LiveSummaryInterval.ninetySeconds

    public var seconds: TimeInterval { rawValue }

    public var title: String {
        switch self {
        case .thirtySeconds: "Every 30 seconds"
        case .oneMinute: "Every minute"
        case .ninetySeconds: "Every 90 seconds"
        case .threeMinutes: "Every 3 minutes"
        }
    }
}

/// The running summary of a call that is still going.
///
/// The window shows the words as they are said. A call worth joining late is longer than a person
/// can re-read while answering something else, so every so often the words are replaced on screen by
/// a summary of them, and one click brings the words back. The model is the same local one that
/// answers questions and writes the brief: nothing leaves the Mac, and the summary is a reading aid
/// in exactly the way the words are.
public enum LiveSummary {
    /// How much of the conversation the model is given.
    public static let maximumContextCharacters = 8_000

    /// The length an update is asked to stay under, in words.
    public static let maximumWords = 120

    /// The room one update is given to write in, in tokens.
    public static let updateTokenBudget = 400

    /// How many characters of new speech make an update worth a model pass.
    ///
    /// Speech arrives at roughly fifteen characters a second, so this is about a minute of talking:
    /// a summary that refreshes every minute is worth re-reading, and one that refreshes every ten
    /// seconds is a flicker. The same rule is what stops a quiet stretch of a call from spending a
    /// model pass on nothing said.
    public static let minimumNewCharacters = 900

    /// Whether the words since the last update are worth a model pass.
    ///
    /// - Parameters:
    ///   - transcript: everything said so far.
    ///   - lastEntryCount: how many lines the summary on screen was written from. The first update
    ///     passes zero, so it waits for the same amount of speech as any later one.
    public static func isWorthUpdating(
        transcript: LiveTranscript,
        lastEntryCount: Int
    ) -> Bool {
        let entries = transcript.entries
        guard entries.count > lastEntryCount else { return false }
        let newCharacters = entries[lastEntryCount...].reduce(0) { $0 + $1.text.count }
        return newCharacters >= minimumNewCharacters
    }

    public static func systemPrompt() -> String {
        """
        You keep a running summary of a call that is being recorded right now on this Mac. You are \
        given the words transcribed so far and the summary written from the words before them.
        Write the summary again so that it covers everything said so far, keeping whatever the \
        earlier summary had that is still true.
        Write in the language the call is in, as a few short lines, with no headings, no preamble, \
        no mention of these rules, and at most \(maximumWords) words.
        The words come from speech recognition while people talk, so they hold mistakes: keep what \
        is clear and leave out what is not.
        """
    }

    public static func userPrompt(previous: String, transcript: String) -> String {
        """
        The summary so far:
        \(previous.isEmpty ? "(nothing yet - this is the first update)" : previous)

        The call so far:
        \(transcript)
        """
    }
}
