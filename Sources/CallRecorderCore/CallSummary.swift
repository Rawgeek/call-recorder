import Foundation

/// A brief of a call, written by a model that runs on this Mac.
///
/// The brief is not a second transcript. It is the part a person reads before working on something
/// else: what the call was about, what was agreed, who owes what, and what was left open. A
/// transcript is the wrong shape for that question — a thirty-four minute call runs to around six
/// thousand words, and every one of them costs context in whatever reads it next.
public struct CallSummary: Codable, Hashable, Sendable {
    public let callID: CallID
    /// The brief itself, as the model wrote it.
    public let text: String
    /// The model that wrote it, by catalog id, so a brief can be told from one another model wrote.
    public let modelID: String
    public let generatedAt: Date
    /// How much of the call the brief covers, in seconds from the start.
    ///
    /// A brief written from the whole transcript covers the call. The field exists because a brief
    /// written from part of one covers only that part, and a reader has to be able to tell the two
    /// apart without guessing.
    public let coveredSeconds: Double

    public init(
        callID: CallID,
        text: String,
        modelID: String,
        generatedAt: Date,
        coveredSeconds: Double
    ) {
        self.callID = callID
        self.text = text
        self.modelID = modelID
        self.generatedAt = generatedAt
        self.coveredSeconds = coveredSeconds
    }
}

/// The rules a brief is written under: when one is worth writing, and how much text one pass holds.
public enum CallBrief {
    /// The catalog id of the model that writes briefs.
    public static let modelID = SupportingModel.callBriefID

    /// The fewest characters of transcript that are worth a model run.
    ///
    /// Below this the call held a sentence or two, and a brief of it would be longer than the thing
    /// it describes. Four hundred characters is roughly a minute of speaking.
    public static let minimumCharacters = 400

    /// The most transcript one model pass is given.
    ///
    /// Ten thousand tokens at the usual four characters to a token, which leaves room in a
    /// thirty-two thousand token context for the instructions and for the brief that comes back. A
    /// call that runs longer is read in parts, and the parts are then written into one brief.
    public static let charactersPerPass = 40_000

    /// The most tokens a brief may run to.
    ///
    /// The prompt asks for under a hundred and fifty words. This is the backstop that stops a model
    /// that ignores the instruction from writing a second transcript.
    public static let maximumTokens = 512

    /// The temperature a brief is written at: enough variation to read as prose, not enough to
    /// wander.
    public static let temperature = 0.3

    /// Whether a transcript holds enough speech to be worth a model run.
    public static func isWorthWriting(transcriptCharacters: Int) -> Bool {
        transcriptCharacters >= minimumCharacters
    }
}

/// The words a brief is asked for in.
public enum SummaryPrompt {
    /// The instruction that does not change with the call.
    ///
    /// Every rule here answers a mistake the model makes without it: the language rule because a
    /// Russian call answered in English is a translation nobody asked for, the name rule because
    /// "Speaker 7" is worse than useless to a reader, and the honesty rule because an invented
    /// ticket number reads exactly like a real one.
    public static func system() -> String {
        return [
            "You write a short brief of a work call. The person reading it was not on the call and",
            "is about to work on something else.",
            "",
            "Rules:",
            "- Write in the language the call was held in. If the call mixes languages, write in",
            "  the language most of it is in.",
            "- Use the names the transcript uses for people. Never write Speaker 1 when the",
            "  transcript gives a name.",
            "- Write only what the transcript supports. Never invent a name, a number, a date, a",
            "  decision, or a task.",
            "- Prefer the concrete: a ticket number, a file, an amount, a date, a person.",
            "- Keep the whole brief under 150 words. No preamble and no closing line.",
            "- Leave out a section that has nothing in it.",
            "",
            "Write these sections:",
            "",
            "## About",
            "One line on what the call was about.",
            "",
            "## Decisions",
            "- What was agreed, and who agreed it.",
            "",
            "## To do",
            "- Who does what.",
            "",
            "## Open",
            "- Questions left unanswered and things that block work.",
            "",
            "## Numbers",
            "- Identifiers, amounts, dates, and systems that matter.",
        ].joined(separator: "\n")
    }

    /// One pass over a transcript, or over one part of a long one.
    ///
    /// - Parameters:
    ///   - transcript: The spoken text, with a name in front of each turn where one is known.
    ///   - context: What is known about the call: its date, how long it ran, who was on it.
    ///   - part: Which part this is, when a long call is read in several. nil asks for a brief of
    ///     the whole call.
    public static func user(
        transcript: String,
        context: CallContext,
        part: (index: Int, count: Int)? = nil
    ) -> String {
        var lines: [String] = [context.line]
        if let part {
            lines.append(
                "This is part " + String(part.index + 1) + " of " + String(part.count)
                    + " of the call, in order. Write a brief of this part alone."
            )
        }
        lines.append("")
        lines.append("Transcript:")
        lines.append(transcript)
        return lines.joined(separator: "\n")
    }

    /// The last pass of a long call: several part briefs written into one.
    public static func merge(briefs: [String], context: CallContext) -> String {
        let body = briefs.enumerated()
            .map { "Brief of part " + String($0.offset + 1) + ":\n" + $0.element }
            .joined(separator: "\n\n")
        return [
            context.line,
            "",
            "The call was too long to read in one pass, so it was read in " + String(briefs.count),
            "parts and a brief was written for each. Write the single brief of the whole call. Join",
            "what the parts agree on and leave out what a later part corrected.",
            "",
            body,
        ].joined(separator: "\n")
    }
}

/// What is known about a call before its transcript is read.
public struct CallContext: Equatable, Sendable {
    public let startedAt: Date?
    public let durationSeconds: Double
    public let participants: [String]
    public let language: String?

    public init(
        startedAt: Date? = nil,
        durationSeconds: Double = 0,
        participants: [String] = [],
        language: String? = nil
    ) {
        self.startedAt = startedAt
        self.durationSeconds = durationSeconds
        self.participants = participants
        self.language = language
    }

    /// The line the model is given about the call, which saves it from reading a date off the
    /// transcript and getting it wrong.
    public var line: String {
        var parts: [String] = []
        if let startedAt {
            parts.append("Date: " + Self.dateFormatter.string(from: startedAt) + ".")
        }
        if durationSeconds > 0 {
            parts.append("Length: " + Self.duration(durationSeconds) + ".")
        }
        if !participants.isEmpty {
            parts.append("People on the call: " + participants.joined(separator: ", ") + ".")
        }
        if let language, !language.isEmpty {
            parts.append("The transcript says this language: " + language + ".")
        }
        return parts.isEmpty ? "A work call." : parts.joined(separator: " ")
    }

    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let minutes = max(total / 60, 1)
        guard minutes >= 60 else { return count(minutes, "minute") }
        let hours = minutes / 60
        let rest = minutes % 60
        guard rest > 0 else { return count(hours, "hour") }
        return count(hours, "hour") + " " + count(rest, "minute")
    }

    /// A number and its noun, with the noun plural only where it should be. A brief that opens
    /// with "Length: 1 minutes" reads as a machine's arithmetic rather than a person's note.
    static func count(_ value: Int, _ noun: String) -> String {
        String(value) + " " + noun + (value == 1 ? "" : "s")
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d MMMM yyyy"
        return formatter
    }()
}

/// The transcript as a model reads it, and the way a long one is split.
public enum SummaryTranscript {
    /// The spoken text of a saved transcript, without its header.
    ///
    /// A saved transcript writes each turn as a bold name, then the words. The bold marks are the
    /// app's, not the speaker's, so they come off before the text is read. The header comes off too:
    /// the people on the call reach the model as its own line, and a header read twice is context
    /// spent twice.
    public static func plainText(fromMarkdown markdown: String) -> String {
        let body = TranscriptRenderer.body(of: markdown)
        return body
            .replacingOccurrences(of: "**", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A long transcript cut into parts the model can hold, in order.
    ///
    /// The cut lands on a line break, so a part never begins in the middle of a turn. A single line
    /// longer than the limit is kept whole: cutting it would be worse than passing it.
    public static func parts(
        of text: String,
        maxCharacters: Int = CallBrief.charactersPerPass
    ) -> [String] {
        guard text.count > maxCharacters else { return [text] }
        var parts: [String] = []
        var current = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let row = String(line) + "\n"
            if !current.isEmpty, current.count + row.count > maxCharacters {
                parts.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = ""
            }
            current += row
        }
        let last = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !last.isEmpty { parts.append(last) }
        return parts.isEmpty ? [text] : parts
    }
}
