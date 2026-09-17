import { randomUUID } from "node:crypto"
import type { Client, Row } from "@libsql/client"
import { z } from "zod"

const RequestActionSchema = z.enum(["confirm", "keepUnknown", "reopen"])
const RequestStatusSchema = z.enum(["pending", "running", "completed", "failed"])
export const SpeakerIdentityRequestSchema = z.object({
  id: z.uuid(),
  clusterId: z.uuid(),
  participantId: z.uuid().nullable(),
  action: RequestActionSchema,
  status: RequestStatusSchema,
  error: z.string().nullable(),
  createdAt: z.iso.datetime(),
  updatedAt: z.iso.datetime(),
})
type SpeakerIdentityRequest = z.infer<typeof SpeakerIdentityRequestSchema>

export class SpeakerReviewUnavailableError extends Error {
  readonly name = "SpeakerReviewUnavailableError"

  constructor(readonly clusterId: string) {
    super(`speaker is unavailable in the local database: ${clusterId}`)
  }
}

export class SpeakerReviewRequestConflictError extends Error {
  readonly name = "SpeakerReviewRequestConflictError"

  constructor(readonly clusterId: string) {
    super(`another speaker mapping is already pending: ${clusterId}`)
  }
}

export class SpeakerIdentityRequestNotFoundError extends Error {
  readonly name = "SpeakerIdentityRequestNotFoundError"

  constructor(readonly requestId: string) {
    super(`speaker identity request not found: ${requestId}`)
  }
}

const request = (row: Row): SpeakerIdentityRequest =>
  SpeakerIdentityRequestSchema.parse({
    id: row[0],
    clusterId: row[1],
    participantId: row[2],
    action: row[3],
    status: row[4],
    error: row[5],
    createdAt: new Date(Number(row[6]) * 1_000).toISOString(),
    updatedAt: new Date(Number(row[7]) * 1_000).toISOString(),
  })

const RequestColumns =
  "id, cluster_id, participant_id, action, status, error, created_at, updated_at"

export const getSpeakerIdentityRequest = async (
  database: Client,
  requestId: string,
): Promise<SpeakerIdentityRequest> => {
  const row = (
    await database.execute({
      sql: `SELECT ${RequestColumns} FROM speaker_review_requests WHERE id = ?`,
      args: [requestId],
    })
  ).rows[0]
  if (row === undefined) throw new SpeakerIdentityRequestNotFoundError(requestId)
  return request(row)
}

const queueRequest = async (
  database: Client,
  clusterId: string,
  action: "confirm" | "keepUnknown" | "reopen",
  participantId: string | null,
): Promise<SpeakerIdentityRequest> => {
  const priorRow = (
    await database.execute({
      sql: `SELECT ${RequestColumns} FROM speaker_review_requests
        WHERE cluster_id = ? AND action = ? AND participant_id IS ?
        ORDER BY created_at DESC LIMIT 1`,
      args: [clusterId, action, participantId],
    })
  ).rows[0]
  if (priorRow !== undefined) {
    const prior = request(priorRow)
    if (prior.status === "pending" || prior.status === "running") return prior
  }

  const review = (
    await database.execute({
      sql: `SELECT 1 FROM speaker_assignments assignments
        JOIN pending_speaker_clusters clusters ON clusters.id = assignments.cluster_id
        WHERE assignments.cluster_id = ?`,
      args: [clusterId],
    })
  ).rows[0]
  if (review === undefined) throw new SpeakerReviewUnavailableError(clusterId)
  let storedParticipantId = participantId
  if (participantId !== null) {
    const participant = await database.execute({
      sql: "SELECT id FROM participants WHERE id = ? COLLATE NOCASE",
      args: [participantId],
    })
    const stored = participant.rows[0]
    if (stored === undefined) throw new SpeakerReviewUnavailableError(clusterId)
    storedParticipantId = z.string().parse(stored[0])
  }

  const now = Date.now() / 1_000
  const transaction = await database.transaction("write")
  try {
    const activeRow = (
      await transaction.execute({
        sql: `SELECT ${RequestColumns} FROM speaker_review_requests
          WHERE cluster_id = ? AND status IN ('pending','running') LIMIT 1`,
        args: [clusterId],
      })
    ).rows[0]
    if (activeRow !== undefined) {
      const active = request(activeRow)
      const sameParticipant =
        (active.participantId ?? "").toLowerCase() === (participantId ?? "").toLowerCase()
      if (active.action !== action || !sameParticipant) {
        throw new SpeakerReviewRequestConflictError(clusterId)
      }
      await transaction.commit()
      return active
    }

    if (priorRow !== undefined) {
      const prior = request(priorRow)
      await transaction.execute({
        sql: `UPDATE speaker_review_requests
          SET status = 'pending', error = NULL, updated_at = ? WHERE id = ?`,
        args: [now, prior.id],
      })
      await transaction.commit()
      return {
        ...prior,
        status: "pending",
        error: null,
        updatedAt: new Date(now * 1_000).toISOString(),
      }
    }

    const id = randomUUID().toUpperCase()
    await transaction.execute({
      sql: `INSERT INTO speaker_review_requests
        (id, cluster_id, participant_id, action, status, created_at, updated_at)
        VALUES (?, ?, ?, ?, 'pending', ?, ?)`,
      args: [id, clusterId, storedParticipantId, action, now, now],
    })
    await transaction.commit()
    return SpeakerIdentityRequestSchema.parse({
      id,
      clusterId,
      participantId: storedParticipantId,
      action,
      status: "pending",
      error: null,
      createdAt: new Date(now * 1_000).toISOString(),
      updatedAt: new Date(now * 1_000).toISOString(),
    })
  } catch (error: unknown) {
    await transaction.rollback()
    throw error
  }
}

/// Queues a mapping for the signed app: a person, or keep the speaker anonymous.
export const queueSpeakerIdentity = (
  database: Client,
  clusterId: string,
  participantId: string | null,
): Promise<SpeakerIdentityRequest> =>
  queueRequest(
    database,
    clusterId,
    participantId === null ? "keepUnknown" : "confirm",
    participantId,
  )

/// Sends a decided speaker back to review and clears the name the transcript showed.
export const queueSpeakerReopen = (
  database: Client,
  clusterId: string,
): Promise<SpeakerIdentityRequest> => queueRequest(database, clusterId, "reopen", null)
