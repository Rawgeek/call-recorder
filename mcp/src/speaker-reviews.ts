import { readFile } from "node:fs/promises"
import type { Client, Row } from "@libsql/client"
import { z } from "zod"
import { audioAvailable } from "./audio-location.ts"
import { CallIdSchema } from "./contracts.ts"
import { ParticipantSchema, RecordNotFoundError } from "./repositories.ts"

const DatabaseIntegerSchema = z
  .union([z.number().int(), z.bigint()])
  .transform((value) => Number(value))
const AssignmentStateSchema = z.enum(["automatic", "suggested", "unknown", "confirmed"])
const ReviewStateSchema = z.enum(["suggested", "unknown"])
const TranscriptSampleSchema = z.object({
  startMs: z.int().nonnegative(),
  endMs: z.int().nonnegative(),
  text: z.string(),
})

export const SpeakerReviewSchema = z.object({
  clusterId: z.uuid(),
  callId: CallIdSchema,
  speakerIndex: z.int().nonnegative(),
  speakerLabel: z.string(),
  speechDurationMs: z.int().nonnegative(),
  state: ReviewStateSchema,
  suggestedParticipant: ParticipantSchema.nullable(),
  transcriptSamples: z.array(TranscriptSampleSchema).max(3),
  audioAvailable: z.boolean(),
})

const NormalizedSegmentSchema = z.object({
  startMs: z.int().nonnegative(),
  endMs: z.int().nonnegative(),
  text: z.string(),
  speakerIndex: z.int().nonnegative().optional(),
  speakerName: z.string().optional(),
  participantID: z.union([z.uuid(), z.object({ rawValue: z.uuid() })]).optional(),
  source: z.enum(["system", "microphone"]).optional(),
})
const NormalizedTranscriptSchema = z.object({ segments: z.array(NormalizedSegmentSchema) })
type NormalizedSegment = z.infer<typeof NormalizedSegmentSchema>

const readTranscript = async (path: string): Promise<z.infer<typeof NormalizedTranscriptSchema>> =>
  NormalizedTranscriptSchema.parse(JSON.parse(await readFile(path, "utf8")))

const participant = (row: Row, offset: number) =>
  row[offset] === null
    ? null
    : ParticipantSchema.parse({
        id: row[offset],
        name: row[offset + 1],
        role: row[offset + 2],
        company: row[offset + 3],
        email: row[offset + 4],
      })

const samplesFor = (
  segments: readonly NormalizedSegment[],
  speakerIndex: number,
): readonly z.infer<typeof TranscriptSampleSchema>[] => {
  const samples: z.infer<typeof TranscriptSampleSchema>[] = []
  let remainingCharacters = 600
  const candidates = segments
    .filter((segment) => segment.source !== "microphone" && segment.speakerIndex === speakerIndex)
    .toSorted((left, right) => right.text.length - left.text.length)
    .slice(0, 3)
    .toSorted((left, right) => left.startMs - right.startMs)
  for (const segment of candidates) {
    if (segment.speakerIndex !== speakerIndex || samples.length === 3) continue
    const text = segment.text.trim().slice(0, remainingCharacters)
    if (text.length === 0) continue
    samples.push({ startMs: segment.startMs, endMs: segment.endMs, text })
    remainingCharacters -= text.length
    if (remainingCharacters === 0) break
  }
  return samples
}

export const listSpeakerReviews = async (
  database: Client,
  limit: number,
): Promise<readonly z.infer<typeof SpeakerReviewSchema>[]> => {
  const rows = (
    await database.execute({
      sql: `SELECT clusters.id, clusters.call_id, clusters.speaker_index,
          clusters.speaker_label, clusters.speech_ms, assignments.state,
          participants.id, participants.name, participants.role,
          participants.company, participants.email, transcripts.json_path, calls.audio_path
        FROM pending_speaker_clusters clusters
        JOIN speaker_assignments assignments ON assignments.cluster_id = clusters.id
        JOIN calls ON calls.id = clusters.call_id
        JOIN transcripts ON transcripts.call_id = clusters.call_id
        LEFT JOIN participants ON participants.id = assignments.participant_id COLLATE NOCASE
        WHERE assignments.state IN ('suggested','unknown')
          AND assignments.reviewed_at IS NULL
        ORDER BY clusters.created_at DESC, clusters.call_id, clusters.speaker_index LIMIT ?`,
      args: [limit],
    })
  ).rows
  return Promise.all(
    rows.map(async (row) => {
      const transcript = await readTranscript(z.string().parse(row[11]))
      return SpeakerReviewSchema.parse({
        clusterId: row[0],
        callId: row[1],
        speakerIndex: row[2],
        speakerLabel: row[3],
        speechDurationMs: row[4],
        state: row[5],
        suggestedParticipant: participant(row, 6),
        transcriptSamples: samplesFor(transcript.segments, DatabaseIntegerSchema.parse(row[2])),
        audioAvailable: audioAvailable(
          z.string().nullable().parse(row[12]),
          z.string().parse(row[1]),
        ),
      })
    }),
  )
}

const DiarizationWarningSchema = z.enum([
  "no_system_speech",
  "missing_speaker_labels",
  "unresolved_speakers",
  "duplicate_participants",
])
const SpeakerQualitySchema = z.object({
  speakerIndex: z.int().nonnegative(),
  speakerLabel: z.string(),
  segmentCount: z.int().nonnegative(),
  speechMs: z.int().nonnegative(),
  participant: ParticipantSchema.nullable(),
  assignmentState: AssignmentStateSchema.nullable(),
})
export const DiarizationQualitySchema = z.object({
  callId: CallIdSchema,
  status: z.enum(["pass", "review", "unavailable"]),
  systemSegmentCount: z.int().nonnegative(),
  diarizedSystemSegmentCount: z.int().nonnegative(),
  attributedSystemSegmentCount: z.int().nonnegative(),
  systemSpeechMs: z.int().nonnegative(),
  diarizedSystemSpeechMs: z.int().nonnegative(),
  attributedSystemSpeechMs: z.int().nonnegative(),
  diarizationCoverage: z.number().min(0).max(1).nullable(),
  attributionCoverage: z.number().min(0).max(1).nullable(),
  unresolvedSpeakerCount: z.int().nonnegative(),
  speakers: z.array(SpeakerQualitySchema),
  warnings: z.array(DiarizationWarningSchema),
})

type Assignment = {
  readonly label: string
  readonly state: z.infer<typeof AssignmentStateSchema>
  readonly participant: z.infer<typeof ParticipantSchema> | null
  readonly unresolved: boolean
}

const duration = (segment: NormalizedSegment): number => segment.endMs - segment.startMs
const coverage = (covered: number, total: number): number | null =>
  total === 0 ? null : Math.round((covered / total) * 1_000) / 1_000

export const getDiarizationQuality = async (
  database: Client,
  callId: z.infer<typeof CallIdSchema>,
): Promise<z.infer<typeof DiarizationQualitySchema>> => {
  const transcriptRow = (
    await database.execute({
      sql: "SELECT json_path FROM transcripts WHERE call_id = ?",
      args: [callId],
    })
  ).rows[0]
  if (transcriptRow === undefined) throw new RecordNotFoundError("transcript", callId)
  const transcript = await readTranscript(z.string().parse(transcriptRow[0]))
  const assignmentRows = (
    await database.execute({
      sql: `SELECT assignments.speaker_index, clusters.speaker_label, assignments.state,
          assignments.reviewed_at, participants.id, participants.name, participants.role,
          participants.company, participants.email
        FROM speaker_assignments assignments
        JOIN pending_speaker_clusters clusters ON clusters.id = assignments.cluster_id
        LEFT JOIN participants ON participants.id = assignments.participant_id COLLATE NOCASE
        WHERE assignments.call_id = ? ORDER BY assignments.speaker_index`,
      args: [callId],
    })
  ).rows
  const assignments = new Map<number, Assignment>()
  for (const row of assignmentRows) {
    const state = AssignmentStateSchema.parse(row[2])
    assignments.set(DatabaseIntegerSchema.parse(row[0]), {
      label: z.string().parse(row[1]),
      state,
      participant: participant(row, 4),
      unresolved: (state === "suggested" || state === "unknown") && row[3] === null,
    })
  }

  const system = transcript.segments.filter((segment) => segment.source !== "microphone")
  const diarized = system.filter((segment) => segment.speakerIndex !== undefined)
  const attributed = diarized.filter(
    (segment) => segment.speakerName !== undefined || segment.participantID !== undefined,
  )
  const systemSpeechMs = system.reduce((total, segment) => total + duration(segment), 0)
  const diarizedSpeechMs = diarized.reduce((total, segment) => total + duration(segment), 0)
  const attributedSpeechMs = attributed.reduce((total, segment) => total + duration(segment), 0)
  const unresolvedSpeakerCount = [...assignments.values()].filter(
    (assignment) => assignment.unresolved,
  ).length
  const warnings: z.infer<typeof DiarizationWarningSchema>[] = []
  if (systemSpeechMs === 0) warnings.push("no_system_speech")
  if (systemSpeechMs > 0 && diarizedSpeechMs < systemSpeechMs) {
    warnings.push("missing_speaker_labels")
  }
  if (unresolvedSpeakerCount > 0) warnings.push("unresolved_speakers")
  // One real voice can be split across clusters, but two clusters claiming the same person is
  // far more often a wrong enrolment, and it silently mislabels most of the transcript.
  const speakerCounts = new Map<string, number>()
  for (const assignment of assignments.values()) {
    const id = assignment.participant?.id
    if (id === undefined) continue
    speakerCounts.set(id, (speakerCounts.get(id) ?? 0) + 1)
  }
  if ([...speakerCounts.values()].some((count) => count > 1)) {
    warnings.push("duplicate_participants")
  }

  const speakerIndexes = [
    ...new Set(
      diarized.flatMap((segment) =>
        segment.speakerIndex === undefined ? [] : [segment.speakerIndex],
      ),
    ),
  ].sort((left, right) => left - right)
  return DiarizationQualitySchema.parse({
    callId,
    status: systemSpeechMs === 0 ? "unavailable" : warnings.length === 0 ? "pass" : "review",
    systemSegmentCount: system.length,
    diarizedSystemSegmentCount: diarized.length,
    attributedSystemSegmentCount: attributed.length,
    systemSpeechMs,
    diarizedSystemSpeechMs: diarizedSpeechMs,
    attributedSystemSpeechMs: attributedSpeechMs,
    diarizationCoverage: coverage(diarizedSpeechMs, systemSpeechMs),
    attributionCoverage: coverage(attributedSpeechMs, systemSpeechMs),
    unresolvedSpeakerCount,
    speakers: speakerIndexes.map((speakerIndex) => {
      const segments = diarized.filter((segment) => segment.speakerIndex === speakerIndex)
      const assignment = assignments.get(speakerIndex)
      return {
        speakerIndex,
        speakerLabel: assignment?.label ?? `Speaker ${speakerIndex + 1}`,
        segmentCount: segments.length,
        speechMs: segments.reduce((total, segment) => total + duration(segment), 0),
        participant: assignment?.participant ?? null,
        assignmentState: assignment?.state ?? null,
      }
    }),
    warnings,
  })
}
