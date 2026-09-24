import CallRecorderCore
import Foundation
import Testing
@testable import CallRecorderApp

/// The live path of one recording: that the tap is ready before the model is started, what a Mac
/// without whisper.cpp is told, and the summary that replaces the words as the call goes on.
///
/// The first test in here is the one that would have caught the 2026-09-21 14:02 recording: the
/// window said "Listening" with the model running, and not one word arrived for fifteen minutes,
/// because the tap handed to the capture path held no reader.
@MainActor
@Suite("Live transcript session")
struct LiveTranscriptSessionTests {
    /// The reader's side of the model, answering from bytes the test chose: no server is started.
    private final class StubTransport: LiveTranscriptionTransport, @unchecked Sendable {
        private let lock = NSLock()
        private let payloads: [String: Data]

        init(payloads: [String: Data]) {
            self.payloads = payloads
        }

        func start() async throws {}

        func transcribe(audioAt url: URL, prompt: String, language: String?) async throws -> Data {
            try lock.withLock {
                guard let payload = payloads[url.lastPathComponent] else {
                    throw LiveTranscriptionError.requestFailed(
                        "no answer for " + url.lastPathComponent
                    )
                }
                return payload
            }
        }

        func stop() async {}
    }

    /// The model behind the window, answering with a sentence the test chose.
    private actor StubSummarizer: LiveSummarizing {
        private let answer: String
        private var asked: [String] = []

        init(answer: String) {
            self.answer = answer
        }

        func summarize(previous: String, transcript: LiveTranscript) async throws -> String {
            asked.append(previous)
            return answer + " (" + String(transcript.entries.count) + " lines)"
        }

        var timesAsked: Int { asked.count }
        var previousSummaries: [String] { asked }
    }

    /// A summarizer that never manages an answer, for the call that must not be disturbed by it.
    private actor FailingSummarizer: LiveSummarizing {
        func summarize(previous: String, transcript: LiveTranscript) async throws -> String {
            throw LiveChatError.empty
        }
    }

    /// What a session reported, in the order it reported it.
    private final class EventBox: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [LiveTranscriptSession.Event] = []

        func append(_ event: LiveTranscriptSession.Event) {
            lock.withLock { events.append(event) }
        }

        var recorded: [LiveTranscriptSession.Event] { lock.withLock { events } }

        var summaries: [String] {
            recorded.compactMap { (event: LiveTranscriptSession.Event) -> String? in
                if case let .summary(text) = event { return text }
                return nil
            }
        }

        var lines: [LiveTranscriptEntry] {
            recorded.flatMap { (event: LiveTranscriptSession.Event) -> [LiveTranscriptEntry] in
                if case let .text(lines) = event { return lines }
                return []
            }
        }

        var failures: [String] {
            recorded.compactMap { (event: LiveTranscriptSession.Event) -> String? in
                if case let .failure(message) = event { return message }
                return nil
            }
        }
    }

    private func scratch() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "live-session-" + UUID().uuidString, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// What the app hands a session for one call, with the model files replaced by whatever the
    /// test needs them to be: only their presence is read here, never their contents.
    private func configuration(
        callDirectory: URL,
        whisperServer: URL? = URL(fileURLWithPath: "/usr/bin/true"),
        whisperModel: URL? = URL(fileURLWithPath: "/usr/bin/true"),
        summaryIntervalSeconds: Double? = nil
    ) -> LiveTranscriptSession.Configuration {
        LiveTranscriptSession.Configuration(
            callDirectory: callDirectory,
            whisperServer: whisperServer,
            whisperModel: whisperModel,
            whisperModelName: "large-v3-turbo",
            prompt: "Stas",
            glossary: [],
            localSpeaker: "Stas",
            remoteSpeaker: "Others",
            chatRuntime: nil,
            chatModel: nil,
            summaryIntervalSeconds: summaryIntervalSeconds
        )
    }

    /// whisper.cpp's answer for one chunk, as the transport hands it up.
    private func payload(_ segments: [(text: String, start: Double, end: Double)]) -> Data {
        let body: [String: Any] = [
            "language": "en",
            "detected_language": "english",
            "detected_language_probability": 0.9,
            "segments": segments.map { segment in
                ["text": segment.text, "start": segment.start, "end": segment.end]
            },
        ]
        return try! JSONSerialization.data(withJSONObject: body)
    }

    /// One closed chunk on disk, which is what a tap hands the reader.
    private func chunk(_ name: String, start: Double, directory: URL) -> LiveAudioTap.Chunk {
        let url = directory.appending(path: name)
        FileManager.default.createFile(atPath: url.path, contents: Data("audio".utf8))
        return LiveAudioTap.Chunk(
            source: .system,
            index: 0,
            startSeconds: start,
            durationSeconds: 15,
            fileURL: url
        )
    }

    /// Waits for something a session reports on its own clock. The bound is what keeps a broken
    /// live path from hanging a test run.
    private func wait(upTo seconds: Double = 3, for condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    /// A minute of speech, which is what one summary is worth.
    ///
    /// Every sentence is a different one on purpose. A paragraph built by repeating a single
    /// sentence is the loop whisper writes when it loses the audio, the decoder throws it away
    /// rather than drawing it, and a test built on one would be checking a path that never runs.
    private let minuteOfSpeech = """
    The label flow is the first thing to look at, because the courier changed the document it \
    returns and the portal shows that document under the shipment. Dmitry said the follow up goes \
    out on Thursday morning, and the numbers he quoted came from last month's report rather than \
    from this one. We still need the account number before a label can be generated for the \
    customer, so Olya will send the list of open returns and John can take the pricing question to \
    the partner. The sandbox keys are in place and the integration is finished on our side. Nobody \
    has asked for a new warehouse yet, and the two open tickets are waiting on the customer's \
    answer. The other items stay where they are until the release goes out, and we will pick up the \
    speaker handling on Monday morning with the rest of the review. Razy asked whether the tracking \
    page can show the courier's reference as well, and the answer is that it can once the field is \
    mapped on our side. Stas will write the note for the release and put the screenshots beside it.
    """

    /// A second minute of speech, also all different sentences.
    private let secondMinuteOfSpeech = """
    The return order comes in first and then we call their API with the data the portal already \
    holds. Direct injection is the case the courier handles itself, so nothing is pushed for it and \
    the label comes back through their own system. When a loop return arrives we sync the status \
    and generate the document from the master credential, which is the part that needs the account \
    number. The reporting endpoint is slow on Mondays and the retry covers it.
    The customer asked for the pricing table again, and the answer depends on the weight band \
    rather than on the surcharge we discussed last time. Artem will check whether the old rate card \
    still applies to the two remaining lanes, and the finance team needs the warehouse count before \
    the Tuesday cut off. Nothing else changed since the last release, so the review can wait until \
    the integration is signed off by the partner. The two lanes are the ones with the manual step, \
    and that step is what the new endpoint removes once the keys are rotated.
    """

    // MARK: - The tap

    @Test("the tap is handed over before anything is started")
    func tapIsReadyBeforeStart() {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = LiveTranscriptSession(configuration: configuration(callDirectory: directory)) {
            _ in
        }

        // The capture path asks for the tap before the recording opens, so a reader that is built
        // only in start() is a reader that does not exist yet when it is asked for. Both sides of
        // the call are tapped, and the second segment is placed after the first.
        #expect(session.isAvailable)
        #expect(session.makeTap(offsetSeconds: 0) != nil)
        #expect(session.makeTap(offsetSeconds: 900) != nil)
    }

    @Test("a Mac without whisper.cpp is told what to install, and gets no tap")
    func withoutWhisperCPP() {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let box = EventBox()
        let session = LiveTranscriptSession(
            configuration: configuration(callDirectory: directory, whisperServer: nil)
        ) { box.append($0) }

        #expect(!session.isAvailable)
        #expect(session.makeTap(offsetSeconds: 0) == nil)
        session.start()
        #expect(box.failures.first?.contains("brew install whisper-cpp") == true)
    }

    @Test("a Mac without the model is told which model is missing")
    func withoutTheModel() {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let box = EventBox()
        let session = LiveTranscriptSession(
            configuration: configuration(callDirectory: directory, whisperModel: nil)
        ) { box.append($0) }

        #expect(!session.isAvailable)
        session.start()
        #expect(box.failures.first?.contains("large-v3-turbo") == true)
    }

    // MARK: - The running summary

    @Test("the words are replaced by a summary while the call goes on")
    func summarizesWhileTheCallRuns() async throws {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let text = minuteOfSpeech
        // The fixture has to be at least what one update is worth, or the test would be checking a
        // call that has not said enough to earn one.
        #expect(text.count >= LiveSummary.minimumNewCharacters)
        let transport = StubTransport(payloads: ["system-0000.wav": payload([(text, 0, 15)])])
        let summarizer = StubSummarizer(answer: "The call is about the label flow.")
        let box = EventBox()
        let session = LiveTranscriptSession(
            configuration: configuration(callDirectory: directory, summaryIntervalSeconds: 0.05),
            readingTransport: transport,
            summarizer: summarizer
        ) { box.append($0) }

        session.start()
        session.transcriber?.enqueue(chunk("system-0000.wav", start: 0, directory: directory))
        await session.transcriber?.waitForIdle()

        #expect(await wait { box.summaries.count == 1 })
        #expect(box.summaries.first?.hasPrefix("The call is about the label flow.") == true)
        // The words stay where they are: the window is what replaces them, and the switch at the top
        // of the window brings them back.
        #expect(box.lines.map(\.text) == [text])
        #expect(box.failures.isEmpty)

        // And the same words do not earn a second pass, however many intervals go by.
        try? await Task.sleep(for: .milliseconds(200))
        #expect(await summarizer.timesAsked == 1)
        #expect(box.summaries.count == 1)
    }

    @Test("an update carries what the summary already said, so it is rewritten, not restarted")
    func laterUpdatesCarryTheEarlierSummary() async throws {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = minuteOfSpeech
        let second = secondMinuteOfSpeech
        #expect(first.count >= LiveSummary.minimumNewCharacters)
        #expect(second.count >= LiveSummary.minimumNewCharacters)
        let transport = StubTransport(payloads: [
            "system-0000.wav": payload([(first, 0, 15)]),
            "system-0001.wav": payload([(second, 15, 30)]),
        ])
        let summarizer = StubSummarizer(answer: "The call is about the label flow.")
        let box = EventBox()
        let session = LiveTranscriptSession(
            configuration: configuration(callDirectory: directory, summaryIntervalSeconds: 0.05),
            readingTransport: transport,
            summarizer: summarizer
        ) { box.append($0) }

        session.start()
        session.transcriber?.enqueue(chunk("system-0000.wav", start: 0, directory: directory))
        await session.transcriber?.waitForIdle()
        #expect(await wait { box.summaries.count == 1 })
        session.transcriber?.enqueue(chunk("system-0001.wav", start: 15, directory: directory))
        await session.transcriber?.waitForIdle()
        #expect(await wait { box.summaries.count == 2 })

        // The second pass was given the summary the first one wrote, which is what keeps a running
        // summary a rewrite of one text instead of a fresh reading of the whole call.
        let previous = await summarizer.previousSummaries
        #expect(previous.first?.isEmpty == true)
        #expect(previous.last?.hasPrefix("The call is about the label flow.") == true)
    }

    @Test("a call with nothing new to say costs no model pass")
    func nothingNewCostsNothing() async throws {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = StubTransport(payloads: ["system-0000.wav": payload([("hello", 0, 2)])])
        let summarizer = StubSummarizer(answer: "Nothing much.")
        let box = EventBox()
        let session = LiveTranscriptSession(
            configuration: configuration(callDirectory: directory, summaryIntervalSeconds: 0.05),
            readingTransport: transport,
            summarizer: summarizer
        ) { box.append($0) }

        session.start()
        session.transcriber?.enqueue(chunk("system-0000.wav", start: 0, directory: directory))
        await session.transcriber?.waitForIdle()

        // Several intervals pass over one word of speech. The window keeps the word, and the model
        // is asked for nothing.
        try? await Task.sleep(for: .milliseconds(250))
        #expect(box.summaries.isEmpty)
        #expect(await summarizer.timesAsked == 0)
        #expect(box.lines.map(\.text) == ["hello"])
    }

    @Test("with the running summary switched off, the model is asked for nothing")
    func switchedOffAsksNothing() async throws {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = StubTransport(payloads: ["system-0000.wav": payload([(minuteOfSpeech, 0, 15)])])
        let summarizer = StubSummarizer(answer: "A summary nobody asked for.")
        let box = EventBox()
        let session = LiveTranscriptSession(
            configuration: configuration(callDirectory: directory),
            readingTransport: transport,
            summarizer: summarizer
        ) { box.append($0) }

        session.start()
        session.transcriber?.enqueue(chunk("system-0000.wav", start: 0, directory: directory))
        await session.transcriber?.waitForIdle()

        try? await Task.sleep(for: .milliseconds(250))
        #expect(box.summaries.isEmpty)
        #expect(await summarizer.timesAsked == 0)
        #expect(box.lines.count == 1)
    }

    @Test("a summary that fails leaves the words on screen and the call alone")
    func failedSummaryLeavesTheWords() async throws {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let text = minuteOfSpeech
        let transport = StubTransport(payloads: ["system-0000.wav": payload([(text, 0, 15)])])
        let box = EventBox()
        let session = LiveTranscriptSession(
            configuration: configuration(callDirectory: directory, summaryIntervalSeconds: 0.05),
            readingTransport: transport,
            summarizer: FailingSummarizer()
        ) { box.append($0) }

        session.start()
        session.transcriber?.enqueue(chunk("system-0000.wav", start: 0, directory: directory))
        await session.transcriber?.waitForIdle()

        try? await Task.sleep(for: .milliseconds(250))
        // A failed summary is not a failed call: no summary is drawn, nothing is reported as a
        // problem, and the words are still there to read.
        #expect(box.summaries.isEmpty)
        #expect(box.failures.isEmpty)
        #expect(box.lines.map(\.text) == [text])
    }
}
