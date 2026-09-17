import { randomUUID } from "node:crypto"
import type { Client, Row } from "@libsql/client"
import { z } from "zod"
import { CallIdSchema } from "./contracts.ts"

const RequestStatusSchema = z.enum(["pending", "running", "completed", "failed"])
const LineActionSchema = z.enum(["assignLines", "releaseLines"])

export const SpeakerLineRequestSchema = z.object({
  id: z.uuid(),
  callId: CallIdSchema,
  participantId: z.uuid().nullable(),
  startMs: z.int().nonnegative(),
  endMs: z.int().positive(),
  action: LineActionSchema,
  status: RequestStatusSchema,
  error: z.string().nullable(),
  createdAt: z.iso.datetime(),
  updatedAt: z.iso.datetime(),
})
type SpeakerLineRequest = z.infer<typeof SpeakerLineRequestSchema>

export class SpeakerCallUnavailableError extends Error {
  readonly name = "SpeakerCallUnavailableError"

  constructor(readonly callId: string) {
    super(`call is unavailable in the local database: ${callId}`)
  }
}

export class SpeakerParticipantUnavailableError extends Error {
  readonly name = "SpeakerParticipantUnavailableError"

  constructor(readonly participantId: string) {
    super(`participant is unavailable in the local database: ${participantId}`)
  }
}

export class SpeakerLineRangeError extends Error {
  readonly name = "SpeakerLineRangeError"

  constructor(startMs: number, endMs: number) {
    super(`a line range must end after it starts: ${startMs} to ${endMs}`)
  }
}

export class SpeakerLineRequestConflictError extends Error {
  readonly name = "SpeakerLineRequestConflictError"

  constructor(callId: string, startMs: number, endMs: number) {
    super(`another change to these lines is already pending: ${callId} ${startMs}-${endMs}`)
  }
}

const Columns =
  "id, call_id, participant_id, start_ms, end_ms, action, status, error, created_at, updated_at"

const lineRequest = (row: Row): SpeakerLineRequest =>
  SpeakerLineRequestSchema.parse({
    id: row[0],
    callId: row[1],
    participantId: row[2],
    startMs: row[3],
    endMs: row[4],
    action: row[5],
    status: row[6],
    error: row[7],
    createdAt: new Date(Number(row[8]) * 1_000).toISOString(),
    updatedAt: new Date(Number(row[9]) * 1_000).toISOString(),
  })

/// Queues one correction to the lines a detected voice was made of.
///
/// Queued rather than written, like a speaker mapping: the signed app owns the transcript and keeps
/// a revision it can roll back to, so a caller outside it goes through that path. A null
/// participantId puts the lines back under the voice own name, which is how a correction is undone.
export const queueSpeakerLines = async (
  database: Client,
  callId: string,
  startMs: number,
  endMs: number,
  participantId: string | null,
): Promise<SpeakerLineRequest> => {
  if (endMs <= startMs) throw new SpeakerLineRangeError(startMs, endMs)
  const action = participantId === null ? "releaseLines" : "assignLines"
  const call = (await database.execute({ sql: "SELECT 1 FROM calls WHERE id = ?", args: [callId] }))
    .rows[0]
  if (call === undefined) throw new SpeakerCallUnavailableError(callId)

  let storedParticipantId: string | null = null
  if (participantId !== null) {
    const stored = (
      await database.execute({
        sql: "SELECT id FROM participants WHERE id = ? COLLATE NOCASE",
        args: [participantId],
      })
    ).rows[0]
    // A person the roster does not hold is a request the app could only fail on, so it is refused
    // here where the caller can be told which identifier was wrong.
    if (stored === undefined) throw new SpeakerParticipantUnavailableError(participantId)
    storedParticipantId = z.string().parse(stored[0])
  }

  const now = Date.now() / 1_000
  const transaction = await database.transaction("write")
  try {
    const active = (
      await transaction.execute({
        sql:
          `SELECT ${Columns} FROM speaker_review_requests` +
          " WHERE call_id = ? AND start_ms = ? AND end_ms = ?" +
          " AND status IN ('pending','running') LIMIT 1",
        args: [callId, startMs, endMs],
      })
    ).rows[0]
    if (active !== undefined) {
      const queued = lineRequest(active)
      const sameParticipant =
        (queued.participantId ?? "").toLowerCase() === (storedParticipantId ?? "").toLowerCase()
      // The same change asked for twice returns the request already waiting rather than a second
      // row for the same range, which the app would apply one after the other to no effect.
      if (queued.action !== action || !sameParticipant) {
        throw new SpeakerLineRequestConflictError(callId, startMs, endMs)
      }
      await transaction.commit()
      return queued
    }

    const id = randomUUID().toUpperCase()
    await transaction.execute({
      sql:
        "INSERT INTO speaker_review_requests " +
        "(id, call_id, participant_id, start_ms, end_ms, action, status, created_at, updated_at) " +
        "VALUES (?, ?, ?, ?, ?, ?, 'pending', ?, ?)",
      args: [id, callId, storedParticipantId, startMs, endMs, action, now, now],
    })
    await transaction.commit()
    return SpeakerLineRequestSchema.parse({
      id,
      callId,
      participantId: storedParticipantId,
      startMs,
      endMs,
      action,
      status: "pending",
      error: null,
      createdAt: new Date(now * 1_000).toISOString(),
      updatedAt: new Date(now * 1_000).toISOString(),
    })
  } catch (error) {
    await transaction.rollback()
    throw error
  }
}

export const getSpeakerLineRequest = async (
  database: Client,
  requestId: string,
): Promise<SpeakerLineRequest> => {
  const row = (
    await database.execute({
      sql: `SELECT ${Columns} FROM speaker_review_requests WHERE id = ?`,
      args: [requestId],
    })
  ).rows[0]
  if (row === undefined) throw new SpeakerLineRequestNotFoundError(requestId)
  return lineRequest(row)
}

export class SpeakerLineRequestNotFoundError extends Error {
  readonly name = "SpeakerLineRequestNotFoundError"

  constructor(readonly requestId: string) {
    super(`speaker line request not found: ${requestId}`)
  }
}
