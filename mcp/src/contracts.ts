import { z } from "zod"

export const CallIdSchema = z.uuid()
export type CallId = z.infer<typeof CallIdSchema>

export const ChunkIdSchema = z.string().min(1)
export type ChunkId = z.infer<typeof ChunkIdSchema>

export const TranscriptSegmentSchema = z
  .object({
    startMs: z.int().nonnegative(),
    endMs: z.int().positive(),
    text: z.string().trim().min(1),
    speakerIndex: z.int().nonnegative().optional(),
    speakerName: z.string().trim().min(1).max(200).optional(),
    source: z.enum(["system", "microphone"]).optional(),
  })
  .refine(({ startMs, endMs }) => endMs >= startMs, {
    error: "endMs must be greater than or equal to startMs",
    path: ["endMs"],
  })

export type TranscriptSegment = z.infer<typeof TranscriptSegmentSchema>

export type TranscriptChunk = {
  readonly id: string
  readonly callId: CallId
  readonly startMs: number
  readonly endMs: number
  readonly text: string
  readonly contentHash: string
}
