import CallRecorderCore
import Foundation
import OSLog

/// Cuts and keeps the short clips the speaker review plays.
///
/// Playing the recording itself meant playing the room tone around the words, and a diarized turn
/// can hold a long pause. The clip is cut once, with the silence removed, and kept, so pressing
/// play again is instant and the filter runs once per excerpt.
struct SpeakerSampleBuilder: Sendable {
    let ffmpeg: URL
    let ffprobe: URL
    let directory: URL

    private let logger = Logger(subsystem: "local.callrecorder.app", category: "samples")

    enum SampleError: LocalizedError {
        case emptyCut

        var errorDescription: String? {
            "The excerpt could not be cut out of the recording."
        }
    }

    func sampleURL(callID: CallID, startMilliseconds: Int, endMilliseconds: Int) -> URL {
        directory
            .appending(path: callID.rawValue.uuidString, directoryHint: .isDirectory)
            .appending(path: "\(startMilliseconds)-\(endMilliseconds).m4a")
    }

    /// Returns the clip, cutting it the first time it is asked for.
    func sample(
        callID: CallID,
        startMilliseconds: Int,
        endMilliseconds: Int,
        audio: URL
    ) async throws -> URL {
        let destination = sampleURL(
            callID: callID,
            startMilliseconds: startMilliseconds,
            endMilliseconds: endMilliseconds
        )
        if FileManager.default.fileExists(atPath: destination.path) { return destination }
        try await Task.detached {
            try cut(
                destination: destination,
                audio: audio,
                startMilliseconds: startMilliseconds,
                endMilliseconds: endMilliseconds
            )
        }.value
        return destination
    }

    private func cut(
        destination: URL,
        audio: URL,
        startMilliseconds: Int,
        endMilliseconds: Int
    ) throws {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // ffmpeg chooses its muxer from the extension, so the part-written file keeps the one the
        // finished file has. "clip.m4a.partial" is a name it refuses to write at all.
        let partial = destination
            .deletingPathExtension()
            .appendingPathExtension("partial")
            .appendingPathExtension(destination.pathExtension)
        _ = try? FileManager.default.removeItem(at: partial)

        _ = try ProcessRunner.runChecked(
            executable: ffmpeg,
            arguments: SpeakerSampleCut.arguments(
                audio: audio,
                destination: partial,
                startMilliseconds: startMilliseconds,
                endMilliseconds: endMilliseconds
            )
        )
        // An excerpt that is silence from end to end comes back empty. The plain cut is still
        // worth hearing — it says what the recording holds — so the caller gets that instead.
        if duration(of: partial) < SpeakerSampleCut.minimumSeconds {
            logger.notice("an excerpt came back empty after trimming; keeping the plain cut")
            _ = try ProcessRunner.runChecked(
                executable: ffmpeg,
                arguments: SpeakerSampleCut.plainArguments(
                    audio: audio,
                    destination: partial,
                    startMilliseconds: startMilliseconds,
                    endMilliseconds: endMilliseconds
                )
            )
        }
        guard duration(of: partial) >= SpeakerSampleCut.minimumSeconds else {
            _ = try? FileManager.default.removeItem(at: partial)
            throw SampleError.emptyCut
        }
        _ = try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: partial, to: destination)
    }

    private func duration(of url: URL) -> Double {
        guard
            let result = try? ProcessRunner.run(
                executable: ffprobe,
                arguments: [
                    "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", url.path,
                ]
            )
        else { return 0 }
        return Double(result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    /// Removes clips kept for excerpts nobody has listened to in a while.
    ///
    /// The clips are a cache: the recording they came from is the record. Keeping a fortnight
    /// covers a review that was started and finished later without letting the cache grow for
    /// every call the app has ever seen.
    func prune(olderThanDays days: Int = 14) {
        let fileManager = FileManager.default
        guard
            let callDirectories = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey]
            )
        else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 24 * 60 * 60)
        for callDirectory in callDirectories {
            let modified = (try? callDirectory.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            if let modified, modified < cutoff {
                try? fileManager.removeItem(at: callDirectory)
            }
        }
    }
}
