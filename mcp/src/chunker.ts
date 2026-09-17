import { createHash } from "node:crypto"
import type { CallId, TranscriptChunk, TranscriptSegment } from "./contracts.ts"

type ChunkPiece = {
  readonly startMs: number
  readonly endMs: number
  readonly text: string
}

const fillerPattern =
  /\[(?:music|silence|applause|laughter|inaudible|noise|phone\.ringing|typing|background|door|cough|sigh|clears\.throat)\]\s*/giu

const cleanText = (text: string): string =>
  text.replaceAll(fillerPattern, "").replaceAll("[BLANK_AUDIO]", "").trim().replaceAll(/\s+/gu, " ")

const contentHash = (text: string): string => createHash("sha256").update(text).digest("hex")

const splitPoint = (characters: readonly string[], maximumCharacters: number): number => {
  for (let index = maximumCharacters; index > Math.floor(maximumCharacters / 2); index -= 1) {
    if (/\s/u.test(characters[index - 1] ?? "")) return index
  }
  return maximumCharacters
}

const splitSegment = (
  segment: TranscriptSegment,
  maximumCharacters: number,
): readonly ChunkPiece[] => {
  const body = cleanText(segment.text)
  const speaker =
    segment.speakerName ??
    (segment.speakerIndex === undefined
      ? segment.source === "system"
        ? "Speaker 1"
        : undefined
      : `Speaker ${segment.speakerIndex + 1}`)
  const text = speaker === undefined ? body : `${speaker}: ${body}`
  const characters = [...text]
  if (characters.length <= maximumCharacters) {
    return [{ startMs: segment.startMs, endMs: segment.endMs, text }]
  }

  const pieces: ChunkPiece[] = []
  const duration = segment.endMs - segment.startMs
  let consumed = 0
  while (consumed < characters.length) {
    const remaining = characters.slice(consumed)
    const length =
      remaining.length <= maximumCharacters
        ? remaining.length
        : splitPoint(remaining, maximumCharacters)
    const pieceText = remaining.slice(0, length).join("").trim()
    const startMs = segment.startMs + Math.round((duration * consumed) / characters.length)
    const nextConsumed = consumed + length
    const endMs = segment.startMs + Math.round((duration * nextConsumed) / characters.length)
    if (pieceText.length > 0) pieces.push({ startMs, endMs, text: pieceText })
    consumed = nextConsumed
  }
  return pieces
}

const makeChunk = (callId: CallId, pieces: readonly ChunkPiece[]): TranscriptChunk => {
  const first = pieces[0]
  const last = pieces.at(-1)
  if (first === undefined || last === undefined) {
    throw new RangeError("cannot create a transcript chunk without content")
  }
  const text = pieces.map((piece) => piece.text).join(" ")
  const hash = contentHash(text)
  return {
    id: `${callId}:${first.startMs}:${last.endMs}:${hash}`,
    callId,
    startMs: first.startMs,
    endMs: last.endMs,
    text,
    contentHash: hash,
  }
}

export const chunkTranscript = (
  callId: CallId,
  segments: readonly TranscriptSegment[],
  maximumCharacters = 1_200,
): readonly TranscriptChunk[] => {
  if (!Number.isInteger(maximumCharacters) || maximumCharacters < 1) {
    throw new RangeError("maximumCharacters must be a positive integer")
  }

  const pieces = segments.flatMap((segment) => splitSegment(segment, maximumCharacters))
  const chunks: TranscriptChunk[] = []
  let window: ChunkPiece[] = []
  for (const piece of pieces) {
    const size = window.reduce((acc, p) => acc + p.text.length, 0) + piece.text.length
    if (size > maximumCharacters && window.length > 0) {
      chunks.push(makeChunk(callId, window))
      window = []
    }
    window.push(piece)
  }
  if (window.length > 0) {
    chunks.push(makeChunk(callId, window))
  }
  return chunks
}
