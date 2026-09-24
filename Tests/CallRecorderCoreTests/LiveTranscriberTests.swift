import Foundation
import Testing
@testable import CallRecorderApp
@testable import CallRecorderCore

/// Turning chunk files into lines of live text: the order they are read in, what happens when the
/// machine cannot keep up, and what the answer means.
@Suite("Live transcriber")
struct LiveTranscriberTests {
    /// A transcriber that answers with bytes the test chose, and remembers what it was asked.
    private final class StubTransport: LiveTranscriptionTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var payloads: [String: Data]
        private var failures: [String: String] = [:]
        private var order: [String] = []
        private var languages: [String?] = []
        private var started = false
        var delay: TimeInterval = 0
        /// Set by a test that needs chunks to pile up: the first read waits until `openGate`.
        var holdsUntilOpened = false
        private var gateOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        init(payloads: [String: Data]) {
            self.payloads = payloads
        }

        func fail(_ name: String, with message: String) {
            lock.withLock { failures[name] = message }
        }

        func start() async throws {
            lock.withLock { started = true }
        }

        func transcribe(audioAt url: URL, prompt: String, language: String?) async throws -> Data {
            let holds = lock.withLock { holdsUntilOpened }
            if holds { await waitForGate() }
            let delay = lock.withLock { self.delay }
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            let name = url.lastPathComponent
            lock.withLock {
                order.append(name)
                languages.append(language)
            }
            return try lock.withLock {
                if let message = failures[name] {
                    throw LiveTranscriptionError.requestFailed(message)
                }
                guard let payload = payloads[name] else {
                    throw LiveTranscriptionError.requestFailed("no answer for " + name)
                }
                return payload
            }
        }

        func stop() async {}

        func openGate() {
            let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                gateOpen = true
                let waiting = waiters
                waiters = []
                return waiting
            }
            for continuation in waiting { continuation.resume() }
        }

        private func waitForGate() async {
            await withCheckedContinuation { continuation in
                let open = lock.withLock { gateOpen }
                if open {
                    continuation.resume()
                } else {
                    lock.withLock { waiters.append(continuation) }
                }
            }
        }

        var servedOrder: [String] { lock.withLock { order } }
        var askedLanguages: [String?] { lock.withLock { languages } }
    }

    /// The events a transcriber reported, in the order it reported them.
    private final class EventBox: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [LiveTranscriberEvent] = []

        func append(_ event: LiveTranscriberEvent) {
            lock.withLock { events.append(event) }
        }

        var all: [LiveTranscriberEvent] { lock.withLock { events } }

        var lines: [LiveTranscriptEntry] {
            all.flatMap { event in
                if case let .entries(lines) = event { return lines }
                return []
            }
        }

        var failures: [String] {
            all.compactMap { event in
                if case let .failed(message) = event { return message }
                return nil
            }
        }

        var lastBacklog: (seconds: Double, dropped: Int)? {
            for event in all.reversed() {
                if case let .backlog(seconds, dropped) = event { return (seconds, dropped) }
            }
            return nil
        }
    }

    private func payload(
        _ segments: [(text: String, start: Double, end: Double)],
        language: String = "en",
        detected: String? = "english",
        probability: Double? = 0.9
    ) -> Data {
        var body: [String: Any] = ["language": language]
        body["segments"] = segments.map { segment in
            ["text": segment.text, "start": segment.start, "end": segment.end]
        }
        if let detected { body["detected_language"] = detected }
        if let probability { body["detected_language_probability"] = probability }
        return try! JSONSerialization.data(withJSONObject: body)
    }

    private func chunk(
        _ name: String,
        source: LiveAudioSource,
        start: Double,
        directory: URL
    ) -> LiveAudioTap.Chunk {
        let url = directory.appending(path: name)
        FileManager.default.createFile(atPath: url.path, contents: Data("audio".utf8))
        return LiveAudioTap.Chunk(
            source: source,
            index: 0,
            startSeconds: start,
            durationSeconds: 15,
            fileURL: url
        )
    }

    private func scratch() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "live-transcriber-" + UUID().uuidString, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test("a chunk that is waiting is read in capture order, whatever order it arrived in")
    func readsWaitingChunksInCaptureOrder() async throws {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = StubTransport(payloads: [
            "system-0000.wav": payload([("first", 0, 4)]),
            "system-0001.wav": payload([("second", 0, 4)]),
            "system-0002.wav": payload([("third", 0, 4)]),
        ])
        // The model is busy with the first chunk, so the next two wait — and they arrive in the
        // wrong order, which is what the two independent taps do to the queue.
        transport.holdsUntilOpened = true
        let box = EventBox()
        let transcriber = LiveTranscriber(
            transport: transport,
            prompt: "",
            localSpeaker: "You",
            remoteSpeaker: "Others",
            glossary: [],
            onEvent: { box.append($0) }
        )
        await transcriber.start()
        transcriber.enqueue(chunk("system-0000.wav", source: .system, start: 0, directory: directory))
        try await Task.sleep(for: .milliseconds(100))
        transcriber.enqueue(chunk("system-0002.wav", source: .system, start: 30, directory: directory))
        transcriber.enqueue(chunk("system-0001.wav", source: .system, start: 15, directory: directory))
        try await Task.sleep(for: .milliseconds(100))
        transport.openGate()
        await transcriber.waitForIdle()

        #expect(
            transport.servedOrder
                == ["system-0000.wav", "system-0001.wav", "system-0002.wav"]
        )
        #expect(box.lines.map(\.text) == ["first", "second", "third"])
    }

    @Test("a chunk is placed on the recording's clock, not on its own")
    func placesLinesOnTheClock() async throws {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = StubTransport(payloads: [
            "system-0002.wav": payload([("in the middle", 1.5, 4.0)])
        ])
        let box = EventBox()
        let transcriber = LiveTranscriber(
            transport: transport,
            prompt: "",
            localSpeaker: "You",
            remoteSpeaker: "Others",
            glossary: [],
            onEvent: { box.append($0) }
        )
        await transcriber.start()
        transcriber.enqueue(chunk("system-0002.wav", source: .system, start: 30, directory: directory))
        await transcriber.waitForIdle()
        #expect(box.lines.first?.startSeconds == 31.5)
        #expect(box.lines.first?.endSeconds == 34.0)
    }

    @Test("what the model wrote but nobody said is not drawn")
    func dropsArtefacts() async throws {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = StubTransport(payloads: [
            "microphone-0000.wav": payload([
                ("[BLANK_AUDIO]", 0, 2),
                ("the real sentence", 2, 5),
            ])
        ])
        let box = EventBox()
        let transcriber = LiveTranscriber(
            transport: transport,
            prompt: "",
            localSpeaker: "You",
            remoteSpeaker: "Others",
            glossary: [],
            onEvent: { box.append($0) }
        )
        await transcriber.start()
        transcriber.enqueue(chunk("microphone-0000.wav", source: .microphone, start: 0, directory: directory))
        await transcriber.waitForIdle()
        #expect(box.lines.map(\.text) == ["the real sentence"])
    }

    @Test("a chunk the model filled with a loop is thrown away rather than drawn")
    func dropsLoops() async throws {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repeated = (0..<24).map { (text: "thank you thank you", start: Double($0) / 2, end: Double($0) / 2 + 0.4) }
        let transport = StubTransport(payloads: [
            "system-0000.wav": payload(repeated)
        ])
        let box = EventBox()
        let transcriber = LiveTranscriber(
            transport: transport,
            prompt: "",
            localSpeaker: "You",
            remoteSpeaker: "Others",
            glossary: [],
            onEvent: { box.append($0) }
        )
        await transcriber.start()
        transcriber.enqueue(chunk("system-0000.wav", source: .system, start: 0, directory: directory))
        await transcriber.waitForIdle()
        #expect(box.lines.isEmpty)
    }

    // The 2026-09-22 call: the far side was close to silent, and the model answered the quiet with
    // a line of its own punctuation. It was drawn, and the window read "1:00 - ." under a speaker.
    @Test("a line with no word in it is not drawn")
    func dropsWordlessLines() async throws {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = StubTransport(payloads: [
            "system-0000.wav": payload([(".", 0, 1), ("...", 1, 2), ("-", 2, 3)])
        ])
        let box = EventBox()
        let transcriber = LiveTranscriber(
            transport: transport,
            prompt: "",
            localSpeaker: "You",
            remoteSpeaker: "Others",
            glossary: [],
            onEvent: { box.append($0) }
        )
        await transcriber.start()
        transcriber.enqueue(chunk("system-0000.wav", source: .system, start: 0, directory: directory))
        await transcriber.waitForIdle()
        #expect(box.lines.isEmpty)
    }

    // The same call, one line later: the model answered near-silence with the same sentence again
    // and again. The loop is drawn once, so the words on screen are the words that were said.
    @Test("a run the model repeated inside one chunk is drawn once")
    func collapsesRepeatsInOneChunk() async throws {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = StubTransport(payloads: [
            "system-0000.wav": payload([
                ("BELLA: I would like to share with you.", 0, 1),
                ("I would like to share with you.", 1, 2),
                ("I would like to share with you.", 2, 3),
                ("I would like to share with you.", 3, 4),
            ])
        ])
        let box = EventBox()
        let transcriber = LiveTranscriber(
            transport: transport,
            prompt: "",
            localSpeaker: "You",
            remoteSpeaker: "Others",
            glossary: [],
            onEvent: { box.append($0) }
        )
        await transcriber.start()
        transcriber.enqueue(chunk("system-0000.wav", source: .system, start: 0, directory: directory))
        await transcriber.waitForIdle()
        #expect(box.lines.count < 4)
        #expect(box.lines.allSatisfy { $0.text.contains("share with you") })
    }

    @Test("the glossary puts the names back the way the library spells them")
    func correctsNames() async throws {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = StubTransport(payloads: [
            "system-0000.wav": payload([("the globe x rate card changed", 0, 4)])
        ])
        let box = EventBox()
        let transcriber = LiveTranscriber(
            transport: transport,
            prompt: "",
            localSpeaker: "You",
            remoteSpeaker: "Others",
            glossary: [
                GlossaryTerm(
                    id: GlossaryTermID(rawValue: UUID()),
                    preferred: "Globex",
                    aliases: ["globe x"]
                )
            ],
            onEvent: { box.append($0) }
        )
        await transcriber.start()
        transcriber.enqueue(chunk("system-0000.wav", source: .system, start: 0, directory: directory))
        await transcriber.waitForIdle()
        #expect(box.lines.first?.text.contains("Globex") == true)
    }

    @Test("the call's language is settled once, from the first confident chunk")
    func pinsTheLanguage() async throws {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = StubTransport(payloads: [
            "system-0000.wav": payload([("privet", 0, 4)], language: "russian", detected: "russian", probability: 0.87),
            "system-0001.wav": payload(
                [("kak dela", 0, 4)],
                language: "russian",
                detected: "russian",
                probability: 0.9
            ),
        ])
        let box = EventBox()
        let transcriber = LiveTranscriber(
            transport: transport,
            prompt: "",
            localSpeaker: "You",
            remoteSpeaker: "Others",
            glossary: [],
            onEvent: { box.append($0) }
        )
        await transcriber.start()
        transcriber.enqueue(chunk("system-0000.wav", source: .system, start: 0, directory: directory))
        await transcriber.waitForIdle()
        transcriber.enqueue(chunk("system-0001.wav", source: .system, start: 15, directory: directory))
        await transcriber.waitForIdle()
        #expect(transport.askedLanguages == [nil, "russian"])
    }

    @Test("falling behind is said out loud, and the newest audio is the audio kept")
    func reportsBacklog() async throws {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        var payloads: [String: Data] = [:]
        for index in 0..<14 {
            payloads[String(format: "system-%04d.wav", index)] = payload([("line \(index)", 0, 4)])
        }
        let transport = StubTransport(payloads: payloads)
        // The first read waits, so the pile-up the rule is about is real rather than a race the
        // test hopes to win: one chunk in flight, then ten waiting, then the ones that go.
        transport.delay = 0.02
        transport.holdsUntilOpened = true
        let box = EventBox()
        let transcriber = LiveTranscriber(
            transport: transport,
            prompt: "",
            localSpeaker: "You",
            remoteSpeaker: "Others",
            glossary: [],
            onEvent: { box.append($0) }
        )
        await transcriber.start()
        for index in 0..<14 {
            transcriber.enqueue(
                chunk(
                    String(format: "system-%04d.wav", index),
                    source: .system,
                    start: Double(index) * 15,
                    directory: directory
                )
            )
        }
        // Long enough for the first chunk to be picked up and the rest to queue behind it.
        try await Task.sleep(for: .milliseconds(200))
        transport.openGate()
        await transcriber.waitForIdle()

        // Ten chunks may wait. One is being read and thirteen are waiting, so three of the oldest
        // waiting ones go, and the window is told how many.
        #expect(box.lastBacklog?.dropped == 3)
        #expect(!box.lines.map(\.text).contains("line 1"))
        #expect(!box.lines.map(\.text).contains("line 2"))
        #expect(box.lines.map(\.text).contains("line 4"))
        #expect(box.lines.map(\.text).last == "line 13")
    }

    @Test("a chunk the transcriber could not read stops the live text with a sentence")
    func reportsFailure() async throws {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = StubTransport(payloads: [:])
        transport.fail("system-0000.wav", with: "the model is gone")
        let box = EventBox()
        let transcriber = LiveTranscriber(
            transport: transport,
            prompt: "",
            localSpeaker: "You",
            remoteSpeaker: "Others",
            glossary: [],
            onEvent: { box.append($0) }
        )
        await transcriber.start()
        transcriber.enqueue(chunk("system-0000.wav", source: .system, start: 0, directory: directory))
        await transcriber.waitForIdle()
        #expect(box.failures.count == 1)
        #expect(box.failures.first?.contains("the model is gone") == true)
    }

    @Test("a chunk read after the recording ended is dropped, not read")
    func dropsLateChunks() async throws {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = StubTransport(payloads: [
            "system-0000.wav": payload([("the tail", 0, 4)])
        ])
        let box = EventBox()
        let transcriber = LiveTranscriber(
            transport: transport,
            prompt: "",
            localSpeaker: "You",
            remoteSpeaker: "Others",
            glossary: [],
            onEvent: { box.append($0) }
        )
        await transcriber.start()
        await transcriber.stop()
        transcriber.enqueue(chunk("system-0000.wav", source: .system, start: 0, directory: directory))
        await transcriber.waitForIdle(timeout: 1)
        #expect(box.lines.isEmpty)
        #expect(transport.servedOrder.isEmpty)
    }
}
