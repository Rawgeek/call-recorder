import type { Client } from "@libsql/client"
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js"
import { z } from "zod"
import {
  getSpeakerLineRequest,
  queueSpeakerLines,
  SpeakerLineRequestSchema,
} from "./speaker-lines.ts"
import {
  getSpeakerIdentityRequest,
  queueSpeakerIdentity,
  queueSpeakerReopen,
  SpeakerIdentityRequestSchema,
} from "./speaker-requests.ts"
import {
  DiarizationQualitySchema,
  getDiarizationQuality,
  listSpeakerReviews,
  SpeakerReviewSchema,
} from "./speaker-reviews.ts"
import { ReadAnnotations, response, WriteAnnotations } from "./tools.ts"

const LimitSchema = z.int().min(1).max(50).default(20)
// IDs are stored uppercase; normalize case-insensitive tool inputs before database use.
const UuidSchema = z.uuid().transform((value) => value.toUpperCase())

export const registerSpeakerTools = (server: McpServer, database: Client): void => {
  server.registerTool(
    "list_speaker_reviews",
    {
      description:
        "List unresolved local speaker reviews with participant suggestions, three transcript samples, and audio availability.",
      inputSchema: z.object({ limit: LimitSchema }),
      outputSchema: z.object({ reviews: z.array(SpeakerReviewSchema) }),
      annotations: ReadAnnotations,
    },
    async ({ limit }) => response({ reviews: await listSpeakerReviews(database, limit) }),
  )

  server.registerTool(
    "get_diarization_quality",
    {
      description:
        "Measure speaker-label coverage, attribution coverage, unresolved speakers, and per-speaker speech for one local call.",
      inputSchema: z.object({ callId: UuidSchema }),
      outputSchema: z.object({ report: DiarizationQualitySchema }),
      annotations: ReadAnnotations,
    },
    async ({ callId }) => response({ report: await getDiarizationQuality(database, callId) }),
  )

  server.registerTool(
    "get_speaker_identity_request",
    {
      description: "Check whether the signed app applied a queued local speaker identity change.",
      inputSchema: z.object({ requestId: UuidSchema }),
      outputSchema: z.object({ request: SpeakerIdentityRequestSchema }),
      annotations: ReadAnnotations,
    },
    async ({ requestId }) =>
      response({ request: await getSpeakerIdentityRequest(database, requestId) }),
  )

  server.registerTool(
    "set_speaker_identity",
    {
      description:
        "Queue a speaker mapping for the signed app. Set participantId to null to keep the speaker unknown.",
      inputSchema: z.object({
        clusterId: UuidSchema,
        participantId: UuidSchema.nullable(),
      }),
      outputSchema: z.object({ request: SpeakerIdentityRequestSchema }),
      annotations: WriteAnnotations,
    },
    async ({ clusterId, participantId }) =>
      response({ request: await queueSpeakerIdentity(database, clusterId, participantId) }),
  )

  server.registerTool(
    "reopen_speaker_review",
    {
      description:
        "Send a decided local speaker back to review so a wrong name can be corrected. The signed app clears the name the transcript showed.",
      inputSchema: z.object({
        clusterId: UuidSchema,
      }),
      outputSchema: z.object({ request: SpeakerIdentityRequestSchema }),
      annotations: WriteAnnotations,
    },
    async ({ clusterId }) => response({ request: await queueSpeakerReopen(database, clusterId) }),
  )

  server.registerTool(
    "assign_speaker_lines",
    {
      description:
        "Move one run of a call's transcript lines onto a person, whatever voice they were detected as. Writes the range and, with participantId null, releases it back to the voice. The signed app applies it and rewrites the transcript.",
      inputSchema: z.object({
        callId: UuidSchema,
        startMs: z.int().nonnegative().describe("Start of the run, in milliseconds."),
        endMs: z.int().positive().describe("End of the run, in milliseconds."),
        participantId: UuidSchema.nullable().describe(
          "The person the lines belong to, or null to put them back under the voice's own name.",
        ),
      }),
      outputSchema: z.object({ request: SpeakerLineRequestSchema }),
      annotations: WriteAnnotations,
    },
    async ({ callId, startMs, endMs, participantId }) =>
      response({
        request: await queueSpeakerLines(database, callId, startMs, endMs, participantId),
      }),
  )

  server.registerTool(
    "get_speaker_line_request",
    {
      description: "Check whether the signed app applied a queued line assignment.",
      inputSchema: z.object({ requestId: UuidSchema }),
      outputSchema: z.object({ request: SpeakerLineRequestSchema }),
      annotations: ReadAnnotations,
    },
    async ({ requestId }) =>
      response({ request: await getSpeakerLineRequest(database, requestId) }),
  )
}
