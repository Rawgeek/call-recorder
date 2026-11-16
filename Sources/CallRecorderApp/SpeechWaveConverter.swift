import CallRecorderCore
import Foundation

/// Converts one recorded track into the wave every reader takes.
///
/// Both readers take the same file: 16 kHz, mono, 16-bit PCM. Keeping the conversion here means
/// the local model and the remote endpoint are handed identical audio, so a difference between
/// their answers is a difference between the readers and not between two conversions.
enum SpeechWaveConverter {
    static func convert(
        audio: URL,
        ffmpeg: URL,
        cancellation: ProcessCancellation?
    ) throws -> (work: URL, wave: URL) {
        let work = FileManager.default.temporaryDirectory
            .appending(path: "speech-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        do {
            let wave = work.appending(path: "audio.wav")
            _ = try ProcessRunner.runChecked(
                executable: ffmpeg,
                arguments: [
                    "-v", "error", "-y", "-i", audio.path,
                    "-vn", "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", wave.path,
                ],
                cancellation: cancellation
            )
            return (work, wave)
        } catch {
            try? FileManager.default.removeItem(at: work)
            throw error
        }
    }
}
