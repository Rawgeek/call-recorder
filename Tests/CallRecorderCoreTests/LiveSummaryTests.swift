import Foundation
import Testing
@testable import CallRecorderCore

/// What earns an update of the running summary, how often one is due, and what the model is asked
/// for one.
@Suite("Running summary")
struct LiveSummaryTests {
    /// A call whose lines are as long as the numbers say.
    private func transcript(_ lengths: [Int]) -> LiveTranscript {
        var transcript = LiveTranscript(localSpeaker: "Stas", remoteSpeaker: "Others")
        transcript.append(
            lengths.enumerated().map { index, length in
                LiveTranscriptEntry(
                    sequence: index,
                    startSeconds: Double(index) * 15,
                    source: .system,
                    speaker: "Others",
                    text: String(repeating: "x", count: length)
                )
            }
        )
        return transcript
    }

    @Test("the first update waits for as much speech as every later one")
    func firstUpdateWaitsLikeTheRest() {
        // A call that has just started: three lines, which is well short of a minute of talking.
        #expect(!LiveSummary.isWorthUpdating(transcript: transcript([200, 200, 200]), lastEntryCount: 0))
        // A minute of speech is about the nine hundred characters the rule asks for.
        #expect(LiveSummary.isWorthUpdating(transcript: transcript([200, 200, 200, 300]), lastEntryCount: 0))
    }

    @Test("words a summary was already written from do not earn a second pass")
    func summarizedWordsAreNotSummarizedAgain() {
        let call = transcript([200, 200, 200, 400])
        #expect(LiveSummary.isWorthUpdating(transcript: call, lastEntryCount: 0))
        #expect(!LiveSummary.isWorthUpdating(transcript: call, lastEntryCount: 4))
    }

    @Test("a quiet stretch of a call costs no model pass")
    func quietStretchCostsNothing() {
        // Two lines arrived since the last update: something was said, but not a minute of it, and
        // a summary written from two sentences is the same summary with a new first line.
        #expect(!LiveSummary.isWorthUpdating(transcript: transcript([400, 400, 100, 80]), lastEntryCount: 2))
    }

    @Test("the step the app ships with is ninety seconds")
    func stepShippedWith() {
        #expect(LiveSummaryInterval.default == .ninetySeconds)
        #expect(LiveSummaryInterval.default.seconds == 90)
        #expect(LiveSummaryInterval.allCases.map(\.rawValue) == [30, 60, 90, 180])
        // Every step is named, and no two steps share a name: the picker draws these.
        #expect(Set(LiveSummaryInterval.allCases.map(\.title)).count == LiveSummaryInterval.allCases.count)
    }

    @Test("the model is told the length, the language, and that the words hold mistakes")
    func whatTheModelIsTold() {
        let system = LiveSummary.systemPrompt()
        #expect(system.contains("120 words"))
        #expect(system.contains("the language the call is in"))
        // The first update has no summary before it, and says so rather than sending nothing.
        #expect(LiveSummary.userPrompt(previous: "", transcript: "hello").contains("first update"))
        #expect(LiveSummary.userPrompt(previous: "earlier", transcript: "hello").contains("earlier"))
    }
}
