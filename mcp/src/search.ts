import type { Client, Row } from "@libsql/client"
import { z } from "zod"
import { type CallId, CallIdSchema, type ChunkId, ChunkIdSchema } from "./contracts.ts"

export type SearchMode = "hybrid" | "lexical" | "semantic"

export type SearchFilters = {
  readonly participantIds?: readonly string[]
  readonly startedAfter?: number
  readonly startedBefore?: number
}

export interface QueryEmbedder {
  /// The model that produced the query vector. Vectors from a different model are not
  /// comparable, so search must only rank chunks the same model embedded.
  readonly modelVersion: string
  embedQuery(query: string): Promise<readonly number[]>
}

export type RankedChunk = {
  readonly id: ChunkId
  readonly score: number
}

export type SearchHit = {
  readonly chunkId: ChunkId
  readonly callId: CallId
  readonly startMs: number
  readonly endMs: number
  readonly text: string
}

export class InvalidEmbeddingError extends Error {
  readonly name = "InvalidEmbeddingError"

  constructor(readonly dimensions: number) {
    super(`expected 256 finite embedding values, received ${dimensions}`)
  }
}

const DatabaseIntegerSchema = z
  .union([z.number().int(), z.bigint()])
  .transform((value) => Number(value))

const lexicalExpression = (query: string): string | undefined => {
  const tokens = query
    .normalize("NFKC")
    .toLowerCase()
    .match(/[\p{L}\p{N}]{2,}/gu)
  return tokens === null ? undefined : [...new Set(tokens)].join(" OR ")
}

const parseChunkIDs = (rows: readonly Row[]): readonly ChunkId[] =>
  rows.map((row) => ChunkIdSchema.parse(row[0]))

const filterSQL = (
  filters: SearchFilters,
): { readonly clause: string; readonly args: readonly (number | string)[] } => {
  const predicates: string[] = []
  const args: (number | string)[] = []
  if (filters.startedAfter !== undefined) {
    predicates.push("filtered_calls.started_at >= ?")
    args.push(filters.startedAfter)
  }
  if (filters.startedBefore !== undefined) {
    predicates.push("filtered_calls.started_at <= ?")
    args.push(filters.startedBefore)
  }
  if (filters.participantIds !== undefined && filters.participantIds.length > 0) {
    const placeholders = filters.participantIds.map(() => "?").join(",")
    predicates.push(
      `EXISTS (SELECT 1 FROM call_participants filtered_participants
        WHERE filtered_participants.call_id = transcript_chunks.call_id
        AND filtered_participants.participant_id COLLATE NOCASE IN (${placeholders}))`,
    )
    args.push(...filters.participantIds)
  }
  return {
    clause: predicates.length === 0 ? "" : ` AND ${predicates.join(" AND ")}`,
    args,
  }
}

export const reciprocalRankFusion = (
  rankings: readonly (readonly ChunkId[])[],
  constant = 60,
): readonly RankedChunk[] => {
  /** Mutable score map: accumulating rank contributions is its sole purpose. */
  const scores = new Map<ChunkId, number>()
  for (const ranking of rankings) {
    ranking.forEach((id, index) => {
      scores.set(id, (scores.get(id) ?? 0) + 1 / (constant + index + 1))
    })
  }
  return [...scores.entries()]
    .map(([id, score]) => ({ id, score }))
    .sort((left, right) => right.score - left.score || left.id.localeCompare(right.id))
}

const lexicalRanking = async (
  database: Client,
  query: string,
  limit: number,
  filters: SearchFilters,
): Promise<readonly ChunkId[]> => {
  const expression = lexicalExpression(query)
  const filter = filterSQL(filters)
  const fts =
    expression === undefined
      ? []
      : parseChunkIDs(
          (
            await database.execute({
              sql:
                "SELECT transcript_chunks_fts.id FROM transcript_chunks_fts " +
                "JOIN transcript_chunks ON transcript_chunks.rowid = transcript_chunks_fts.rowid " +
                "JOIN calls filtered_calls ON filtered_calls.id = transcript_chunks.call_id " +
                `WHERE transcript_chunks_fts MATCH ?${filter.clause} ` +
                "ORDER BY bm25(transcript_chunks_fts) LIMIT ?",
              args: [expression, ...filter.args, limit],
            })
          ).rows,
        )

  const fallback = parseChunkIDs(
    (
      await database.execute({
        sql:
          "SELECT transcript_chunks.id FROM transcript_chunks " +
          "JOIN calls filtered_calls ON filtered_calls.id = transcript_chunks.call_id " +
          `WHERE instr(lower(text), lower(?)) > 0${filter.clause} ` +
          "ORDER BY transcript_chunks.start_ms, transcript_chunks.id LIMIT ?",
        args: [query.trim(), ...filter.args, limit],
      })
    ).rows,
  )
  return [...fts, ...fallback.filter((id) => !fts.includes(id))].slice(0, limit)
}

const semanticRanking = async (
  database: Client,
  embedder: QueryEmbedder,
  query: string,
  limit: number,
  filters: SearchFilters,
): Promise<readonly ChunkId[]> => {
  const embedding = await embedder.embedQuery(query)
  if (embedding.length !== 256 || embedding.some((value) => !Number.isFinite(value))) {
    throw new InvalidEmbeddingError(embedding.length)
  }
  const filter = filterSQL(filters)
  // Only chunks embedded by the model in use are comparable with this query vector. Chunks from
  // a superseded model keep their text and stay reachable through the lexical lanes; ranking
  // them here would return confident nonsense after any model update.
  // ponytail: exact local scan keeps filters correct; benchmark before adding ANN vector_top_k.
  return parseChunkIDs(
    (
      await database.execute({
        sql:
          "SELECT transcript_chunks.id FROM transcript_chunks " +
          "JOIN calls filtered_calls ON filtered_calls.id = transcript_chunks.call_id " +
          `WHERE embedding IS NOT NULL AND embedding_model = ?${filter.clause} ` +
          "ORDER BY vector_distance_cos(transcript_chunks.embedding, vector32(?)), " +
          "transcript_chunks.id LIMIT ?",
        args: [embedder.modelVersion, ...filter.args, JSON.stringify(embedding), limit],
      })
    ).rows,
  )
}

const fetchHits = async (
  database: Client,
  ranking: readonly ChunkId[],
): Promise<readonly SearchHit[]> => {
  if (ranking.length === 0) return []
  const placeholders = ranking.map(() => "?").join(",")
  const result = await database.execute({
    sql: `SELECT id, call_id, start_ms, end_ms, text FROM transcript_chunks WHERE id IN (${placeholders})`,
    args: [...ranking],
  })
  const byID = new Map<ChunkId, SearchHit>()
  for (const row of result.rows) {
    const chunkId = ChunkIdSchema.parse(row[0])
    byID.set(chunkId, {
      chunkId,
      callId: CallIdSchema.parse(row[1]),
      startMs: DatabaseIntegerSchema.parse(row[2]),
      endMs: DatabaseIntegerSchema.parse(row[3]),
      text: z.string().parse(row[4]),
    })
  }
  return ranking.flatMap((id) => {
    const hit = byID.get(id)
    return hit === undefined ? [] : [hit]
  })
}

export const searchCalls = async (
  database: Client,
  embedder: QueryEmbedder,
  query: string,
  mode: SearchMode,
  limit: number,
  filters: SearchFilters = {},
): Promise<readonly SearchHit[]> => {
  const trimmedQuery = query.trim()
  if (trimmedQuery.length === 0 || limit < 1) return []
  const candidateLimit = Math.max(limit * 4, 20)

  if (mode === "lexical") {
    return fetchHits(
      database,
      (await lexicalRanking(database, trimmedQuery, candidateLimit, filters)).slice(0, limit),
    )
  }
  if (mode === "semantic") {
    return fetchHits(
      database,
      (await semanticRanking(database, embedder, trimmedQuery, candidateLimit, filters)).slice(
        0,
        limit,
      ),
    )
  }
  const [lexical, semantic] = await Promise.all([
    lexicalRanking(database, trimmedQuery, candidateLimit, filters),
    semanticRanking(database, embedder, trimmedQuery, candidateLimit, filters),
  ])
  const fused = reciprocalRankFusion([lexical, semantic])
    .slice(0, limit)
    .map(({ id }) => id)
  return fetchHits(database, fused)
}
