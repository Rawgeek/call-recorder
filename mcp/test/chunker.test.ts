import { describe, expect, test } from "bun:test"
import { chunkTranscript } from "../src/chunker.ts"
import { CallIdSchema, TranscriptSegmentSchema } from "../src/contracts.ts"

const callId = CallIdSchema.parse("3eab7aee-1f8a-48b9-94ca-d720858c8ed0")

describe("chunkTranscript", () => {
  test("preserves timestamped text when short segments fit one chunk", () => {
    // Given
    const segments = [
      TranscriptSegmentSchema.parse({ startMs: 0, endMs: 1_000, text: "Hello." }),
      TranscriptSegmentSchema.parse({ startMs: 1_100, endMs: 2_000, text: "Привет." }),
    ]

    // When
    const chunks = chunkTranscript(callId, segments)

    // Then
    expect(chunks).toHaveLength(1)
    expect(chunks[0]).toMatchObject({
      callId,
      startMs: 0,
      endMs: 2_000,
      text: "Hello. Привет.",
    })
  })

  test("keeps confirmed and anonymous speaker labels in Codex context", () => {
    const segments = [
      TranscriptSegmentSchema.parse({
        startMs: 0,
        endMs: 1_000,
        text: "Hello.",
        speakerIndex: 0,
        source: "system",
        speakerName: "Dana",
      }),
      TranscriptSegmentSchema.parse({
        startMs: 1_000,
        endMs: 2_000,
        text: "Unknown reply.",
        speakerIndex: 1,
        source: "system",
      }),
    ]

    const chunks = chunkTranscript(callId, segments)

    expect(chunks[0]?.text).toBe("Dana: Hello. Speaker 2: Unknown reply.")
  })

  test("splits long text without exceeding the Unicode-scalar limit", () => {
    // Given
    const longText = `${"ภาษาไทย ".repeat(180)}จบ`
    const segment = TranscriptSegmentSchema.parse({ startMs: 0, endMs: 9_000, text: longText })

    // When
    const chunks = chunkTranscript(callId, [segment], 240)

    // Then
    expect(chunks.length).toBeGreaterThan(1)
    expect(chunks.every(({ text }) => [...text].length <= 240)).toBe(true)
    expect(
      chunks
        .map(({ text }) => text)
        .join(" ")
        .replaceAll(/\s+/g, " ")
        .trim(),
    ).toBe(longText.replaceAll(/\s+/g, " ").trim())
  })

  test("produces stable hashes and IDs for unchanged input", () => {
    // Given
    const segment = TranscriptSegmentSchema.parse({
      startMs: 10,
      endMs: 20,
      text: "同じ内容です。",
    })

    // When
    const first = chunkTranscript(callId, [segment])
    const second = chunkTranscript(callId, [segment])

    // Then
    expect(second).toEqual(first)
    expect(first[0]?.contentHash).toMatch(/^[a-f0-9]{64}$/)
  })

  test("returns no chunks for no transcript segments", () => {
    // Given / When
    const chunks = chunkTranscript(callId, [])

    // Then
    expect(chunks).toEqual([])
  })
})
