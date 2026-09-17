import { randomUUID } from "node:crypto"
import type { Client, Row } from "@libsql/client"
import { z } from "zod"
import { audioAvailable } from "./audio-location.ts"
import { type CallId, CallIdSchema } from "./contracts.ts"

/// A page of a listing, with the total so a partial result is never mistaken for the whole set.
///
/// These tools used to return a bare array with a hard cap and no count. An agent asking for
/// every glossary term received the first 20 in alphabetical order and no signal that 115 more
/// existed, so a wrong "we have no term for that" was indistinguishable from a right one.
export interface Listing<T> {
  readonly items: readonly T[]
  readonly total: number
  readonly offset: number
  readonly hasMore: boolean
}

const page = <T>(items: readonly T[], total: number, offset: number): Listing<T> => ({
  items,
  total,
  offset,
  hasMore: offset + items.length < total,
})

export const ParticipantSchema = z.object({
  id: z.uuid(),
  name: z.string(),
  role: z.string().nullable(),
  company: z.string().nullable(),
  email: z.string().nullable(),
})
export type Participant = z.infer<typeof ParticipantSchema>
export type ParticipantInput = {
  readonly id?: string
  readonly name: string
  readonly role?: string | null | undefined
  readonly company?: string | null | undefined
  readonly email?: string | null | undefined
}

export const GlossaryTermSchema = z.object({
  id: z.uuid(),
  preferred: z.string(),
  aliases: z.array(z.string()),
})
export type GlossaryTerm = z.infer<typeof GlossaryTermSchema>

export const CallStatusSchema = z.enum([
  "recording",
  "metadata",
  "transcribing",
  "indexing",
  "ready",
  "failed",
])

export type CallSummary = {
  readonly id: CallId
  readonly startedAt: string
  readonly endedAt: string | null
  readonly status: z.infer<typeof CallStatusSchema>
  readonly participants: readonly Participant[]
}

type MutableCallSummary = Omit<CallSummary, "participants"> & { participants: Participant[] }

export type CallDetail = CallSummary & {
  readonly audioPath: string | null
  /// Whether the audio can still be read from disk.
  ///
  /// The stored path stays even after the app removes the working folder it names, because the row
  /// is the record of where the audio was written. A caller that read the path alone believed the
  /// audio was there and went looking for a folder that no longer existed. The answer is a separate
  /// field so the stored path can stay honest and the question can still be answered.
  readonly audioAvailable: boolean
  readonly transcript: {
    readonly language: string
    readonly model: string
    readonly markdownPath: string
    readonly jsonPath: string
    /// Whether the transcript holds speech.
    ///
    /// A recording with no speech produces a transcript with a language, a model, and empty text.
    /// Without this field that row reads exactly like a transcript whose text was lost, so an agent
    /// asking what was said on the call receives an empty answer and no reason for it.
    readonly hasSpeech: boolean
  } | null
}

export type TranscriptPage = {
  readonly callId: CallId
  readonly language: string
  readonly model: string
  readonly segments: readonly {
    readonly id: string
    readonly startMs: number
    readonly endMs: number
    readonly text: string
  }[]
  readonly nextCursor: string | null
}

export class RecordNotFoundError extends Error {
  readonly name = "RecordNotFoundError"

  constructor(kind: string, id: string) {
    super(`${kind} not found: ${id}`)
  }
}

export class InvalidCursorError extends Error {
  readonly name = "InvalidCursorError"

  constructor(cursor: string) {
    super(`invalid transcript cursor: ${cursor}`)
  }
}

const DatabaseIntegerSchema = z
  .union([z.number().int(), z.bigint()])
  .transform((value) => Number(value))
const DatabaseNumberSchema = z.union([z.number(), z.bigint()]).transform((value) => Number(value))
const AliasesSchema = z.array(z.string())

const isoDate = (value: unknown): string =>
  new Date(DatabaseNumberSchema.parse(value) * 1_000).toISOString()

const participantsForCall = async (database: Client, callId: CallId): Promise<Participant[]> =>
  (
    await database.execute({
      sql: `SELECT participants.id, participants.name, participants.role,
          participants.company, participants.email FROM participants
        JOIN call_participants ON call_participants.participant_id = participants.id COLLATE NOCASE
        WHERE call_participants.call_id = ? ORDER BY participants.normalized_name`,
      args: [callId],
    })
  ).rows.map(participant)

export const listCalls = async (
  database: Client,
  limit: number,
  offset = 0,
): Promise<Listing<CallSummary>> => {
  const rows = (
    await database.execute({
      sql: `WITH selected AS (
          SELECT id, started_at, ended_at, status, COUNT(*) OVER () AS total FROM calls
          ORDER BY started_at DESC, id LIMIT ? OFFSET ?
        )
        SELECT selected.total, selected.id, selected.started_at, selected.ended_at,
          selected.status, participants.id, participants.name, participants.role,
          participants.company, participants.email
        FROM selected
        LEFT JOIN call_participants ON call_participants.call_id = selected.id
        LEFT JOIN participants ON participants.id = call_participants.participant_id COLLATE NOCASE
        ORDER BY selected.started_at DESC, selected.id, participants.normalized_name`,
      args: [limit, offset],
    })
  ).rows
  const calls = new Map<CallId, MutableCallSummary>()
  let total = 0
  for (const row of rows) {
    total = Number(row[0])
    const id = CallIdSchema.parse(row[1])
    let call = calls.get(id)
    if (call === undefined) {
      call = {
        id,
        startedAt: isoDate(row[2]),
        endedAt: row[3] === null ? null : isoDate(row[3]),
        status: CallStatusSchema.parse(row[4]),
        participants: [],
      }
      calls.set(id, call)
    }
    if (row[5] !== null) {
      call.participants.push(participant([row[5], row[6], row[7], row[8], row[9]]))
    }
  }
  return page([...calls.values()], total, offset)
}

export const getCall = async (database: Client, callId: CallId): Promise<CallDetail> => {
  const row = (
    await database.execute({
      sql: "SELECT id, started_at, ended_at, status, audio_path FROM calls WHERE id = ?",
      args: [callId],
    })
  ).rows[0]
  if (row === undefined) throw new RecordNotFoundError("call", callId)
  const transcript = (
    await database.execute({
      sql: "SELECT language, model, markdown_path, json_path FROM transcripts WHERE call_id = ?",
      args: [callId],
    })
  ).rows[0]
  const spoken = (
    await database.execute({
      sql: "SELECT length(trim(text)) AS characters FROM transcripts WHERE call_id = ?",
      args: [callId],
    })
  ).rows[0]
  return {
    id: CallIdSchema.parse(row[0]),
    startedAt: isoDate(row[1]),
    endedAt: row[2] === null ? null : isoDate(row[2]),
    status: CallStatusSchema.parse(row[3]),
    audioPath: z.string().nullable().parse(row[4]),
    audioAvailable: audioAvailable(z.string().nullable().parse(row[4]), callId),
    participants: await participantsForCall(database, callId),
    transcript:
      transcript === undefined
        ? null
        : {
            language: z.string().parse(transcript[0]),
            model: z.string().parse(transcript[1]),
            markdownPath: z.string().parse(transcript[2]),
            jsonPath: z.string().parse(transcript[3]),
            hasSpeech: DatabaseIntegerSchema.parse(spoken?.[0] ?? 0) > 0,
          },
  }
}

export const getTranscript = async (
  database: Client,
  callId: CallId,
  cursor: string | undefined,
  maxSegments: number,
): Promise<TranscriptPage> => {
  const transcript = (
    await database.execute({
      sql: "SELECT language, model FROM transcripts WHERE call_id = ?",
      args: [callId],
    })
  ).rows[0]
  if (transcript === undefined) throw new RecordNotFoundError("transcript", callId)

  let cursorTime = -1
  if (cursor !== undefined) {
    const cursorRow = (
      await database.execute({
        sql: "SELECT start_ms FROM transcript_chunks WHERE call_id = ? AND id = ?",
        args: [callId, cursor],
      })
    ).rows[0]
    if (cursorRow === undefined) throw new InvalidCursorError(cursor)
    cursorTime = DatabaseIntegerSchema.parse(cursorRow[0])
  }
  const rows = (
    await database.execute({
      sql: `SELECT id, start_ms, end_ms, text FROM transcript_chunks
        WHERE call_id = ? AND (start_ms > ? OR (start_ms = ? AND id > ?))
        ORDER BY start_ms, id LIMIT ?`,
      args: [callId, cursorTime, cursorTime, cursor ?? "", maxSegments + 1],
    })
  ).rows
  const hasMore = rows.length > maxSegments
  const segments = rows.slice(0, maxSegments).map((row) => ({
    id: z.string().parse(row[0]),
    startMs: DatabaseIntegerSchema.parse(row[1]),
    endMs: DatabaseIntegerSchema.parse(row[2]),
    text: z.string().parse(row[3]),
  }))
  return {
    callId,
    language: z.string().parse(transcript[0]),
    model: z.string().parse(transcript[1]),
    segments,
    nextCursor: hasMore ? (segments.at(-1)?.id ?? null) : null,
  }
}

export const listParticipants = async (
  database: Client,
  limit: number,
  offset = 0,
): Promise<Listing<Participant>> => {
  // COUNT(*) OVER () is evaluated before LIMIT, so one query returns the page and the true
  // total. Without the total a caller cannot tell a short list from a truncated one.
  const rows = (
    await database.execute({
      sql: `SELECT id, name, role, company, email, COUNT(*) OVER () AS total FROM participants
        ORDER BY normalized_name LIMIT ? OFFSET ?`,
      args: [limit, offset],
    })
  ).rows
  const total = rows.length === 0 ? 0 : Number(rows[0]?.[5])
  return page(rows.map(participant), total, offset)
}

const glossaryTerm = (row: Row): GlossaryTerm =>
  GlossaryTermSchema.parse({
    id: row[0],
    preferred: row[1],
    aliases: AliasesSchema.parse(JSON.parse(z.string().parse(row[2]))),
  })

export const listGlossary = async (
  database: Client,
  limit: number,
  offset = 0,
): Promise<Listing<GlossaryTerm>> => {
  const rows = (
    await database.execute({
      sql: `SELECT id, preferred, aliases_json, COUNT(*) OVER () AS total FROM glossary_terms
        ORDER BY normalized_preferred LIMIT ? OFFSET ?`,
      args: [limit, offset],
    })
  ).rows
  const total = rows.length === 0 ? 0 : Number(rows[0]?.[3])
  return page(rows.map(glossaryTerm), total, offset)
}

const clean = (value: string): string => value.trim().split(/\s+/u).join(" ")
const normalized = (value: string): string => value.normalize("NFKC").toLowerCase()
const cleanOptional = (value: string | null | undefined): string | null | undefined =>
  value === undefined ? undefined : value === null ? null : clean(value) || null
const participant = (row: Row | readonly unknown[]): Participant =>
  ParticipantSchema.parse({
    id: row[0],
    name: row[1],
    role: row[2],
    company: row[3],
    email: row[4],
  })

export class ParticipantMergeError extends Error {
  readonly name = "ParticipantMergeError"
}

/// Folds a duplicate profile into the person to keep. Call links, learned voices, and
/// speaker names move across, then the duplicate row is removed.
export const mergeParticipants = async (
  database: Client,
  sourceId: string,
  targetId: string,
): Promise<{
  participant: Participant
  movedCalls: number
  movedVoiceSamples: number
}> => {
  if (sourceId.toUpperCase() === targetId.toUpperCase()) {
    throw new ParticipantMergeError("the duplicate and the kept person are the same profile")
  }
  const rows = (
    await database.execute({
      sql: `SELECT id, name, role, company, email, normalized_name FROM participants
        WHERE id = ? COLLATE NOCASE OR id = ? COLLATE NOCASE`,
      args: [sourceId, targetId],
    })
  ).rows
  const source = rows.find(
    (row) => z.string().parse(row[0]).toUpperCase() === sourceId.toUpperCase(),
  )
  const target = rows.find(
    (row) => z.string().parse(row[0]).toUpperCase() === targetId.toUpperCase(),
  )
  if (source === undefined || target === undefined) {
    throw new ParticipantMergeError("both participants must exist before a merge")
  }
  const sourceKey = z.string().parse(source[0])
  const targetKey = z.string().parse(target[0])
  const optional = ["participant_voice_samples", "speaker_assignments", "voice_sample_recovery"]
  const present = await Promise.all(
    optional.map(async (name) => {
      const found = await database.execute({
        sql: "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
        args: [name],
      })
      return found.rows.length > 0 ? name : undefined
    }),
  )
  const has = new Set(present.filter((name): name is string => name !== undefined))
  const transaction = await database.transaction("write")
  try {
    const inserted = await transaction.execute({
      sql: `INSERT OR IGNORE INTO call_participants (call_id, participant_id)
        SELECT call_id, ? FROM call_participants WHERE participant_id = ?`,
      args: [targetKey, sourceKey],
    })
    await transaction.execute({
      sql: "DELETE FROM call_participants WHERE participant_id = ?",
      args: [sourceKey],
    })
    let movedVoiceSamples = 0
    if (has.has("participant_voice_samples")) {
      const moved = await transaction.execute({
        sql: "UPDATE participant_voice_samples SET participant_id = ? WHERE participant_id = ?",
        args: [targetKey, sourceKey],
      })
      movedVoiceSamples = moved.rowsAffected
    }
    if (has.has("speaker_assignments")) {
      await transaction.execute({
        sql: "UPDATE speaker_assignments SET participant_id = ? WHERE participant_id = ?",
        args: [targetKey, sourceKey],
      })
    }
    if (has.has("voice_sample_recovery")) {
      await transaction.execute({
        sql: "UPDATE voice_sample_recovery SET participant_id = ? WHERE participant_id = ?",
        args: [targetKey, sourceKey],
      })
    }
    await transaction.execute({
      sql: `UPDATE participants SET role = COALESCE(role, ?), company = COALESCE(company, ?),
          email = COALESCE(email, ?) WHERE id = ?`,
      args: [source[2] ?? null, source[3] ?? null, source[4] ?? null, targetKey],
    })
    await transaction.execute({
      sql: "DELETE FROM participants WHERE id = ?",
      args: [sourceKey],
    })
    await transaction.commit()
    const merged = (
      await database.execute({
        sql: "SELECT id, name, role, company, email FROM participants WHERE id = ?",
        args: [targetKey],
      })
    ).rows[0]
    if (merged === undefined) throw new ParticipantMergeError("the kept person disappeared")
    return {
      participant: participant(merged),
      movedCalls: inserted.rowsAffected,
      movedVoiceSamples,
    }
  } catch (error: unknown) {
    await transaction.rollback()
    throw error
  }
}

export const upsertParticipants = async (
  database: Client,
  inputs: readonly ParticipantInput[],
): Promise<readonly Participant[]> => {
  const uniqueInputs = new Map<string, ParticipantInput>()
  for (const input of inputs) {
    const name = clean(input.name)
    const key = normalized(name)
    const existing = uniqueInputs.get(key)
    const cleaned = {
      ...input,
      name,
      role: cleanOptional(input.role),
      company: cleanOptional(input.company),
      email: cleanOptional(input.email),
    }
    uniqueInputs.set(
      key,
      existing === undefined
        ? cleaned
        : {
            ...existing,
            ...(cleaned.id === undefined ? {} : { id: cleaned.id }),
            ...(cleaned.role === undefined ? {} : { role: cleaned.role }),
            ...(cleaned.company === undefined ? {} : { company: cleaned.company }),
            ...(cleaned.email === undefined ? {} : { email: cleaned.email }),
          },
    )
  }
  const unique = [...uniqueInputs.entries()]
  const transaction = await database.transaction("write")
  try {
    for (const [normalizedName, input] of unique) {
      const updateFields = [input.role, input.company, input.email] as const
      if (input.id !== undefined) {
        const updated = await transaction.execute({
          sql: `UPDATE participants SET name = ?, normalized_name = ?,
            role = CASE WHEN ? THEN ? ELSE role END,
            company = CASE WHEN ? THEN ? ELSE company END,
            email = CASE WHEN ? THEN ? ELSE email END WHERE id = ? COLLATE NOCASE`,
          args: [
            input.name,
            normalizedName,
            input.role === undefined ? 0 : 1,
            input.role ?? null,
            input.company === undefined ? 0 : 1,
            input.company ?? null,
            input.email === undefined ? 0 : 1,
            input.email ?? null,
            input.id,
          ],
        })
        if (updated.rowsAffected > 0) continue
      }
      await transaction.execute({
        sql: `INSERT INTO participants
            (id, name, normalized_name, role, company, email) VALUES (?, ?, ?, ?, ?, ?)
          ON CONFLICT(normalized_name) DO UPDATE SET name = excluded.name,
            role = CASE WHEN ? THEN excluded.role ELSE participants.role END,
            company = CASE WHEN ? THEN excluded.company ELSE participants.company END,
            email = CASE WHEN ? THEN excluded.email ELSE participants.email END`,
        args: [
          input.id?.toUpperCase() ?? randomUUID().toUpperCase(),
          input.name,
          normalizedName,
          input.role ?? null,
          input.company ?? null,
          input.email ?? null,
          updateFields[0] === undefined ? 0 : 1,
          updateFields[1] === undefined ? 0 : 1,
          updateFields[2] === undefined ? 0 : 1,
        ],
      })
    }
    await transaction.commit()
  } catch (error: unknown) {
    await transaction.rollback()
    throw error
  }
  const rows = (
    await database.execute({
      sql: `SELECT id, name, role, company, email, normalized_name FROM participants
        WHERE normalized_name IN (${unique.map(() => "?").join(",")})`,
      args: unique.map(([name]) => name),
    })
  ).rows
  const byName = new Map(rows.map((row) => [z.string().parse(row[5]), participant(row)]))
  return unique.flatMap(([name]) => {
    const participant = byName.get(name)
    return participant === undefined ? [] : [participant]
  })
}

export type GlossaryInput = { readonly preferred: string; readonly aliases: readonly string[] }

export const upsertGlossaryTerms = async (
  database: Client,
  terms: readonly GlossaryInput[],
): Promise<readonly GlossaryTerm[]> => {
  const unique = [
    ...new Map(
      terms.map((term) => {
        const preferred = clean(term.preferred)
        const aliases = [
          ...new Map(
            term.aliases.map((alias) => {
              const cleaned = clean(alias)
              return [normalized(cleaned), cleaned] as const
            }),
          ).values(),
        ]
        return [normalized(preferred), { preferred, aliases }] as const
      }),
    ).entries(),
  ]
  await database.batch(
    unique.map(([normalizedPreferred, term]) => ({
      sql: `INSERT INTO glossary_terms
          (id, preferred, normalized_preferred, aliases_json) VALUES (?, ?, ?, ?)
        ON CONFLICT(normalized_preferred) DO UPDATE SET
          preferred = excluded.preferred, aliases_json = excluded.aliases_json`,
      args: [
        randomUUID().toUpperCase(),
        term.preferred,
        normalizedPreferred,
        JSON.stringify(term.aliases),
      ],
    })),
    "write",
  )
  const rows = (
    await database.execute({
      sql: `SELECT id, preferred, aliases_json, normalized_preferred FROM glossary_terms
        WHERE normalized_preferred IN (${unique.map(() => "?").join(",")})`,
      args: unique.map(([name]) => name),
    })
  ).rows
  const byName = new Map(rows.map((row) => [z.string().parse(row[3]), glossaryTerm(row)]))
  return unique.flatMap(([name]) => {
    const term = byName.get(name)
    return term === undefined ? [] : [term]
  })
}

/// What a delete removed, and what it did not find.
///
/// A caller that is cleaning a glossary needs both halves. Silence about a term that was never
/// there is indistinguishable from a delete that failed, and the whole reason to clean a glossary
/// through a tool is to be able to prove what the store holds afterwards.
export type GlossaryDeletion = {
  readonly deleted: readonly string[]
  readonly missing: readonly string[]
}

/// Remove glossary terms by their preferred spelling.
///
/// The Vocabulary pane has always been able to delete a term. The tool surface could add and
/// update but not remove, so a duplicate could be created through the server and never repaired
/// through it: the glossary held both "Priya" and "Priya Singh" as separate preferred terms,
/// each listing the other as an alias, and only the window could resolve that. A merge is the
/// wrong shape here because a term has no dependants to move; a delete is the whole operation.
export const deleteGlossaryTerms = async (
  database: Client,
  preferred: readonly string[],
): Promise<GlossaryDeletion> => {
  const wanted = [
    ...new Map(
      preferred
        .map((value) => clean(value))
        .filter((value) => value.length > 0)
        .map((value) => [normalized(value), value] as const),
    ).entries(),
  ]
  if (wanted.length === 0) return { deleted: [], missing: [] }

  const transaction = await database.transaction("write")
  try {
    const deleted: string[] = []
    const missing: string[] = []
    for (const [key, shown] of wanted) {
      const outcome = await transaction.execute({
        sql: "DELETE FROM glossary_terms WHERE normalized_preferred = ?",
        args: [key],
      })
      if (outcome.rowsAffected > 0) deleted.push(shown)
      else missing.push(shown)
    }
    await transaction.commit()
    return { deleted, missing }
  } catch (error) {
    await transaction.rollback()
    throw error
  }
}
