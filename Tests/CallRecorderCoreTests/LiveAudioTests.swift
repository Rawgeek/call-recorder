import Foundation
import Testing
@testable import CallRecorderCore

/// Cutting a call into pieces a model can read: where the cuts land, what is worth sending, and what
/// a WAV file says about itself.
@Suite("Live audio chunks")
struct LiveAudioTests {
    private let rate: Double = 16_000

    private func speech(_ seconds: Double, amplitude: Float = 0.4) -> [Float] {
        Array(repeating: amplitude, count: Int(seconds * rate))
    }

    private func silence(_ seconds: Double) -> [Float] {
        Array(repeating: 0, count: Int(seconds * rate))
    }

    @Test("a chunk is cut by samples, not by a clock")
    func cutsBySamples() {
        var accumulator = LiveAudioAccumulator(sampleRate: rate, chunkSeconds: 15)
        #expect(accumulator.append(speech(10)).isEmpty)
        let chunks = accumulator.append(speech(6))
        #expect(chunks.count == 1)
        #expect(chunks.first?.durationSeconds == 15)
        #expect(chunks.first?.startSeconds == 0)
    }

    @Test("a later chunk knows where it belongs in the stream")
    func placesLaterChunks() {
        var accumulator = LiveAudioAccumulator(sampleRate: rate, chunkSeconds: 15)
        #expect(accumulator.append(speech(15)).count == 1)
        let second = accumulator.append(speech(15))
        #expect(second.first?.startSeconds == 15)
        #expect(second.first?.index == 1)
    }

    @Test("the tail of a recording is worth sending when it holds a sentence")
    func keepsTheTail() {
        var accumulator = LiveAudioAccumulator(
            sampleRate: rate,
            chunkSeconds: 15,
            minimumTailSeconds: 2
        )
        _ = accumulator.append(speech(17))
        let tail = accumulator.finish()
        #expect(tail?.startSeconds == 15)
        #expect(tail?.durationSeconds == 2)
        // The place a tail sits is measured from the audio already sent, not from its own number:
        // counting chunks would have placed it at fifteen seconds into the call.
        #expect(accumulator.totalSeconds == 17)
    }

    @Test("a click at the end of a recording is not a chunk")
    func dropsATinyTail() {
        var accumulator = LiveAudioAccumulator(
            sampleRate: rate,
            chunkSeconds: 15,
            minimumTailSeconds: 2
        )
        _ = accumulator.append(speech(16))
        #expect(accumulator.finish() == nil)
    }

    @Test("silence is not worth sending to a model")
    func seesSilence() {
        var accumulator = LiveAudioAccumulator(sampleRate: rate, chunkSeconds: 1)
        let quiet = accumulator.append(silence(1))
        #expect(quiet.count == 1)
        #expect(quiet.first?.holdsSpeech == false)
        // A quiet room's own noise: 0.002 of full scale is -54 dBFS, under the -50 the app counts
        // as speech, while 0.02 is -34 and is somebody talking softly.
        let roomTone = accumulator.append(speech(1, amplitude: 0.002))
        #expect(roomTone.first?.holdsSpeech == false)
        let spoken = accumulator.append(speech(1, amplitude: 0.02))
        #expect(spoken.first?.holdsSpeech == true)
        let loud = accumulator.append(speech(1, amplitude: 0.5))
        #expect(loud.first?.holdsSpeech == true)
    }

    @Test("a chunk written to disk is a WAV file whisper can read")
    func writesAWav() throws {
        let samples: [Float] = [0, 0.5, -0.5, 1] + Array(repeating: 0, count: 1_596)
        let chunk = LiveAudioChunk(
            index: 0,
            startSeconds: 0,
            samples: samples,
            sampleRate: rate
        )
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "live-audio-" + UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "microphone-0000.wav")
        try LiveAudioChunkWriter.write(chunk, to: url)

        let data = try Data(contentsOf: url)
        #expect(data.count == 44 + samples.count * 2)
        #expect(String(decoding: data[0..<4], as: UTF8.self) == "RIFF")
        #expect(String(decoding: data[8..<12], as: UTF8.self) == "WAVE")
        #expect(String(decoding: data[12..<16], as: UTF8.self) == "fmt ")
        #expect(readUInt16(data, at: 20) == 1)
        #expect(readUInt16(data, at: 22) == 1)
        #expect(readUInt32(data, at: 24) == 16_000)
        #expect(readUInt16(data, at: 34) == 16)
        #expect(String(decoding: data[36..<40], as: UTF8.self) == "data")
        #expect(readUInt32(data, at: 40) == UInt32(samples.count * 2))
        // The samples survive the trip within one step of the quietest bit a signed 16-bit sample
        // has, which is the whole point of writing them at that width.
        #expect(abs(Int(readInt16(data, at: 44 + 2)) - Int((0.5 * 32_767).rounded())) <= 1)
        #expect(abs(Int(readInt16(data, at: 44 + 4)) - Int((-0.5 * 32_767).rounded())) <= 1)
    }

    @Test("a sample beyond full scale is clamped rather than wrapped")
    func clamps() {
        let data = LiveAudioChunkWriter.wavData(samples: [1.8, -1.8], sampleRate: rate)
        #expect(readInt16(data, at: 44) == 32_767)
        #expect(readInt16(data, at: 46) == -32_767)
    }

    private func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private func readInt16(_ data: Data, at offset: Int) -> Int16 {
        Int16(bitPattern: readUInt16(data, at: offset))
    }

    private func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24)
    }
}
