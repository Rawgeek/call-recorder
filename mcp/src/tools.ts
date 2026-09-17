import type { Client } from "@libsql/client"
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js"
import type { ToolAnnotations } from "@modelcontextprotocol/sdk/types.js"
import { z } from "zod"
import { CallIdSchema } from "./contracts.ts"
import {
  CallStatusSchema,
  deleteGlossaryTerms,
  type GlossaryDeletion,
  GlossaryTermSchema,
  getCall,
  getTranscript,
  type Listing,
  listCalls,
  listGlossary,
  listParticipants,
  mergeParticipants,
  type ParticipantInput,
  ParticipantSchema,
  upsertGlossaryTerms,
  upsertParticipants,
} from "./repositories.ts"
import { type QueryEmbedder, searchCalls } from "./search.ts"

/// How many rows one call may ask for.
///
/// The cap used to be 50, which was below the size of the real data: the glossary holds 135
/// terms and the call log holds 85 calls, so no single request could ever read the whole set and
/// there was no way to page past it either.
const LimitSchema = z.int().min(1).max(500).default(20)
const OffsetSchema = z.int().min(0).default(0)

/// The pagination fields every listing carries, so a partial answer says so.
const paginationFields = {
  total: z.int().nonnegative(),
  offset: z.int().nonnegative(),
  hasMore: z.boolean(),
  nextOffset: z.int().nonnegative().nullable(),
}

/// Builds the payload for a listing: the page, plus what the page is a page of.
const listingPayload = <K extends string, T>(key: K, listing: Listing<T>) =>
  ({
    [key]: listing.items,
    total: listing.total,
    offset: listing.offset,
    hasMore: listing.hasMore,
    nextOffset: listing.hasMore ? listing.offset + listing.items.length : null,
  }) as Record<K, readonly T[]> & {
    total: number
    offset: number
    hasMore: boolean
    nextOffset: number | null
  }
export const ReadAnnotations: ToolAnnotations = {
  readOnlyHint: true,
  destructiveHint: false,
  idempotentHint: true,
  openWorldHint: false,
}
export const WriteAnnotations: ToolAnnotations = {
  readOnlyHint: false,
  destructiveHint: false,
  idempotentHint: true,
  openWorldHint: false,
}

/// A write that takes something away.
///
/// The distinction is not decoration: a client is told to confirm a destructive call, and a
/// delete that advertised itself as an ordinary write would be the one call an agent could make
/// without anyone noticing that the term is gone.
const DeleteAnnotations: ToolAnnotations = {
  readOnlyHint: false,
  destructiveHint: true,
  idempotentHint: true,
  openWorldHint: false,
}

const CallSummarySchema = z.object({
  id: CallIdSchema,
  startedAt: z.iso.datetime(),
  endedAt: z.iso.datetime().nullable(),
  status: CallStatusSchema,
  participants: z.array(ParticipantSchema),
})
const CallDetailSchema = CallSummarySchema.extend({
  audioPath: z.string().nullable(),
  audioAvailable: z.boolean(),
  transcript: z
    .object({
      language: z.string(),
      model: z.string(),
      markdownPath: z.string(),
      jsonPath: z.string(),
      hasSpeech: z.boolean(),
    })
    .nullable(),
})
const TranscriptPageSchema = z.object({
  callId: CallIdSchema,
  language: z.string(),
  model: z.string(),
  segments: z.array(
    z.object({
      id: z.string(),
      startMs: z.int().nonnegative(),
      endMs: z.int().nonnegative(),
      text: z.string(),
    }),
  ),
  nextCursor: z.string().nullable(),
})
const SearchHitSchema = z.object({
  chunkId: z.string(),
  callId: CallIdSchema,
  startMs: z.int().nonnegative(),
  endMs: z.int().nonnegative(),
  text: z.string(),
})
const ParticipantInputSchema = z.object({
  id: z.uuid().optional(),
  name: z.string().trim().min(1).max(200),
  role: z.string().trim().max(200).nullable().optional(),
  company: z.string().trim().max(200).nullable().optional(),
  email: z.email().max(320).nullable().optional(),
})

export const response = (structuredContent: Record<string, unknown>) => ({
  content: [{ type: "text" as const, text: JSON.stringify(structuredContent) }],
  structuredContent,
})

export const registerTools = (
  server: McpServer,
  database: Client,
  embedder: QueryEmbedder,
): void => {
  server.registerTool(
    "list_calls",
    {
      description:
        "List recent locally recorded calls with participants. Reports the total so a partial page is visible as one.",
      inputSchema: z.object({ limit: LimitSchema, offset: OffsetSchema }),
      outputSchema: z.object({ calls: z.array(CallSummarySchema), ...paginationFields }),
      annotations: ReadAnnotations,
    },
    async ({ limit, offset }) =>
      response(listingPayload("calls", await listCalls(database, limit, offset))),
  )

  server.registerTool(
    "search_calls",
    {
      description: "Search local transcript chunks with BM25, semantic, or hybrid ranking.",
      inputSchema: z.object({
        query: z.string().trim().min(1).max(500),
        mode: z.enum(["hybrid", "lexical", "semantic"]).default("hybrid"),
        limit: LimitSchema,
        participantIds: z.array(z.uuid()).max(20).optional(),
        startedAfter: z.iso.datetime().optional(),
        startedBefore: z.iso.datetime().optional(),
      }),
      outputSchema: z.object({ results: z.array(SearchHitSchema) }),
      annotations: ReadAnnotations,
    },
    async ({ query, mode, limit, participantIds, startedAfter, startedBefore }) =>
      response({
        results: await searchCalls(database, embedder, query, mode, limit, {
          ...(participantIds === undefined ? {} : { participantIds }),
          ...(startedAfter === undefined ? {} : { startedAfter: Date.parse(startedAfter) / 1_000 }),
          ...(startedBefore === undefined
            ? {}
            : { startedBefore: Date.parse(startedBefore) / 1_000 }),
        }),
      }),
  )

  server.registerTool(
    "get_call",
    {
      description: "Get one local call and its participant and transcript metadata.",
      inputSchema: z.object({ callId: CallIdSchema }),
      outputSchema: z.object({ call: CallDetailSchema }),
      annotations: ReadAnnotations,
    },
    async ({ callId }) => response({ call: await getCall(database, callId) }),
  )

  server.registerTool(
    "get_transcript",
    {
      description: "Read a bounded page of timestamped transcript segments.",
      inputSchema: z.object({
        callId: CallIdSchema,
        cursor: z.string().min(1).optional(),
        maxSegments: z.int().min(1).max(100).default(100),
      }),
      outputSchema: z.object({ transcript: TranscriptPageSchema }),
      annotations: ReadAnnotations,
    },
    async ({ callId, cursor, maxSegments }) =>
      response({ transcript: await getTranscript(database, callId, cursor, maxSegments) }),
  )

  server.registerTool(
    "list_participants",
    {
      description:
        "List saved local meeting participants. Reports the total so a partial page is visible as one.",
      inputSchema: z.object({ limit: LimitSchema, offset: OffsetSchema }),
      outputSchema: z.object({ participants: z.array(ParticipantSchema), ...paginationFields }),
      annotations: ReadAnnotations,
    },
    async ({ limit, offset }) =>
      response(listingPayload("participants", await listParticipants(database, limit, offset))),
  )

  server.registerTool(
    "list_glossary",
    {
      description:
        "List saved local transcription glossary terms. Reports the total so a partial page is visible as one.",
      inputSchema: z.object({ limit: LimitSchema, offset: OffsetSchema }),
      outputSchema: z.object({ terms: z.array(GlossaryTermSchema), ...paginationFields }),
      annotations: ReadAnnotations,
    },
    async ({ limit, offset }) =>
      response(listingPayload("terms", await listGlossary(database, limit, offset))),
  )

  server.registerTool(
    "upsert_participants",
    {
      description: "Add or update reusable local participant profiles.",
      inputSchema: z
        .object({
          names: z.array(z.string().trim().min(1).max(200)).max(50).optional(),
          participants: z.array(ParticipantInputSchema).max(50).optional(),
        })
        .refine(
          ({ names, participants }) => (names?.length ?? 0) + (participants?.length ?? 0) > 0,
          {
            error: "provide at least one participant name or profile",
          },
        ),
      outputSchema: z.object({ participants: z.array(ParticipantSchema) }),
      annotations: WriteAnnotations,
    },
    async ({ names, participants }) => {
      const inputs: ParticipantInput[] = [
        ...(names ?? []).map((name) => ({ name })),
        ...(participants ?? []),
      ]
      return response({ participants: await upsertParticipants(database, inputs) })
    },
  )

  server.registerTool(
    "upsert_glossary_terms",
    {
      description: "Add or update local transcription glossary terms and aliases.",
      inputSchema: z.object({
        terms: z
          .array(
            z.object({
              preferred: z.string().trim().min(1).max(200),
              aliases: z.array(z.string().trim().min(1).max(200)).max(20).default([]),
            }),
          )
          .min(1)
          .max(50),
      }),
      outputSchema: z.object({ terms: z.array(GlossaryTermSchema) }),
      annotations: WriteAnnotations,
    },
    async ({ terms }) => response({ terms: await upsertGlossaryTerms(database, terms) }),
  )

  server.registerTool(
    "delete_glossary_terms",
    {
      description:
        "Delete local transcription glossary terms by their preferred spelling. Reports which were removed and which were not found, so a clean-up can be verified afterwards.",
      inputSchema: z.object({
        terms: z.array(z.string().trim().min(1).max(200)).min(1).max(50),
      }),
      outputSchema: z.object({
        deleted: z.array(z.string()),
        missing: z.array(z.string()),
      }),
      annotations: DeleteAnnotations,
    },
    async ({ terms }) => response((await deleteGlossaryTerms(database, terms)) as GlossaryDeletion),
  )

  server.registerTool(
    "merge_participants",
    {
      description:
        "Merge a duplicate local participant into the person you keep, moving call links and learned voices.",
      inputSchema: z.object({
        duplicateId: z.uuid(),
        keepId: z.uuid(),
      }),
      outputSchema: z.object({
        participant: ParticipantSchema,
        movedCalls: z.int().nonnegative(),
        movedVoiceSamples: z.int().nonnegative(),
      }),
      annotations: WriteAnnotations,
    },
    async ({ duplicateId, keepId }) =>
      response(await mergeParticipants(database, duplicateId, keepId)),
  )
}
