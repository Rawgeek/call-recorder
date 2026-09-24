import Foundation
import Testing
@testable import CallRecorderCore

/// The words of a call that is still running: how they are ordered, who they are drawn under, and
/// what a question is allowed to be answered from.
@Suite("Live transcript")
struct LiveTranscriptTests {
    private func line(
        _ start: Double,
        _ source: LiveAudioSource,
        _ speaker: String,
        _ text: String
    ) -> LiveTranscriptEntry {
        LiveTranscriptEntry(
            startSeconds: start,
            source: source,
            speaker: speaker,
            text: text
        )
    }

    @Test("lines are drawn in the order they were said, not the order they arrived")
    func ordersByTime() {
        // The two sides close their chunks independently, so the system's line for the second
        // fifteen seconds is read before the microphone's line for the first.
        var transcript = LiveTranscript()
        transcript.append([line(20, .system, "Others", "second")])
        transcript.append([line(4, .microphone, "You", "first")])
        transcript.append([line(12, .microphone, "You", "in between")])
        #expect(transcript.entries.map(\.text) == ["first", "in between", "second"])
    }

    @Test("two lines that share a moment keep the order they arrived in")
    func settlesTies() {
        // Two chunks can hold the same starting second — both sides are cut every fifteen seconds
        // — and a sort that left the pair up to chance would redraw the window differently on the
        // next append. The arrival order is the answer, and it is settled by the sequence number.
        var transcript = LiveTranscript()
        transcript.append([line(5, .system, "Others", "the first one in")])
        transcript.append([line(5, .microphone, "You", "the second one in")])
        #expect(transcript.entries.map(\.text) == ["the first one in", "the second one in"])
    }

    @Test("each side is drawn under the name the app decided")
    func namesTheSides() {
        let transcript = LiveTranscript(localSpeaker: "Dana Holt", remoteSpeaker: "Others")
        #expect(transcript.speakerName(for: .microphone) == "Dana Holt")
        #expect(transcript.speakerName(for: .system) == "Others")
        #expect(transcript.speakers.isEmpty)
    }

    @Test("a moment in the call is written as a short clock")
    func writesTheClock() {
        #expect(LiveTranscript.clock(0) == "0:00")
        #expect(LiveTranscript.clock(67) == "1:07")
        #expect(LiveTranscript.clock(3_599) == "59:59")
        #expect(LiveTranscript.clock(3_661) == "1:01:01")
    }

    // The 2026-09-22 call: a meeting app played the other side for five seconds and the recording
    // started, then the call was held on a phone and the Mac recorded a room. One side of a call
    // was on screen with nothing said about the other, which reads as the transcription failing.
    @Test("a call with one side heard says so, once it has run long enough to matter")
    func noticesTheMissingSide() {
        var transcript = LiveTranscript()
        transcript.append([line(4, .microphone, "You", "When is she coming?")])
        #expect(transcript.unheardSideNotice(atSeconds: 60) == nil)
        let notice = transcript.unheardSideNotice(atSeconds: 200)
        #expect(notice?.contains("other side") == true)
        // What the room heard of the far end counts as the far end: a call is not one-sided because
        // the only words from it came through the speakers.
        transcript.append([line(90, .system, "Others", "I am on my way")])
        #expect(transcript.unheardSideNotice(atSeconds: 200) == nil)
    }

    @Test("a call where only the far side has been heard asks about the microphone")
    func noticesTheSilentMicrophone() {
        var transcript = LiveTranscript()
        transcript.append([line(4, .system, "Others", "Can you hear me?")])
        let notice = transcript.unheardSideNotice(atSeconds: 400)
        #expect(notice?.contains("microphone") == true)
    }

    @Test("a question is answered from the newest words that fit")
    func keepsTheNewestWords() {
        var transcript = LiveTranscript()
        for index in 0..<50 {
            transcript.append([line(Double(index), .system, "Others", "line \(index)")])
        }
        let tail = transcript.tail(maxCharacters: 120)
        #expect(tail.contains("line 49"))
        #expect(!tail.contains("line 0"))
        // Whole lines: a prompt that starts mid-sentence spends its first tokens on a fragment.
        for text in tail.split(separator: "\n") {
            #expect(text.hasPrefix("Others: line "))
        }
    }

    @Test("one line longer than the room left is cut rather than dropped")
    func cutsOneLongLine() {
        var transcript = LiveTranscript()
        transcript.append([line(1, .system, "Others", String(repeating: "a", count: 400))])
        let tail = transcript.tail(maxCharacters: 80)
        #expect(tail.count <= 80)
        #expect(!tail.isEmpty)
    }

    @Test("the state says what is happening in words a person reads")
    func saysWhatIsHappening() {
        #expect(LiveTranscriptStatus.listening.headline == "Listening")
        #expect(LiveTranscriptStatus.behind(seconds: 40).headline == "Reading the last 40 seconds")
        #expect(LiveTranscriptStatus.behind(seconds: 40).detail?.contains("40 seconds") == true)
        #expect(LiveTranscriptStatus.stopped.headline == "Recording finished")
        #expect(LiveTranscriptStatus.failed("the model stopped").detail == "the model stopped")
        #expect(LiveTranscriptStatus.failed("the model stopped").isProblem)
        #expect(!LiveTranscriptStatus.behind(seconds: 40).isProblem)
    }

    @Test("a question is refused with a sentence when there is nothing to answer from")
    func refusesAnEmptyCall() {
        let transcript = LiveTranscript()
        #expect(LiveChat.refusal(question: "What did I miss?", transcript: transcript) != nil)
        #expect(LiveChat.refusal(question: "   ", transcript: transcript) != nil)
        var spoken = LiveTranscript()
        spoken.append([line(1, .system, "Others", "We agreed on the first of October.")])
        #expect(LiveChat.refusal(question: "What did I miss?", transcript: spoken) == nil)
    }

    @Test("the question prompt carries the words and the question, and nothing else")
    func buildsTheQuestionPrompt() {
        let prompt = LiveChat.userPrompt(
            question: "What was decided?",
            transcript: "Others: We agreed on the first of October."
        )
        #expect(prompt.contains("Others: We agreed on the first of October."))
        #expect(prompt.contains("What was decided?"))
        let system = LiveChat.systemPrompt()
        #expect(system.contains("Answer only from those words"))
        #expect(system.contains(String(LiveChat.maximumAnswerWords)))
    }

    @Test("the offered questions are the four that fit any call")
    func offersQuestions() {
        #expect(LiveChat.recommendedQuestions.count == 4)
        #expect(LiveChat.recommendedQuestions.contains("What have I missed?"))
    }

    // MARK: - The room hearing the speakers

    @Test("a long microphone copy of the far end is hidden")
    func hidesAnEcho() {
        var transcript = LiveTranscript()
        transcript.append([
            line(60, .system, "Others", "we should move the launch to the first of october"),
            line(61, .microphone, "You", "we should move the launch to the first of october"),
        ])
        #expect(transcript.entries.count == 1)
        #expect(transcript.entries.first?.source == .system)
    }

    @Test("an echo is hidden when one word came back differently")
    func hidesAFuzzyEcho() {
        var transcript = LiveTranscript()
        transcript.append([
            line(30, .system, "Others", "one two three four five six seven eight nine ten"),
            line(31, .microphone, "You", "one two three four five six seven eight wrong ten"),
        ])
        #expect(transcript.entries.count == 1)
    }

    @Test("an echo is hidden when the cleaner side split it into several lines")
    func hidesAnEchoAcrossLines() {
        var transcript = LiveTranscript()
        transcript.append([
            line(1, .system, "Others", "and that is great maybe we could take on some part time"),
            line(5, .system, "Others", "developers that we can bring in to help andrey"),
            line(8, .system, "Others", "rather than as the main developers"),
            line(1, .microphone, "You", "and that is great maybe we could take on some part time "
                + "developers that we can bring in to help andrey rather than as the main developers"),
        ])
        #expect(transcript.entries.allSatisfy { $0.source == .system })
    }

    @Test("a short reply is speech, not an echo")
    func keepsShortReplies() {
        var transcript = LiveTranscript()
        transcript.append([
            line(10, .system, "Others", "yes that is exactly right"),
            line(10.5, .microphone, "You", "yes exactly right thanks"),
        ])
        #expect(transcript.entries.count == 2)
    }

    @Test("agreeing with somebody four seconds later is speech, not an echo")
    func keepsADelayedAgreement() {
        var transcript = LiveTranscript()
        transcript.append([
            line(10, .system, "Others", "yes that is exactly right"),
            line(16, .microphone, "You", "yes that is exactly right"),
        ])
        #expect(transcript.entries.count == 2)
    }

    @Test("a line already drawn is never taken back")
    func neverRemovesWhatIsDrawn() {
        var transcript = LiveTranscript()
        transcript.append([line(10, .microphone, "You", "we should move the launch to october")])
        transcript.append([line(10.5, .system, "Others", "we should move the launch to october")])
        transcript.append([line(11, .microphone, "You", "we should move the launch to october")])
        #expect(transcript.entries.count == 2)
        #expect(transcript.entries.map(\.source) == [.microphone, .system])
    }
}
