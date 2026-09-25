import CallRecorderCore
import Darwin
import Foundation

struct Diarizer: Sendable {
    let python: URL
    let script: URL
    let ffmpeg: URL?
    let timeout: TimeInterval

    init(
        python: URL,
        script: URL,
        ffmpeg: URL? = nil,
        timeout: TimeInterval = 90 * 60
    ) {
        self.python = python
        self.script = script
        self.ffmpeg = ffmpeg
        self.timeout = timeout
    }

    /// Runs diarization on a 16kHz mono WAV.
    ///
    /// A count reaches the script as a number to answer exactly, which is the slower of the two
    /// separations the script holds. Without one, the separation counts the voices it hears.
    func run(
        on waveURL: URL,
        numberOfSpeakers: Int?,
        cancellation: ProcessCancellation? = nil
    ) throws -> DiarizationResult {
        var arguments = [waveURL.path]
        if let numberOfSpeakers {
            arguments += ["--num-speakers", String(numberOfSpeakers)]
        }
        return try execute(arguments: arguments, cancellation: cancellation)
    }

    func check() throws {
        _ = try execute(arguments: ["--check"])
    }

    private func execute(
        arguments: [String],
        cancellation: ProcessCancellation? = nil,
        ffmpegOverride: URL? = nil
    ) throws -> DiarizationResult {
        let process = Process()
        process.executableURL = python
        process.arguments = [script.path] + arguments
        process.environment = Self.runtimeEnvironment(
            base: ProcessInfo.processInfo.environment,
            ffmpeg: ffmpegOverride ?? ffmpeg
        )
        let errorURL = FileManager.default.temporaryDirectory.appending(
            path: "diarizer-\(UUID().uuidString).stderr")
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        let errorFile = try FileHandle(forWritingTo: errorURL)
        // Both streams go to files rather than to pipes.
        //
        // The output used to arrive through a pipe read by a thread on the utility queue, and the
        // parent waited five seconds for that reader to finish after the script had exited. On a
        // busy machine the reader could still be waiting to be scheduled when the five seconds ran
        // out, and a diarization that failed for a real reason was then reported as an empty
        // output, which names the wrong fault and sends whoever reads the error to the wrong place.
        // A file has no reader to wait for: what the script wrote is on disk when it exits.
        let outputURL = FileManager.default.temporaryDirectory.appending(
            path: "diarizer-\(UUID().uuidString).stdout")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let outputFile = try FileHandle(forWritingTo: outputURL)
        defer {
            try? errorFile.close()
            try? outputFile.close()
            try? FileManager.default.removeItem(at: errorURL)
            try? FileManager.default.removeItem(at: outputURL)
        }
        process.standardError = errorFile
        process.standardOutput = outputFile
        let terminated = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in terminated.signal() }
        do {
            try process.run()
        } catch {
            throw error
        }
        // Waited on in short steps rather than one long block, so a stopped analysis and a run
        // that has overstayed its timeout both end the script instead of waiting for it.
        let deadline = Date().addingTimeInterval(timeout)
        while terminated.wait(timeout: .now() + 0.2) == .timedOut {
            if cancellation?.isCancelled == true {
                ProcessRunner.end(process)
                throw CancellationError()
            }
            if Date() >= deadline {
                process.terminate()
                if terminated.wait(timeout: .now() + 2) == .timedOut {
                    kill(process.processIdentifier, SIGKILL)
                    _ = terminated.wait(timeout: .now() + 2)
                }
                throw DiarizerError.timedOut
            }
        }
        let data = (try? Data(contentsOf: outputURL)) ?? Data()
        if let raw = try? JSONDecoder().decode(DiarizerRawOutput.self, from: data), let error = raw.error {
            throw DiarizerError.scriptFailed(DiagnosticsReporter.redacted(error: error))
        }
        guard process.terminationStatus == 0 else {
            let stderr = try String(contentsOf: errorURL, encoding: .utf8)
            throw DiarizerError.scriptFailed(
                DiagnosticsReporter.redacted(
                    error: "Exit \(process.terminationStatus): \(stderr.suffix(8_000))"
                ))
        }
        guard !data.isEmpty else { throw DiarizerError.emptyOutput }
        return try Self.decode(data)
    }

    func run(
        audio: URL,
        ffmpeg: URL,
        numberOfSpeakers: Int? = nil,
        cancellation: ProcessCancellation? = nil
    ) throws -> DiarizationResult {
        let wave = FileManager.default.temporaryDirectory.appending(
            path: "diarizing-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: wave) }
        _ = try ProcessRunner.runChecked(
            executable: ffmpeg,
            arguments: [
                "-v", "error", "-n", "-i", audio.path,
                "-vn", "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", wave.path,
            ],
            cancellation: cancellation)
        var arguments = [wave.path]
        if let numberOfSpeakers {
            arguments += ["--num-speakers", String(numberOfSpeakers)]
        }
        return try execute(
            arguments: arguments,
            cancellation: cancellation,
            ffmpegOverride: ffmpeg
        )
    }

    /// TorchCodec loads FFmpeg's shared libraries at runtime. A GUI app does not inherit
    /// Homebrew's shell setup, so the executable may be found while its dylibs are not. Derive
    /// the library directory from the exact ffmpeg binary the app selected and expose it only to
    /// the speaker-analysis child process.
    static func runtimeEnvironment(base: [String: String], ffmpeg: URL?) -> [String: String] {
        guard let ffmpeg else { return base }
        let libraryDirectory = ffmpeg
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "lib", directoryHint: .isDirectory)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: libraryDirectory.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else { return base }

        var environment = base
        var paths = (base["DYLD_FALLBACK_LIBRARY_PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        if !paths.contains(libraryDirectory.path) {
            paths.insert(libraryDirectory.path, at: 0)
        }
        environment["DYLD_FALLBACK_LIBRARY_PATH"] = paths.joined(separator: ":")
        return environment
    }

    static func decode(_ data: Data) throws -> DiarizationResult {
        let raw = try JSONDecoder().decode(DiarizerRawOutput.self, from: data)
        if let error = raw.error { throw DiarizerError.scriptFailed(error) }
        return try result(from: raw)
    }

    private static func result(from raw: DiarizerRawOutput) throws -> DiarizationResult {
        let turns = (raw.segments ?? []).map {
            DiarizationTurn(start: $0.start, end: $0.end, speakerLabel: $0.speaker)
        }
        var seenLabels = Set<String>()
        let clusters = try (raw.speakers ?? []).map { speaker in
            guard
                !speaker.speaker.isEmpty,
                seenLabels.insert(speaker.speaker).inserted,
                speaker.embedding.count == 256,
                speaker.embedding.allSatisfy(\.isFinite)
            else { throw DiarizerError.invalidEmbedding }
            let norm = sqrt(speaker.embedding.reduce(0) { $0 + $1 * $1 })
            guard norm.isFinite, abs(norm - 1) < 0.02 else {
                throw DiarizerError.invalidEmbedding
            }
            let duration =
                turns
                .filter { $0.speakerLabel == speaker.speaker }
                .reduce(0) { $0 + max(0, $1.end - $1.start) }
            return DiarizedSpeakerCluster(
                speakerLabel: speaker.speaker,
                embedding: speaker.embedding.map(Float.init),
                speechDurationSeconds: duration
            )
        }
        guard clusters.isEmpty || raw.model?.isEmpty == false else {
            throw DiarizerError.invalidEmbedding
        }
        return DiarizationResult(
            modelVersion: raw.model,
            turns: turns,
            clusters: clusters
        )
    }

    struct DiarizerRawOutput: Decodable {
        let error: String?
        let model: String?
        let segments: [Segment]?
        let speakers: [Speaker]?

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let array = try? container.decode([Segment].self) {
                error = nil
                model = nil
                segments = array
                speakers = nil
            } else {
                let obj = try container.decode(ObjectOutput.self)
                error = obj.error
                model = obj.model
                segments = obj.segments
                speakers = obj.speakers
            }
        }

        struct Segment: Decodable {
            let start: Double
            let end: Double
            let speaker: String
        }

        struct Speaker: Decodable {
            let speaker: String
            let embedding: [Double]
        }

        private struct ObjectOutput: Decodable {
            let error: String?
            let model: String?
            let segments: [Segment]?
            let speakers: [Speaker]?
        }
    }
}

struct DiarizationResult: Equatable, Sendable {
    let modelVersion: String?
    let turns: [DiarizationTurn]
    let clusters: [DiarizedSpeakerCluster]
}

struct DiarizedSpeakerCluster: Equatable, Sendable {
    let speakerLabel: String
    let embedding: [Float]
    let speechDurationSeconds: Double
}

struct DiarizationTurn: Equatable {
    let start: Double  // seconds
    let end: Double  // seconds
    let speakerLabel: String  // "SPEAKER_00" etc.
}

/// Joins the voices a recording was separated into when two of them are the same person.
///
/// Diarization returns whole voices, and one voice can come back in pieces. The 2026-09-18 17:47
/// call is one: one speaker was separated into two clusters of about two and a half minutes each,
/// while a third cluster held twelve minutes of somebody else. The review window then offers two
/// people to name where there is one, and the transcript draws two names for one voice.
///
/// Two clusters are the same voice when their centroids are as close as the policy already says two
/// fragments of one recording have to be for one person to be named on both of them. That is the
/// test the matcher uses when it lets one person hold two fragments of a call, asked one step
/// earlier: not "is this the person", but "is this the same voice at all".
enum DiarizationVoiceMerge {
    static func mergingSplitVoices(
        _ result: DiarizationResult,
        policy: SpeakerMatchPolicy
    ) -> (result: DiarizationResult, mergedClusters: Int) {
        guard result.clusters.count > 1 else { return (result, 0) }

        var parent = Array(result.clusters.indices)
        func root(_ index: Int) -> Int {
            var index = index
            while parent[index] != index { index = parent[index] }
            return index
        }
        func join(_ left: Int, _ right: Int) {
            let leftRoot = root(left)
            let rightRoot = root(right)
            guard leftRoot != rightRoot else { return }
            // The lower index stays the root, so the merged result is ordered the way the clusters
            // arrived rather than the way the pairs were compared.
            parent[max(leftRoot, rightRoot)] = min(leftRoot, rightRoot)
        }

        func asSpeakerCluster(_ cluster: DiarizedSpeakerCluster) -> SpeakerCluster {
            SpeakerCluster(
                id: SpeakerClusterID(rawValue: UUID()),
                modelVersion: result.modelVersion ?? "unknown",
                embedding: cluster.embedding,
                speechDurationMilliseconds: Int(
                    max(0, cluster.speechDurationSeconds * 1_000).rounded()
                )
            )
        }

        for left in result.clusters.indices {
            for right in result.clusters.indices where right > left {
                guard
                    let similarity = SpeakerMatcher.similarity(
                        asSpeakerCluster(result.clusters[left]),
                        asSpeakerCluster(result.clusters[right])
                    ),
                    similarity >= Double(policy.splitVoiceSimilarity)
                else { continue }
                join(left, right)
            }
        }

        var membersByRoot: [Int: [Int]] = [:]
        for index in result.clusters.indices {
            membersByRoot[root(index), default: []].append(index)
        }
        guard membersByRoot.values.contains(where: { $0.count > 1 }) else { return (result, 0) }

        var merged: [DiarizedSpeakerCluster] = []
        var labelSurvivor: [String: String] = [:]
        var mergedClusters = 0
        var handled = Set<Int>()
        for index in result.clusters.indices where !handled.contains(index) {
            let members = membersByRoot[root(index)] ?? [index]
            handled.formUnion(members)
            // The voice that spoke longest keeps its label and its centroid. The others are the same
            // voice heard in pieces, and their speech is added to it rather than thrown away.
            guard
                let survivor = members.max(by: { left, right in
                    let leftSeconds = result.clusters[left].speechDurationSeconds
                    let rightSeconds = result.clusters[right].speechDurationSeconds
                    if leftSeconds != rightSeconds { return leftSeconds < rightSeconds }
                    return left > right
                })
            else { continue }
            let speech = members.reduce(0.0) { $0 + result.clusters[$1].speechDurationSeconds }
            merged.append(
                DiarizedSpeakerCluster(
                    speakerLabel: result.clusters[survivor].speakerLabel,
                    embedding: result.clusters[survivor].embedding,
                    speechDurationSeconds: speech
                )
            )
            for member in members where member != survivor {
                labelSurvivor[result.clusters[member].speakerLabel] = result.clusters[survivor]
                    .speakerLabel
                mergedClusters += 1
            }
        }
        let turns = result.turns.map { turn -> DiarizationTurn in
            guard let label = labelSurvivor[turn.speakerLabel] else { return turn }
            return DiarizationTurn(start: turn.start, end: turn.end, speakerLabel: label)
        }
        return (
            DiarizationResult(modelVersion: result.modelVersion, turns: turns, clusters: merged),
            mergedClusters
        )
    }
}

enum DiarizerError: LocalizedError, Equatable {
    case emptyOutput
    case scriptFailed(String)
    case invalidEmbedding
    case timedOut
    case runtimeUnavailable
    case noSpeakersDetected

    var errorDescription: String? {
        switch self {
        case .emptyOutput: "Diarization produced no output."
        case .scriptFailed(let msg): "Diarization failed: \(msg)"
        case .invalidEmbedding: "Diarization produced an invalid speaker embedding."
        case .timedOut: "Diarization timed out and was stopped. Retry it from Recovery."
        case .runtimeUnavailable:
            "Local speaker-analysis runtime is missing. Choose its Python environment in Review. Your audio and transcript are safe."
        case .noSpeakersDetected:
            "Speech was transcribed, but no usable speakers were detected. Audio is retained. Retry speaker detection from Review."
        }
    }
}

enum SegmentMerger {
    /// What the merge did to a call's labels, so a caller can report the change rather than trust it.
    struct Outcome: Equatable {
        let segments: [TranscriptSegment]
        /// Fragments too short to hold a turn that took the voice of the segment before them.
        let snappedSegments: Int
        /// Runs of one voice too short to be a turn that were folded into the run before them.
        let absorbedRuns: Int
        /// How many times the label changes from one segment to the next.
        ///
        /// This is the number the merge exists to lower. The 2026-09-18 call came out of the plain
        /// overlap rule with 257 changes across 277 rendered turns -- a speaker switch every 1.1
        /// lines in an eleven-person standup, which is a boundary drawn badly rather than a meeting.
        let labelChanges: Int
    }

    /// How short a segment has to be before it cannot hold a turn of its own.
    ///
    /// Two seconds, or five words. Segments run about two seconds, and diarization turns
    /// run for tens of seconds, so a short segment that lands on the other side of a turn boundary
    /// is the boundary being imprecise. A short segment in the middle of a long turn is the same
    /// problem seen from the other side.
    static let shortFragmentSeconds = 2.0
    static let shortFragmentWords = 5

    /// How much of the best overlap a neighbouring voice needs before a short fragment keeps it.
    ///
    /// Half. A voice that was active for half of a short fragment's length was very likely the one
    /// speaking through it, and the segment is too short for the difference to be a turn. Below
    /// half, the fragment is a real interjection and its own label stays.
    static let neighbourOverlapShare = 0.5

    /// Merges diarization speaker labels into transcript segments by timestamp overlap.
    /// Assigns speakerIndex by order of first appearance (0, 1, 2…).
    /// The renderer maps these to "Speaker 1", "Speaker 2", etc.
    static func merge(
        speechSegments: [TranscriptSegment],
        diarization: [DiarizationTurn]
    ) -> [TranscriptSegment] {
        merging(speechSegments: speechSegments, diarization: diarization).segments
    }

    /// The merge, with what it changed.
    ///
    /// Plain greatest-overlap labelling was measured on the 2026-09-18 call and produced a label
    /// change every 1.1 rendered lines: a fragment inside a longer turn picked up the voice on the
    /// other side of a diarization boundary, so a name flipped back and forth across a monologue.
    /// Three rules hold a turn together, in order: a short fragment takes the voice of the segment
    /// before it when that voice was nearly as active in it as the winner; a short fragment no turn
    /// covers takes the voice of the turn beside it; and a short run of one voice between runs of
    /// another is folded into the run before it.
    static func merging(
        speechSegments: [TranscriptSegment],
        diarization: [DiarizationTurn]
    ) -> Outcome {
        guard !diarization.isEmpty else {
            return Outcome(
                segments: speechSegments,
                snappedSegments: 0,
                absorbedRuns: 0,
                labelChanges: 0
            )
        }

        var speakerIndexMap = [String: Int]()
        for turn in diarization where speakerIndexMap[turn.speakerLabel] == nil {
            speakerIndexMap[turn.speakerLabel] = speakerIndexMap.count
        }

        // How much of each segment each voice covers, by label.
        let coverage: [[String: Double]] = speechSegments.map { segment in
            let segStart = Double(segment.startMs) / 1000.0
            let segEnd = Double(segment.endMs) / 1000.0
            var overlaps: [String: Double] = [:]
            for turn in diarization {
                let overlap = min(segEnd, turn.end) - max(segStart, turn.start)
                if overlap > 0 { overlaps[turn.speakerLabel, default: 0] += overlap }
            }
            return overlaps
        }

        // Pass one: the greatest overlap wins, unless the fragment is too short to hold a turn and
        // the voice already open on the line before was nearly as active in it.
        var labels = [String?](repeating: nil, count: speechSegments.count)
        var snapped = 0
        for index in speechSegments.indices {
            let overlaps = coverage[index]
            guard
                let best = overlaps.max(by: { left, right in
                    left.value == right.value
                        ? left.key > right.key  // a stable winner when two voices tie
                        : left.value < right.value
                })
            else { continue }
            let openVoice: String? = index > 0 ? labels[index - 1] : nil
            guard
                isShortFragment(speechSegments[index]),
                let previous = openVoice,
                previous != best.key,
                let previousOverlap = overlaps[previous],
                previousOverlap >= best.value * neighbourOverlapShare
            else {
                labels[index] = best.key
                continue
            }
            labels[index] = previous
            snapped += 1
        }

        // Pass two: a short fragment no turn covers takes the voice of the turn beside it. One of
        // these is the six characters the 2026-09-18 library renders as "Speaker 1", a tag the
        // diarization never gave and the renderer invented.
        for index in speechSegments.indices where labels[index] == nil {
            guard isShortFragment(speechSegments[index]) else { continue }
            if index > 0, let previous = labels[index - 1] {
                labels[index] = previous
                snapped += 1
            } else if index + 1 < labels.count, let next = labels[index + 1] {
                labels[index] = next
                snapped += 1
            }
        }

        // Pass three: a run of one voice shorter than a turn, between runs of another voice, is the
        // same boundary problem seen from the other side. It joins the run before it.
        var absorbed = 0
        var index = 0
        while index < labels.count {
            guard let label = labels[index] else {
                index += 1
                continue
            }
            var last = index
            var seconds = 0.0
            while last < labels.count, labels[last] == label {
                seconds += Double(speechSegments[last].endMs - speechSegments[last].startMs) / 1000
                last += 1
            }
            if seconds <= shortFragmentSeconds, index > 0, let previous = labels[index - 1],
                previous != label {
                for position in index..<last { labels[position] = previous }
                absorbed += 1
            }
            index = last
        }

        var changes = 0
        var previousLabel: String?
        for label in labels {
            guard let label else { continue }
            if let previousLabel, previousLabel != label { changes += 1 }
            previousLabel = label
        }

        let merged = zip(speechSegments, labels).map { segment, label -> TranscriptSegment in
            guard let label, let idx = speakerIndexMap[label] else { return segment }
            return TranscriptSegment(
                startMs: segment.startMs,
                endMs: segment.endMs,
                text: segment.text,
                speakerIndex: idx,
                source: segment.source
            )
        }
        return Outcome(
            segments: merged,
            snappedSegments: snapped,
            absorbedRuns: absorbed,
            labelChanges: changes
        )
    }

    /// Whether a segment is too short to hold a turn of its own.
    static func isShortFragment(_ segment: TranscriptSegment) -> Bool {
        let seconds = Double(segment.endMs - segment.startMs) / 1000
        let words = segment.text.split(whereSeparator: { $0.isWhitespace }).count
        return seconds <= shortFragmentSeconds || words <= shortFragmentWords
    }

    /// Whether a segment runs long enough to be a turn of its own.
    ///
    /// The word count above is left out on purpose. "Remote voice." over ten seconds is two words
    /// and still one person speaking, so a segment like that is a turn that is waiting for a voice.
    /// The word count answers a boundary question -- whether a short piece belongs to the turn
    /// beside it -- which is not the question a caller of this one is asking.
    static func runsLongEnoughForATurn(_ segment: TranscriptSegment) -> Bool {
        Double(segment.endMs - segment.startMs) / 1000 > shortFragmentSeconds
    }
}
