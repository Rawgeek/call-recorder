import CallRecorderCore
import Foundation

enum MediaFinalizerError: LocalizedError {
    case noSegments
    case noAudio(URL)
    case unreadableOutput(URL)

    var errorDescription: String? {
        switch self {
        case .noSegments:
            "No recorded audio segments were found."
        case let .noAudio(url):
            "The recording contains no audio: \(url.lastPathComponent)"
        case let .unreadableOutput(url):
            "The saved audio could not be verified: \(url.lastPathComponent)"
        }
    }
}

struct FinalizedAudioSources: Equatable, Sendable {
    let system: URL?
    let microphone: URL?
}

struct MediaFinalizer: Sendable {
    let ffmpeg: URL
    let ffprobe: URL

    /// Writes the two sides of a call as files anything can read, and nothing else.
    ///
    /// This is what the pipeline reads: the transcriber takes the system and microphone files
    /// apart, and the diarizer works on the system side. Nothing is mixed here,
    /// because a mix is a second encode of the whole call and no part of the transcript needs it —
    /// see `writeCompatibilityMix`.
    func finalizeTracks(
        segments: [CaptureSegment],
        destination: URL
    ) async throws -> FinalizedAudioSources {
        try await Task.detached {
            try finalizeTracksSynchronously(segments: segments, destination: destination)
        }.value
    }

    /// Writes the one file a person plays a call from, out of the two sides already on disk.
    ///
    /// This is the expensive half: both sides are decoded, mixed, and encoded again, and an hour of
    /// call costs minutes of work. It is therefore not part of finalizing a recording. It runs once
    /// the person has chosen to keep the audio, after the transcript is written, and it returns the
    /// file that is already there rather than writing it twice.
    func writeCompatibilityMix(
        system: URL?,
        microphone: URL?,
        destination: URL
    ) async throws -> URL {
        try await Task.detached {
            try finalizeCompatibilityMix(
                system: system,
                microphone: microphone,
                destination: destination
            )
        }.value
    }

    /// The sides of a finished call that are on disk, under the names this class writes.
    static func existingTracks(in directory: URL) -> (system: URL?, microphone: URL?) {
        let system = directory.appending(path: "system.m4a")
        let microphone = directory.appending(path: "microphone.m4a")
        return (
            FileManager.default.fileExists(atPath: system.path) ? system : nil,
            FileManager.default.fileExists(atPath: microphone.path) ? microphone : nil
        )
    }

    private func finalizeTracksSynchronously(
        segments: [CaptureSegment],
        destination: URL
    ) throws -> FinalizedAudioSources {
        guard !segments.isEmpty else { throw MediaFinalizerError.noSegments }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let ordered = segments.sorted { $0.index < $1.index }
        let timedSources = ordered.flatMap { [$0.system, $0.microphone].compactMap { $0 } }
            .filter { $0.durationSeconds > 0 && $0.firstPresentationSeconds.isFinite }
        let timelineOrigin = timedSources.map(\.firstPresentationSeconds).min()
        let system = try finalizeTrack(
            ordered.compactMap(\.system),
            fileName: "system.m4a",
            destination: destination,
            timelineOrigin: timelineOrigin
        )
        let microphone = try finalizeTrack(
            ordered.compactMap(\.microphone),
            fileName: "microphone.m4a",
            destination: destination,
            timelineOrigin: timelineOrigin
        )
        guard system != nil || microphone != nil else { throw MediaFinalizerError.noSegments }
        return FinalizedAudioSources(system: system, microphone: microphone)
    }

    private func finalizeTrack(
        _ sources: [CapturedAudioSource],
        fileName: String,
        destination: URL,
        timelineOrigin: Double?
    ) throws -> URL? {
        guard !sources.isEmpty else { return nil }
        let finalURL = destination.appending(path: fileName)
        if FileManager.default.fileExists(atPath: finalURL.path) {
            guard try duration(of: finalURL) > 0 else {
                throw MediaFinalizerError.unreadableOutput(finalURL)
            }
            return finalURL
        }

        let token = UUID().uuidString
        let stem = finalURL.deletingPathExtension().lastPathComponent
        let partialURL = destination.appending(path: ".\(stem)-\(token).partial.m4a")
        defer { try? FileManager.default.removeItem(at: partialURL) }

        // One source is the whole track, so it is copied rather than decoded and written out as a
        // wave. A copy is a remux, which finishes at once; a wave is a gigabyte of writes with a
        // second encode behind it. This is the shape of every call without a pause, and the copy
        // used to be taken only when the manifest arrived with durations — which a finished
        // recording never has. The 2026-09-21 call paid for that: the wait before its transcript
        // started was three passes over an hour and twelve minutes of audio.
        if sources.count == 1, try canBeCopiedIntoM4A(sources[0].fileURL) {
            try copyTrack(sources[0].fileURL, to: partialURL)
        } else if
            let timelineOrigin,
            sources.allSatisfy({
                $0.durationSeconds > 0
                    && $0.durationSeconds.isFinite
                    && $0.firstPresentationSeconds.isFinite
            })
        {
            // Several pieces of one side are laid on the timeline of the recording and encoded
            // once, rather than each being written out as a wave and read back to be joined.
            try renderTimeline(sources, origin: timelineOrigin, to: partialURL)
        } else {
            let waveURLs = sources.indices.map {
                destination.appending(path: ".finalizing-\(stem)-\(token)-\($0).wav")
            }
            defer { waveURLs.forEach { try? FileManager.default.removeItem(at: $0) } }
            for (source, waveURL) in zip(sources, waveURLs) {
                try renderWave(from: source.fileURL, to: waveURL)
            }
            try join(waveURLs, at: partialURL)
        }
        guard try duration(of: partialURL) > 0 else {
            throw MediaFinalizerError.unreadableOutput(partialURL)
        }
        try FileManager.default.moveItem(at: partialURL, to: finalURL)
        return finalURL
    }

    private func renderTimeline(
        _ sources: [CapturedAudioSource],
        origin: Double,
        to destination: URL
    ) throws {
        var arguments = ["-v", "error", "-y"]
        for source in sources {
            arguments.append(contentsOf: ["-i", source.fileURL.path])
        }
        var filters: [String] = []
        for (index, source) in sources.enumerated() {
            let delay = Int(max(0, (source.firstPresentationSeconds - origin) * 1_000).rounded())
            filters.append(
                "[\(index):a:0]aresample=48000,"
                    + "aformat=sample_rates=48000:channel_layouts=stereo,"
                    + "adelay=delays=\(delay):all=1[a\(index)]"
            )
        }
        let inputs = sources.indices.map { "[a\($0)]" }.joined()
        filters.append(
            "\(inputs)amix=inputs=\(sources.count):duration=longest:normalize=0,"
                + "alimiter=limit=0.95[out]"
        )
        arguments.append(contentsOf: [
            "-filter_complex", filters.joined(separator: ";"),
            "-map", "[out]", "-vn", "-c:a", "aac", "-b:a", "192k",
            "-movflags", "+faststart", destination.path,
        ])
        _ = try run(ffmpeg, arguments)
    }

    private func finalizeCompatibilityMix(
        system: URL?,
        microphone: URL?,
        destination: URL
    ) throws -> URL {
        let finalURL = destination.appending(path: "call.m4a")
        if FileManager.default.fileExists(atPath: finalURL.path) {
            guard try duration(of: finalURL) > 0 else {
                throw MediaFinalizerError.unreadableOutput(finalURL)
            }
            return finalURL
        }
        let sources = [system, microphone].compactMap { $0 }
        guard !sources.isEmpty else { throw MediaFinalizerError.noSegments }
        let partialURL = destination.appending(path: ".call-\(UUID().uuidString).partial.m4a")
        defer { try? FileManager.default.removeItem(at: partialURL) }
        if sources.count == 1 {
            try join(sources, at: partialURL)
        } else {
            var arguments = ["-v", "error", "-y"]
            for source in sources { arguments.append(contentsOf: ["-i", source.path]) }
            arguments.append(contentsOf: [
                "-filter_complex",
                "[0:a:0][1:a:0]amix=inputs=2:duration=longest:normalize=0,"
                    + "alimiter=limit=0.95[out]",
                "-map", "[out]", "-vn", "-c:a", "aac", "-b:a", "192k",
                "-movflags", "+faststart", partialURL.path,
            ])
            _ = try run(ffmpeg, arguments)
        }
        guard try duration(of: partialURL) > 0 else {
            throw MediaFinalizerError.unreadableOutput(partialURL)
        }
        try FileManager.default.moveItem(at: partialURL, to: finalURL)
        return finalURL
    }

    private func renderWave(from source: URL, to destination: URL) throws {
        let trackCount = try audioTrackCount(of: source)
        guard trackCount > 0 else { throw MediaFinalizerError.noAudio(source) }

        var arguments = ["-v", "error", "-y", "-i", source.path]
        if trackCount == 1 {
            arguments.append(contentsOf: ["-map", "0:a:0"])
        } else {
            let inputs = (0..<trackCount).map { "[0:a:\($0)]" }.joined()
            arguments.append(contentsOf: [
                "-filter_complex",
                "\(inputs)amix=inputs=\(trackCount):duration=longest:normalize=0,alimiter=limit=0.95[a]",
                "-map", "[a]",
            ])
        }
        arguments.append(contentsOf: [
            "-vn", "-ar", "48000", "-ac", "2", "-c:a", "pcm_s16le", destination.path,
        ])
        _ = try run(ffmpeg, arguments)
    }

    private func join(_ sources: [URL], at destination: URL) throws {
        // One source is already the finished audio, so it is copied rather than decoded and encoded
        // a second time.
        if sources.count == 1, let source = sources.first, try canBeCopiedIntoM4A(source) {
            try copyTrack(source, to: destination)
            return
        }
        var arguments = ["-v", "error", "-y"]
        for source in sources {
            arguments.append(contentsOf: ["-i", source.path])
        }
        if sources.count == 1 {
            arguments.append(contentsOf: ["-map", "0:a:0"])
        } else {
            let inputs = sources.indices.map { "[\($0):a:0]" }.joined()
            arguments.append(contentsOf: [
                "-filter_complex", "\(inputs)concat=n=\(sources.count):v=0:a=1[out]",
                "-map", "[out]",
            ])
        }
        arguments.append(contentsOf: [
            "-vn", "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart", destination.path,
        ])
        _ = try run(ffmpeg, arguments)
    }

    private func duration(of url: URL) throws -> Double {
        let result = try run(
            ffprobe,
            [
                "-v", "error", "-show_entries", "format=duration",
                "-of", "default=noprint_wrappers=1:nokey=1", url.path,
            ]
        )
        return Double(result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    /// Remuxes one finished recording into its final file without re-encoding it.
    private func copyTrack(_ source: URL, to destination: URL) throws {
        _ = try run(
            ffmpeg,
            [
                "-v", "error", "-y", "-i", source.path,
                "-map", "0:a:0", "-vn", "-c:a", "copy",
                "-movflags", "+faststart", destination.path,
            ]
        )
    }

    /// How many audio tracks a file holds.
    private func audioTrackCount(of url: URL) throws -> Int {
        let probe = try run(
            ffprobe,
            [
                "-v", "error", "-select_streams", "a",
                "-show_entries", "stream=index", "-of", "csv=p=0", url.path,
            ]
        )
        return probe.standardOutput.split(whereSeparator: \Character.isNewline).count
    }

    /// Whether a file can be dropped into an audio-only MP4 as it is.
    ///
    /// Only a track that is already AAC, and only when there is exactly one of them. The
    /// intermediate files this class writes while scoring a timeline are PCM inside a wave, and a
    /// wave copied into an m4a fails at the muxer: the container cannot name that codec.
    private func canBeCopiedIntoM4A(_ url: URL) throws -> Bool {
        guard try audioTrackCount(of: url) == 1 else { return false }
        let probe = try run(
            ffprobe,
            [
                "-v", "error", "-select_streams", "a:0",
                "-show_entries", "stream=codec_name",
                "-of", "default=noprint_wrappers=1:nokey=1", url.path,
            ]
        )
        return probe.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) == "aac"
    }

    private func run(_ executable: URL, _ arguments: [String]) throws -> ProcessResult {
        try ProcessRunner.runChecked(executable: executable, arguments: arguments)
    }
}
