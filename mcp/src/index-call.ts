import { isAbsolute } from "node:path"
import { parseArgs } from "node:util"
import type { Client } from "@libsql/client"
import { z } from "zod"
import { chunkTranscript } from "./chunker.ts"
import {
  type CallId,
  CallIdSchema,
  type TranscriptSegment,
  TranscriptSegmentSchema,
} from "./contracts.ts"
import { migrateSearchSchema, openDatabase } from "./database.ts"
import { loadEmbeddingService } from "./embedder.ts"

export interface DocumentEmbedder {
  readonly modelVersion: string
  embedDocuments(documents: readonly string[]): Promise<readonly (readonly number[])[]>
}

const IndexCommandSchema = z.discriminatedUnion("kind", [
  z
    .object({
      kind: z.literal("index"),
      databasePath: z.string().refine(isAbsolute),
      callId: CallIdSchema,
      cacheDirectory: z.string().refine(isAbsolute),
    })
    .readonly(),
  z
    .object({
      kind: z.literal("download-model"),
      cacheDirectory: z.string().refine(isAbsolute),
    })
    .readonly(),
])

export type IndexCommand = z.infer<typeof IndexCommandSchema>

export type IndexCommandResult = IndexCallResult | { readonly kind: "model-ready" }

export type IndexCommandDependencies = {
  readonly openDatabase: (path: string) => Client
  readonly loadEmbeddingService: (
    cacheDirectory: string,
    allowDownload: boolean,
  ) => Promise<DocumentEmbedder>
}

export const parseIndexCommand = (arguments_: readonly string[]): IndexCommand => {
  const parsed = parseArgs({
    args: [...arguments_],
    allowPositionals: true,
    strict: true,
    options: {
      database: { type: "string" },
      "call-id": { type: "string" },
      cache: { type: "string" },
    },
  })
  return IndexCommandSchema.parse({
    kind: parsed.positionals[0],
    databasePath: parsed.values.database,
    callId: parsed.values["call-id"],
    cacheDirectory: parsed.values.cache,
  })
}

export type IndexCallResult =
  | { readonly kind: "indexed"; readonly chunkCount: number }
  | { readonly kind: "skipped"; readonly chunkCount: number }

export class TranscriptNotFoundError extends Error {
  readonly name = "TranscriptNotFoundError"

  constructor(readonly callId: CallId) {
    super(`transcript not found for call ${callId}`)
  }
}

const TranscriptDocumentSchema = z.object({
  callId: CallIdSchema,
  language: z.string().min(1),
  model: z.string().min(1),
  participants: z.array(z.object({ id: z.uuid(), name: z.string().min(1) })),
  glossary: z.array(
    z.object({ id: z.uuid(), preferred: z.string().min(1), aliases: z.array(z.string()) }),
  ),
  segments: z.array(TranscriptSegmentSchema),
})

const EmbeddingSchema = z.array(z.number().finite()).length(256)

const performIndexCall = async (
  database: Client,
  callId: CallId,
  embedder: DocumentEmbedder,
): Promise<IndexCallResult> => {
  await migrateSearchSchema(database)
  const transcriptResult = await database.execute({
    sql: "SELECT text, json_path FROM transcripts WHERE call_id = ?",
    args: [callId],
  })
  const row = transcriptResult.rows[0]
  if (row === undefined) throw new TranscriptNotFoundError(callId)
  const text = z.string().parse(row[0])
  const jsonFile = Bun.file(z.string().parse(row[1]))
  let segments: readonly TranscriptSegment[]
  if (await jsonFile.exists()) {
    const document = TranscriptDocumentSchema.parse(await jsonFile.json())
    if (document.callId !== callId) throw new TranscriptNotFoundError(callId)
    segments = document.segments
  } else {
    // ponytail: synthetic positions keep cleaned transcripts indexable after JSON cleanup;
    // persist segment JSON in the database if timestamp-aware retrieval becomes necessary.
    segments = [{ startMs: 0, endMs: Math.max(1, [...text].length), text }]
  }

  const chunks = chunkTranscript(callId, segments)
  const storedResult = await database.execute({
    sql: "SELECT id, content_hash, embedding_model FROM transcript_chunks WHERE call_id = ?",
    args: [callId],
  })
  const stored = new Map(
    storedResult.rows.map((storedRow) => [
      z.string().parse(storedRow[0]),
      {
        contentHash: z.string().parse(storedRow[1]),
        modelVersion: z.string().nullable().parse(storedRow[2]),
      },
    ]),
  )
  const unchanged =
    stored.size === chunks.length &&
    chunks.every((chunk) => {
      const existing = stored.get(chunk.id)
      return (
        existing?.contentHash === chunk.contentHash &&
        existing.modelVersion === embedder.modelVersion
      )
    })
  if (unchanged) {
    await database.batch([
      { sql: "UPDATE calls SET status = 'ready' WHERE id = ?", args: [callId] },
      {
        sql: "UPDATE index_jobs SET status = 'ready', error = NULL WHERE call_id = ?",
        args: [callId],
      },
    ])
    return { kind: "skipped", chunkCount: chunks.length }
  }
  const embeddings = z
    .array(EmbeddingSchema)
    .length(chunks.length)
    .parse(await embedder.embedDocuments(chunks.map(({ text }) => text)))
  const transaction = await database.transaction("write")
  try {
    await transaction.execute({
      sql: "DELETE FROM transcript_chunks WHERE call_id = ?",
      args: [callId],
    })
    for (const [index, chunk] of chunks.entries()) {
      const embedding = embeddings[index]
      if (embedding === undefined) throw new RangeError("missing chunk embedding")
      await transaction.execute({
        sql: `INSERT INTO transcript_chunks
          (id, call_id, start_ms, end_ms, text, content_hash, embedding, embedding_model)
          VALUES (?, ?, ?, ?, ?, ?, vector32(?), ?)`,
        args: [
          chunk.id,
          chunk.callId,
          chunk.startMs,
          chunk.endMs,
          chunk.text,
          chunk.contentHash,
          JSON.stringify(embedding),
          embedder.modelVersion,
        ],
      })
    }
    await transaction.execute({
      sql: "UPDATE calls SET status = 'ready' WHERE id = ?",
      args: [callId],
    })
    await transaction.execute({
      sql: "UPDATE index_jobs SET status = 'ready', error = NULL WHERE call_id = ?",
      args: [callId],
    })
    await transaction.commit()
  } catch (error) {
    await transaction.rollback()
    throw error
  }
  return { kind: "indexed", chunkCount: chunks.length }
}

export const indexCall = async (
  database: Client,
  callId: CallId,
  embedder: DocumentEmbedder,
): Promise<IndexCallResult> => {
  try {
    return await performIndexCall(database, callId, embedder)
  } catch (error) {
    const message = error instanceof Error ? error.message : "Unknown indexing failure."
    await database.batch([
      { sql: "UPDATE calls SET status = 'failed' WHERE id = ?", args: [callId] },
      {
        sql: "UPDATE index_jobs SET status = 'failed', error = ? WHERE call_id = ?",
        args: [message, callId],
      },
    ])
    throw error
  }
}

const assertNever = (value: never): never => {
  throw new TypeError(`Unsupported index command: ${JSON.stringify(value)}`)
}

const defaultDependencies = {
  openDatabase,
  loadEmbeddingService,
} as const satisfies IndexCommandDependencies

export const runIndexCommand = async (
  command: IndexCommand,
  dependencies: IndexCommandDependencies = defaultDependencies,
): Promise<IndexCommandResult> => {
  switch (command.kind) {
    case "download-model":
      await dependencies.loadEmbeddingService(command.cacheDirectory, true)
      return { kind: "model-ready" }
    case "index": {
      const embedder = await dependencies.loadEmbeddingService(command.cacheDirectory, false)
      const database = dependencies.openDatabase(command.databasePath)
      try {
        return await indexCall(database, command.callId, embedder)
      } finally {
        database.close()
      }
    }
    default:
      return assertNever(command)
  }
}

if (import.meta.main) {
  try {
    const result = await runIndexCommand(parseIndexCommand(Bun.argv.slice(2)))
    process.stdout.write(`${JSON.stringify(result)}\n`)
  } catch (error) {
    // no-excuse-ok: catch — CLI boundary converts every failure to stderr and a nonzero exit.
    const message = error instanceof Error ? error.message : "Unknown indexing failure."
    console.error(message)
    process.exitCode = 1
  }
}
