import Foundation

/// A piece of one side's audio, ready to be transcribed.
public struct LiveAudioChunk: Equatable, Sendable {
    /// Which chunk of its own side this is. Chunks are numbered, not timed, so a name survives the
    /// file being written to a different folder.
    public let index: Int
    /// Where the chunk starts, in seconds from the start of this side's stream.
    public let startSeconds: Double
    public let samples: [Float]
    public let sampleRate: Double

    public var durationSeconds: Double { Double(samples.count) / sampleRate }
    public var endSeconds: Double { startSeconds + durationSeconds }

    /// Whether anything in this chunk is loud enough to be speech.
    ///
    /// A call has long stretches of room tone, and sending those to a model costs the same as
    /// sending speech while returning text that nobody said. Whisper in particular answers silence
    /// with whole sentences it has learned to expect.
    public var holdsSpeech: Bool {
        var peak: Float = 0
        for sample in samples where abs(sample) > peak {
            peak = abs(sample)
        }
        return AudioLevels.isSpeech(peak: peak)
    }
}

/// Cuts one side's converted audio into the chunks a transcriber reads.
///
/// The cut is made by counting samples and never by reading a clock. A clock says how long the
/// machine has been working, and a model that is still loading, a call that has just started, and a
/// machine under load all make those two numbers different. A chunk boundary is a place in the
/// audio, so only the audio can say where it is.
public struct LiveAudioAccumulator: Sendable {
    public let sampleRate: Double
    public let chunkSeconds: Double
    /// The least audio worth sending on its own, used for the tail a recording leaves behind.
    ///
    /// A pause usually lands mid-chunk, and the words in that tail are the ones somebody said just
    /// before the pause. A tail shorter than this is a click rather than a sentence.
    public let minimumTailSeconds: Double

    private var samples: [Float] = []
    /// How many samples have left this accumulator inside a chunk. A chunk's place in the stream
    /// is measured from here rather than from its number, because the last chunk of a recording is
    /// shorter than the ones before it and a count of chunks would place it late.
    private var emittedSamples = 0
    private var nextIndex = 0

    public init(
        sampleRate: Double = 16_000,
        chunkSeconds: Double = 15,
        minimumTailSeconds: Double = 2
    ) {
        self.sampleRate = sampleRate
        self.chunkSeconds = chunkSeconds
        self.minimumTailSeconds = minimumTailSeconds
    }

    /// How much audio has gone in, in seconds. This is the number a caller offsets by.
    public var totalSeconds: Double { Double(emittedSamples + samples.count) / sampleRate }

    /// Adds audio and returns every chunk that is now complete.
    public mutating func append(_ newSamples: [Float]) -> [LiveAudioChunk] {
        guard !newSamples.isEmpty else { return [] }
        samples.append(contentsOf: newSamples)
        let size = max(1, Int((chunkSeconds * sampleRate).rounded()))
        var finished: [LiveAudioChunk] = []
        while samples.count >= size {
            let head = Array(samples[0..<size])
            samples.removeFirst(size)
            finished.append(take(head))
        }
        return finished
    }

    /// The audio left over when a recording stops or pauses, when there is enough of it to read.
    public mutating func finish() -> LiveAudioChunk? {
        let least = Int((minimumTailSeconds * sampleRate).rounded())
        guard samples.count >= least else {
            samples.removeAll(keepingCapacity: false)
            return nil
        }
        let tail = samples
        samples.removeAll(keepingCapacity: false)
        return take(tail)
    }

    /// Wraps one body of samples as the next chunk of the stream.
    private mutating func take(_ body: [Float]) -> LiveAudioChunk {
        let chunk = LiveAudioChunk(
            index: nextIndex,
            startSeconds: Double(emittedSamples) / sampleRate,
            samples: body,
            sampleRate: sampleRate
        )
        emittedSamples += body.count
        nextIndex += 1
        return chunk
    }
}

public enum LiveAudioChunkWriterError: LocalizedError {
    case unwritable(URL)

    public var errorDescription: String? {
        switch self {
        case let .unwritable(url):
            "The live audio chunk could not be written: " + url.lastPathComponent
        }
    }
}

/// Writes a chunk as the 16-bit mono WAV file whisper.cpp reads.
///
/// A file is what the transcriber is given rather than a buffer in memory, because the transcriber
/// is a separate process that reads a path. WAV is the one format that needs no encoder and that
/// whisper.cpp reads without help from ffmpeg, which matters for a chunk written fifteen seconds
/// after the call started.
public enum LiveAudioChunkWriter {
    /// The bytes of one chunk: a RIFF header, then the samples as little-endian 16-bit PCM.
    public static func wavData(samples: [Float], sampleRate: Double) -> Data {
        let bitsPerSample = 16
        let channels = 1
        let byteCount = samples.count * MemoryLayout<Int16>.size
        let byteRate = Int(sampleRate) * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8

        var data = Data(capacity: 44 + byteCount)
        func append(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
        func append(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }

        append("RIFF")
        append(UInt32(36 + byteCount))
        append("WAVE")
        append("fmt ")
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(channels))
        append(UInt32(sampleRate))
        append(UInt32(byteRate))
        append(UInt16(blockAlign))
        append(UInt16(bitsPerSample))
        append("data")
        append(UInt32(byteCount))
        for sample in samples {
            let clamped = max(-1, min(1, sample))
            let value = Int16((clamped * 32_767).rounded())
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    public static func write(_ chunk: LiveAudioChunk, to url: URL) throws {
        let data = wavData(samples: chunk.samples, sampleRate: chunk.sampleRate)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url)
        } catch {
            throw LiveAudioChunkWriterError.unwritable(url)
        }
    }
}
