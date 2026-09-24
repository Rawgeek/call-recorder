import CallRecorderCore
import Foundation
import OSLog

/// What the live window learns from the transcriber.
enum LiveTranscriberEvent: Sendable {
    /// The model is loaded and the first chunk can be read.
    case ready
    /// Lines of the call, already placed on the recording's clock.
    case entries([LiveTranscriptEntry])
    /// How much audio is waiting to be read, and how much was given up on.
    case backlog(seconds: Double, droppedChunks: Int)
    /// The live path stopped working, with the sentence that explains it.
    case failed(String)
}

/// Turns the chunk files a tap writes into lines of live text.
///
/// One chunk is read at a time and the queue is ordered by where each chunk sits in the recording,
/// not by when it turned up: the two sides close their chunks independently, so the system's chunk
/// for the last fifteen seconds can be ready before the microphone's chunk for the minute before it.
/// Reading them in capture order is what lets the window show one conversation instead of two
/// streams that have to be followed at once.
///
/// The queue is bounded on purpose. A machine that cannot read a chunk in the time it takes to
/// speak one is behind for the rest of the call, and the honest answers are to keep the newest
/// audio and to say what was let go of — never to spend the meeting's memory on a preview of it.
actor LiveTranscriber {
    /// How much audio may wait to be read. Ten chunks is two and a half minutes of a call.
    static let maximumPendingChunks = 10

    private let transport: any LiveTranscriptionTransport
    private let prompt: String
    private let localSpeaker: String
    private let remoteSpeaker: String
    private let glossary: [GlossaryTerm]
    private let onEvent: @Sendable (LiveTranscriberEvent) -> Void
    private let logger = Logger(subsystem: "local.callrecorder.app", category: "live")

    private var pending: [LiveAudioTap.Chunk] = []
    private var inFlight: LiveAudioTap.Chunk?
    private var working = false
    private var hasFailed = false
    /// Set when the session is over. A chunk still arriving from a tap that has not been closed yet
    /// is dropped rather than read: the model behind it has been released, and starting it again
    /// for the tail of a call that has ended is how a server outlives its recording.
    private var hasStopped = false
    private var started = false
    private var droppedChunks = 0
    /// Chunks the tap has handed over that have not reached the actor yet.
    ///
    /// The tap calls `enqueue` from its own queue and cannot wait for an actor hop. Without this
    /// count, "everything handed over has been read" is true for a moment after every handover —
    /// because nothing has arrived yet — which is a race for a test and a lie for anything else.
    private let handover = HandoverCounter()
    /// The language the call turned out to be in, once one chunk has been confident about it.
    private var pinnedLanguage: String?

    init(
        transport: any LiveTranscriptionTransport,
        prompt: String,
        localSpeaker: String,
        remoteSpeaker: String,
        glossary: [GlossaryTerm],
        onEvent: @escaping @Sendable (LiveTranscriberEvent) -> Void
    ) {
        self.transport = transport
        self.prompt = prompt
        self.localSpeaker = localSpeaker
        self.remoteSpeaker = remoteSpeaker
        self.glossary = glossary
        self.onEvent = onEvent
    }

    /// Brings the model up before the first chunk is ready, so the first words do not wait for it.
    func start() async {
        guard !started, !hasFailed else { return }
        started = true
        do {
            try await transport.start()
            onEvent(.ready)
        } catch {
            fail(error)
        }
    }

    /// Hands over one closed chunk. Called from the tap's own queue.
    nonisolated func enqueue(_ chunk: LiveAudioTap.Chunk) {
        handover.increment()
        Task { await self.accept(chunk) }
    }

    /// Ends the work and the model behind it.
    func stop() async {
        hasStopped = true
        pending.removeAll()
        await transport.stop()
    }

    /// Waits until everything handed over has been read. Used by the stop path's tests.
    func waitForIdle(timeout: TimeInterval = 20) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if handover.count == 0, pending.isEmpty, !working { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: - The queue

    private func accept(_ chunk: LiveAudioTap.Chunk) {
        handover.decrement()
        guard !hasFailed, !hasStopped else { return }
        pending.append(chunk)
        pending.sort { $0.startSeconds < $1.startSeconds }
        if pending.count > Self.maximumPendingChunks {
            // The oldest goes: a preview is worth most at the end of the call, and the recording
            // itself keeps every word either way.
            pending.removeFirst()
            droppedChunks += 1
        }
        publishBacklog()
        guard !working else { return }
        working = true
        Task { await self.drain() }
    }

    private func drain() async {
        while let chunk = nextChunk() {
            guard !hasStopped else { break }
            inFlight = chunk
            publishBacklog()
            do {
                let data = try await transport.transcribe(
                    audioAt: chunk.fileURL,
                    prompt: prompt,
                    language: pinnedLanguage
                )
                let outcome = LiveTranscriptionDecoder.decode(
                    data,
                    chunk: chunk,
                    speaker: chunk.source == .microphone ? localSpeaker : remoteSpeaker,
                    glossary: glossary
                )
                pinLanguage(from: outcome)
                if !outcome.entries.isEmpty { onEvent(.entries(outcome.entries)) }
            } catch {
                discard(chunk)
                inFlight = nil
                fail(error)
                return
            }
            discard(chunk)
            inFlight = nil
            publishBacklog()
        }
        working = false
    }

    private func nextChunk() -> LiveAudioTap.Chunk? {
        guard !pending.isEmpty else { return nil }
        return pending.removeFirst()
    }

    /// Deletes a chunk once it has been read or given up on, so a two hour call does not leave two
    /// hours of audio in a folder that exists for a preview.
    private func discard(_ chunk: LiveAudioTap.Chunk) {
        try? FileManager.default.removeItem(at: chunk.fileURL)
    }

    private func pinLanguage(from outcome: LiveTranscriptionOutcome) {
        guard pinnedLanguage == nil, let language = outcome.detectedLanguage else { return }
        guard let probability = outcome.languageProbability, probability >= 0.6 else { return }
        pinnedLanguage = language
    }

    private func publishBacklog() {
        let waiting = pending.reduce(0) { $0 + $1.durationSeconds }
            + (inFlight?.durationSeconds ?? 0)
        onEvent(.backlog(seconds: waiting, droppedChunks: droppedChunks))
    }

    private func fail(_ error: any Error) {
        guard !hasFailed else { return }
        hasFailed = true
        pending.removeAll()
        working = false
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        logger.notice("live transcription stopped: \(message, privacy: .public)")
        onEvent(.failed(message))
    }
}

/// Counts chunks that have been handed over but have not reached the actor yet.
///
/// Its own type rather than two properties on the actor: the tap calls `enqueue` from its own
/// queue and cannot wait for an actor hop, so the number has to be readable and writable without
/// one. It is the difference between "everything has been read" and "nothing has arrived yet".
private final class HandoverCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() { lock.withLock { value += 1 } }
    func decrement() { lock.withLock { value -= 1 } }
    var count: Int { lock.withLock { value } }
}

/// What one chunk's JSON turned into.
struct LiveTranscriptionOutcome: Equatable, Sendable {
    let entries: [LiveTranscriptEntry]
    let detectedLanguage: String?
    let languageProbability: Double?
}

/// Reads whisper.cpp's answer for one chunk.
///
/// The rules here are the batch pipeline's, applied to a smaller piece of the same call: what the
/// model wrote but nobody said comes off first, then the glossary puts the names back the way the
/// library spells them, and a chunk that is nothing but a repeated loop is thrown away rather than
/// drawn. Amanu's notes call this out from the other side: a live view that shows a model's
/// artefacts teaches people not to trust the one that shows their words.
enum LiveTranscriptionDecoder {
    /// A segment the model was this sure was not speech is not shown.
    static let noSpeechProbabilityLimit = 0.6

    static func decode(
        _ data: Data,
        chunk: LiveAudioTap.Chunk,
        speaker: String,
        glossary: [GlossaryTerm]
    ) -> LiveTranscriptionOutcome {
        guard let response = try? JSONDecoder().decode(LiveWhisperResponse.self, from: data) else {
            return LiveTranscriptionOutcome(
                entries: [],
                detectedLanguage: nil,
                languageProbability: nil
            )
        }
        let segments = (response.segments ?? []).compactMap { segment -> TranscriptSegment? in
            guard segment.noSpeechProbability ?? 0 < noSpeechProbabilityLimit else { return nil }
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            // A stretch of audio that held no word is not drawn, whatever the model answered with:
            // a lone full stop, a run of dots, a dash. The 2026-09-22 call drew "Others 1:00 ." for
            // a far side that was close to silent, and a line like that teaches a reader to skim
            // past the side of the call they were trying to follow.
            guard text.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
            let start = chunk.startSeconds + max(0, segment.start)
            let end = chunk.startSeconds + max(segment.start, segment.end)
            return TranscriptSegment(
                startMs: Int((start * 1_000).rounded()),
                endMs: Int((end * 1_000).rounded()),
                text: text,
                source: chunk.source == .microphone ? .microphone : .system
            )
        }
        guard !segments.isEmpty else {
            return LiveTranscriptionOutcome(
                entries: [],
                detectedLanguage: response.detectedLanguage,
                languageProbability: response.detectedLanguageProbability
            )
        }
        // The artefacts first: a prompt echo is the model repeating the names it was given, and
        // drawing it would credit somebody with a sentence they never said.
        let cleaned = TranscriptArtifacts.filter(segments: segments).segments
        guard !cleaned.isEmpty else {
            return LiveTranscriptionOutcome(
                entries: [],
                detectedLanguage: response.detectedLanguage,
                languageProbability: response.detectedLanguageProbability
            )
        }
        // Then the spelling of the names, so a live line and the saved transcript agree about how
        // the people on the call are written.
        let transcript = WhisperTranscript(language: response.language ?? "", segments: cleaned)
            .applyingGlossary(terms: glossary).transcript
        // A chunk the model filled with a loop is thrown away whole, which is asked first: the pass
        // below would leave one line of it standing, and one line of a stuck decoder is still the
        // decoder talking rather than anybody in the call.
        guard !TranscriptQualityValidator.isRepetitive(transcript) else {
            return LiveTranscriptionOutcome(
                entries: [],
                detectedLanguage: response.detectedLanguage,
                languageProbability: response.detectedLanguageProbability
            )
        }
        // Then the speech this chunk holds twice. It has two shapes: the model reading the same run
        // of words again, and the room hearing the far side through the speakers a moment after the
        // tap took it. The batch pass has run the same rule over a whole call since it was written;
        // a chunk is that fault in miniature, and the 2026-09-22 call is why it belongs here too —
        // "BELLA: I would like to share with you" arrived twice a second for fifteen seconds, and a
        // window that draws a loop is a window nobody reads.
        let duplicates = TranscriptDeduplicator.deduplicate(segments: transcript.segments)
        let entries = duplicates.segments.map { segment in
            LiveTranscriptEntry(
                startSeconds: Double(segment.startMs) / 1_000,
                source: chunk.source,
                speaker: speaker,
                endSeconds: Double(segment.endMs) / 1_000,
                text: segment.text
            )
        }
        return LiveTranscriptionOutcome(
            entries: entries,
            detectedLanguage: response.detectedLanguage,
            languageProbability: response.detectedLanguageProbability
        )
    }
}

/// The part of whisper.cpp's `verbose_json` this app reads.
struct LiveWhisperResponse: Decodable {
    struct Segment: Decodable {
        let text: String
        let start: Double
        let end: Double
        let noSpeechProbability: Double?

        enum CodingKeys: String, CodingKey {
            case text
            case start
            case end
            case noSpeechProbability = "no_speech_prob"
        }
    }

    let language: String?
    let segments: [Segment]?
    let detectedLanguage: String?
    let detectedLanguageProbability: Double?

    enum CodingKeys: String, CodingKey {
        case language
        case segments
        case detectedLanguage = "detected_language"
        case detectedLanguageProbability = "detected_language_probability"
    }
}
