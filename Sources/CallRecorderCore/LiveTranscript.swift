import Foundation

/// Which side of the call a line of live text came from.
///
/// The capture already delivers the two sides on separate queues, so this is not a guess: the
/// microphone is the person at this Mac and the system track is everybody else. Naming the two is
/// what makes the live view readable while the call runs, which is before the call's own
/// diarization has had the audio to decide any better.
public enum LiveAudioSource: String, Codable, Equatable, Sendable, CaseIterable {
    case microphone
    case system
}

/// One line of the live view: when it was said, which side said it, and the words.
public struct LiveTranscriptEntry: Identifiable, Equatable, Sendable, Codable {
    /// The order this line was added in, so the transcript can settle two lines that share a
    /// moment without the answer depending on how the sort felt that day.
    public let sequence: Int
    public let id: UUID
    /// Where the line starts, in seconds from the start of the recording.
    public let startSeconds: Double
    public let source: LiveAudioSource
    /// The name the line is drawn under, as the app decided it at the moment it arrived.
    public let speaker: String
    /// The end of the line, in seconds from the start of the recording, when it is known.
    public let endSeconds: Double?
    public let text: String

    public init(
        id: UUID = UUID(),
        sequence: Int = 0,
        startSeconds: Double,
        source: LiveAudioSource,
        speaker: String,
        endSeconds: Double? = nil,
        text: String
    ) {
        self.id = id
        self.sequence = sequence
        self.startSeconds = startSeconds
        self.source = source
        self.speaker = speaker
        self.endSeconds = endSeconds
        self.text = text
    }

    /// The moment this line was said, as a short clock.
    public var timeLabel: String { LiveTranscript.clock(startSeconds) }
}

/// The words of a recording that is still running, and the rules that keep them readable.
///
/// This is a reading aid and never a record. Nothing here is written into the library: the call's
/// transcript is produced after the call by the batch pipeline, from the recording itself, and it
/// is the file the app stands behind. The value type exists so the ordering, the naming, and the
/// text a question is answered from can be checked without a recording, a window, or a model.
public struct LiveTranscript: Equatable, Sendable {
    public private(set) var entries: [LiveTranscriptEntry]
    /// Chunks the transcriber gave up on because it fell too far behind. The count is shown, so a
    /// gap in the text is explained rather than mistaken for silence.
    public private(set) var droppedChunks: Int
    /// How the microphone side is named when the library knows who is speaking.
    public private(set) var localSpeaker: String
    /// How the other side is named. The voices on the far end are told apart after the call, so
    /// while it runs they are one group and are named as one.
    public private(set) var remoteSpeaker: String
    private var nextSequence: Int

    public init(
        entries: [LiveTranscriptEntry] = [],
        droppedChunks: Int = 0,
        localSpeaker: String = "You",
        remoteSpeaker: String = "Others"
    ) {
        self.entries = entries
        self.droppedChunks = droppedChunks
        self.localSpeaker = localSpeaker
        self.remoteSpeaker = remoteSpeaker
        nextSequence = (entries.map(\.sequence).max() ?? -1) + 1
    }

    public var isEmpty: Bool { entries.isEmpty }

    /// The people this transcript draws, in the order they first spoke.
    public var speakers: [String] {
        var seen: Set<String> = []
        return entries.compactMap { entry in
            seen.insert(entry.speaker).inserted ? entry.speaker : nil
        }
    }

    /// The name a line from one side is drawn under.
    public func speakerName(for source: LiveAudioSource) -> String {
        source == .microphone ? localSpeaker : remoteSpeaker
    }

    /// How long a call runs before one side being absent is worth a sentence.
    ///
    /// Three minutes. A far end that has said nothing for a minute is a far end that is listening,
    /// and a window that comments on every quiet stretch is a window with a notice in it. Three
    /// minutes of one side only is a recording of a room, and the person should hear it from this
    /// window rather than from the file the next day.
    public static let unheardSideSeconds: Double = 180

    /// What to say about a side of the call that has not been heard, or nil while both have been.
    ///
    /// The 2026-09-22 call started by itself when a meeting app played the other side for five
    /// seconds, and then recorded a room: the call itself was on a phone, and the Mac played
    /// nothing for the rest of it. The window drew the one side it heard and said nothing about the
    /// other, which reads as a fault in the transcription rather than a fact about the audio. The
    /// sentence is written from the lines themselves, so a side that has produced no words — or
    /// only the model's words for a quiet room, which are not drawn — counts as unheard.
    public func unheardSideNotice(atSeconds elapsed: Double) -> String? {
        guard elapsed >= Self.unheardSideSeconds else { return nil }
        let heardLocal = entries.contains { $0.source == .microphone }
        let heardRemote = entries.contains { $0.source == .system }
        guard heardLocal != heardRemote else { return nil }
        guard heardLocal else {
            return "Only the other side of the call has been heard so far. If you are speaking, "
                + "check the microphone this Mac is listening to."
        }
        return "Only your side of the call has been heard so far. If the other side is speaking, "
            + "check that the call's audio plays through this Mac."
    }

    /// Adds lines, in the order they were said rather than the order they arrived.
    ///
    /// The two sides are transcribed as their own chunks close, so lines do not arrive in time
    /// order: the microphone's chunk for the last fifteen seconds can be read before the system's
    /// chunk for the minute before it. Sorting here is what keeps the window a conversation
    /// instead of two streams that have to be followed at once.
    public mutating func append(_ lines: [LiveTranscriptEntry]) {
        guard !lines.isEmpty else { return }
        // What the room heard of the speakers is dropped before it is ever drawn, so the window
        // does not show the far end twice, once under each name.
        let kept = LiveEchoFilter.keepingSpeech(lines, against: entries + lines)
        guard !kept.isEmpty else { return }
        var stamped: [LiveTranscriptEntry] = []
        stamped.reserveCapacity(kept.count)
        for line in kept {
            stamped.append(
                LiveTranscriptEntry(
                    id: line.id,
                    sequence: nextSequence,
                    startSeconds: line.startSeconds,
                    source: line.source,
                    speaker: line.speaker,
                    endSeconds: line.endSeconds,
                    text: line.text
                )
            )
            nextSequence += 1
        }
        entries.append(contentsOf: stamped)
        entries.sort { left, right in
            if left.startSeconds != right.startSeconds {
                return left.startSeconds < right.startSeconds
            }
            return left.sequence < right.sequence
        }
    }

    /// Records how many chunks the transcriber has given up on so far.
    ///
    /// The number is the transcriber's own count rather than an increment, so a report that arrives
    /// twice cannot double it.
    public mutating func setDroppedChunks(_ count: Int) {
        droppedChunks = max(0, count)
    }

    /// The last part of the conversation, small enough for a model's prompt.
    ///
    /// Whole lines are kept where they fit and the newest lines win: a question is about what was
    /// just said, and a prompt that starts mid-sentence spends its first tokens on a fragment
    /// nobody can use. One line longer than the budget is cut from its own start, because a line
    /// that long is a transcription artefact rather than a sentence.
    public func tail(maxCharacters: Int) -> String {
        guard maxCharacters > 0 else { return "" }
        var kept: [String] = []
        var used = 0
        for entry in entries.reversed() {
            let line = entry.speaker + ": " + entry.text
            let cost = line.count + 1
            if used + cost > maxCharacters {
                if kept.isEmpty {
                    kept.append(String(line.suffix(maxCharacters)))
                }
                break
            }
            kept.append(line)
            used += cost
        }
        return kept.reversed().joined(separator: "\n")
    }

    /// A moment in the recording as a short clock: `4:07`, or `1:04:07` once a call passes an hour.
    public static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total >= 3_600 {
            return String(
                format: "%d:%02d:%02d",
                total / 3_600,
                (total % 3_600) / 60,
                total % 60
            )
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// What the live view says is happening, in the few states it can be in.
public enum LiveTranscriptStatus: Equatable, Sendable {
    /// No recording is running, so there is nothing to read.
    case idle
    /// A recording is running and the transcriber is loading its model.
    case starting
    /// Text is arriving as fast as it is spoken.
    case listening
    /// The transcriber is behind by this many seconds of audio.
    case behind(seconds: Int)
    /// The recording ended, so the live path stopped with it.
    case stopped
    /// The live path stopped working, and this is why.
    case failed(String)

    /// The first line of the live view.
    public var headline: String {
        switch self {
        case .idle: "Not recording"
        case .starting: "Starting"
        case .listening: "Listening"
        case let .behind(seconds): "Reading the last " + Self.duration(seconds)
        case .stopped: "Recording finished"
        case .failed: "Live text stopped"
        }
    }

    /// The sentence under the headline, when there is one.
    public var detail: String? {
        switch self {
        case .idle:
            "Start a recording, or open this window while one is running, and the words appear "
                + "here as they are said."
        case .starting:
            "The transcription model is loading. The first words appear once it is ready."
        case .listening:
            nil
        case let .behind(seconds):
            "This machine is behind by about " + Self.duration(seconds)
                + " of speech. The text below is still arriving in order."
        case .stopped:
            "The call's own transcript is written from the recording when it is ready. "
                + "Keep this window open to read what was said, or close it."
        case let .failed(reason):
            reason
        }
    }

    /// Whether the state is one the view draws as a problem.
    public var isProblem: Bool {
        if case .failed = self { return true }
        return false
    }

    /// Whether the state is one where a question can be asked.
    public var acceptsQuestions: Bool {
        switch self {
        case .starting, .listening, .behind: true
        case .idle, .stopped, .failed: false
        }
    }

    /// A number of seconds as words: `40 seconds`, `2 minutes`.
    public static func duration(_ seconds: Int) -> String {
        let seconds = max(0, seconds)
        if seconds < 60 { return String(seconds) + " seconds" }
        let minutes = seconds / 60
        let rest = seconds % 60
        if rest == 0 {
            return String(minutes) + (minutes == 1 ? " minute" : " minutes")
        }
        return String(minutes) + " min " + String(rest) + " s"
    }
}

/// A question asked during a call, and the answer it was given.
public struct LiveChatAnswer: Equatable, Sendable {
    public let question: String
    public let answer: String

    public init(question: String, answer: String) {
        self.question = question
        self.answer = answer
    }
}

/// The rules for asking a local model about a call that is still running.
///
/// A question is answered from the words so far and nothing else. The model is the same one that
/// writes the brief after a call, run on this Mac by llama.cpp: the call never leaves the machine,
/// which is why a question about a private meeting can be asked at all.
public enum LiveChat {
    /// The questions the window offers, chosen to fit any call.
    public static let recommendedQuestions = [
        "What have I missed?",
        "What was decided?",
        "What are the action items?",
        "What numbers came up?",
    ]

    /// How much of the conversation a question is answered from.
    ///
    /// The tail rather than the whole call: a question asked during a meeting is about the meeting
    /// so far, and eight thousand characters is around an hour of speech — more than the model
    /// needs to answer and less than its context can hold beside the answer.
    public static let maximumContextCharacters = 8_000

    /// The length the answer is asked to stay under, in words.
    public static let maximumAnswerWords = 120

    /// The room the answer is given to write in, in tokens.
    public static let answerTokenBudget = 400

    public static func systemPrompt() -> String {
        """
        You answer questions about a call that is being recorded right now on this Mac. You are \
        given the words transcribed so far and nothing else.
        Answer only from those words. If they do not hold the answer, say so plainly instead of \
        guessing.
        The words come from speech recognition while people talk, so they hold mistakes and the \
        most recent words may be missing.
        Answer in the language the question was asked in, in at most \(maximumAnswerWords) words, \
        with no preamble and no mention of these rules.
        """
    }

    public static func userPrompt(question: String, transcript: String) -> String {
        """
        The call so far:
        \(transcript)

        Question: \(question.trimmingCharacters(in: .whitespacesAndNewlines))
        """
    }

    /// Why a question cannot be asked, or nil when it can.
    public static func refusal(question: String, transcript: LiveTranscript) -> String? {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Type a question first." }
        guard !transcript.isEmpty else {
            return "There is nothing to answer from yet. The words appear as people speak."
        }
        return nil
    }
}
