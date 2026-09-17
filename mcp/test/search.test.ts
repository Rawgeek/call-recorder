import { describe, expect, test } from "bun:test"
import { mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { ChunkIdSchema } from "../src/contracts.ts"
import { migrateSearchSchema, openDatabase } from "../src/database.ts"
import { type QueryEmbedder, reciprocalRankFusion, searchCalls } from "../src/search.ts"

const vector = (first: number, second: number): readonly number[] => [
  first,
  second,
  ...Array.from({ length: 254 }, () => 0),
]

const MODEL_VERSION = "test:256"

const fakeEmbedder: QueryEmbedder = {
  modelVersion: MODEL_VERSION,
  embedQuery: async (query) => (query.includes("shipping") ? vector(0, 1) : vector(1, 0)),
}

const fixtureDatabase = async () => {
  const path = join(mkdtempSync(join(tmpdir(), "call-recorder-search-")), "calls.db")
  const database = openDatabase(path)
  await database.executeMultiple(`
    PRAGMA foreign_keys = ON;
    CREATE TABLE calls (id TEXT PRIMARY KEY, started_at REAL NOT NULL);
    CREATE TABLE transcripts (call_id TEXT PRIMARY KEY REFERENCES calls(id));
    CREATE TABLE participants (id TEXT PRIMARY KEY, name TEXT NOT NULL);
    CREATE TABLE call_participants (
      call_id TEXT NOT NULL REFERENCES calls(id),
      participant_id TEXT NOT NULL REFERENCES participants(id)
    );
    INSERT INTO calls VALUES ('3eab7aee-1f8a-48b9-94ca-d720858c8ed0', 1800000000);
    INSERT INTO calls VALUES ('7ab89e88-5958-4f28-a69b-7a285a091f6d', 1900000000);
    INSERT INTO transcripts VALUES ('3eab7aee-1f8a-48b9-94ca-d720858c8ed0');
    INSERT INTO transcripts VALUES ('7ab89e88-5958-4f28-a69b-7a285a091f6d');
    INSERT INTO participants VALUES ('51d1fee8-5085-420f-a393-70b28ebcc8a0', 'Alice');
    INSERT INTO participants VALUES ('70524379-bd17-4cdd-a4db-061139385abc', 'Bob');
    INSERT INTO call_participants VALUES (
      '3eab7aee-1f8a-48b9-94ca-d720858c8ed0',
      '51d1fee8-5085-420f-a393-70b28ebcc8a0'
    );
    INSERT INTO call_participants VALUES (
      '7ab89e88-5958-4f28-a69b-7a285a091f6d',
      '70524379-bd17-4cdd-a4db-061139385abc'
    );
  `)
  await migrateSearchSchema(database)
  const rows = [
    ["a", "Project Zephyr launch checklist", vector(1, 0)],
    ["b", "Discussed how to ship the new product", vector(0, 1)],
    ["c", "Обсудили бюджет и сроки запуска", vector(0.7, 0.3)],
    ["d", "製品の発売予定を確認しました", vector(0.5, 0.5)],
  ] as const
  for (const [id, text, embedding] of rows) {
    await database.execute({
      sql: `INSERT INTO transcript_chunks
        (id, call_id, start_ms, end_ms, text, content_hash, embedding, embedding_model)
        VALUES (?, ?, ?, ?, ?, ?, vector32(?), ?)`,
      args: [
        id,
        "3eab7aee-1f8a-48b9-94ca-d720858c8ed0",
        0,
        1_000,
        text,
        `hash-${id}`,
        JSON.stringify(embedding),
        "test:256",
      ],
    })
  }
  await database.execute({
    sql: `INSERT INTO transcript_chunks
      (id, call_id, start_ms, end_ms, text, content_hash, embedding, embedding_model)
      VALUES (?, ?, ?, ?, ?, ?, vector32(?), ?)`,
    args: [
      "e",
      "7ab89e88-5958-4f28-a69b-7a285a091f6d",
      0,
      1_000,
      "Launch budget review",
      "hash-e",
      JSON.stringify(vector(0.8, 0.2)),
      "test:256",
    ],
  })
  return database
}

describe("reciprocalRankFusion", () => {
  test("promotes an item found by lexical and semantic rankings", () => {
    // Given
    const first = [ChunkIdSchema.parse("a"), ChunkIdSchema.parse("b")]
    const second = [ChunkIdSchema.parse("b"), ChunkIdSchema.parse("c")]

    // When
    const fused = reciprocalRankFusion([first, second])

    // Then
    expect(fused.map(({ id }) => id)).toEqual(["b", "a", "c"])
  })
})

describe("searchCalls", () => {
  test("BM25 returns exact project names", async () => {
    // Given
    const database = await fixtureDatabase()

    // When
    const hits = await searchCalls(database, fakeEmbedder, "Zephyr", "lexical", 5)

    // Then
    expect(hits.map(({ chunkId }) => chunkId)).toEqual(["a"])
    database.close()
  })

  test("semantic search returns a paraphrased shipping discussion", async () => {
    // Given
    const database = await fixtureDatabase()

    // When
    const hits = await searchCalls(database, fakeEmbedder, "shipping timeline", "semantic", 1)

    // Then
    expect(hits[0]?.chunkId).toBe("b")
    database.close()
  })

  test("hybrid search retains lexical and semantic candidates", async () => {
    // Given
    const database = await fixtureDatabase()

    // When
    const hits = await searchCalls(database, fakeEmbedder, "Zephyr shipping", "hybrid", 5)

    // Then
    expect(hits.map(({ chunkId }) => chunkId)).toContain("a")
    expect(hits.map(({ chunkId }) => chunkId)).toContain("b")
    database.close()
  })

  test("lexical search handles Russian text", async () => {
    // Given
    const database = await fixtureDatabase()

    // When
    const hits = await searchCalls(database, fakeEmbedder, "бюджет", "lexical", 5)

    // Then
    expect(hits[0]?.chunkId).toBe("c")
    database.close()
  })

  test("lexical fallback finds a Unicode substring missed as a token", async () => {
    // Given
    const database = await fixtureDatabase()

    // When
    const hits = await searchCalls(database, fakeEmbedder, "発売", "lexical", 5)

    // Then
    expect(hits[0]?.chunkId).toBe("d")
    database.close()
  })

  test("semantic search ignores vectors built by a superseded model", async () => {
    // Given an archived chunk whose vector came from the model this build no longer uses, and
    // whose vector would otherwise be the closest match in the database.
    const database = await fixtureDatabase()
    await database.execute({
      sql: `INSERT INTO transcript_chunks
        (id, call_id, start_ms, end_ms, text, content_hash, embedding, embedding_model)
        VALUES (?, ?, ?, ?, ?, ?, vector32(?), ?)`,
      args: [
        "stale",
        "3eab7aee-1f8a-48b9-94ca-d720858c8ed0",
        0,
        1_000,
        "Archived discussion about ocean freight",
        "hash-stale",
        JSON.stringify(vector(0, 1)),
        "superseded:256",
      ],
    })

    // When
    const semantic = await searchCalls(database, fakeEmbedder, "shipping", "semantic", 5)
    const lexical = await searchCalls(database, fakeEmbedder, "Archived", "lexical", 5)

    // Then the incomparable vector is never ranked...
    expect(semantic.map(({ chunkId }) => chunkId)).not.toContain("stale")
    // ...but the words are still reachable, because no model is needed to read them.
    expect(lexical.map(({ chunkId }) => chunkId)).toContain("stale")
    database.close()
  })

  test("applies date and participant filters before bounding results", async () => {
    // Given
    const database = await fixtureDatabase()

    // When
    const hits = await searchCalls(database, fakeEmbedder, "project launch", "lexical", 1, {
      participantIds: ["70524379-bd17-4cdd-a4db-061139385abc"],
      startedAfter: 1_850_000_000,
    })

    // Then
    expect(hits.map(({ chunkId }) => chunkId)).toEqual(["e"])
    database.close()
  })

  test("participant filters match identifiers stored with different casing", async () => {
    // Given
    const database = await fixtureDatabase()

    // When
    const hits = await searchCalls(database, fakeEmbedder, "project launch", "lexical", 1, {
      participantIds: ["70524379-BD17-4CDD-A4DB-061139385ABC"],
      startedAfter: 1_850_000_000,
    })

    // Then
    expect(hits.map(({ chunkId }) => chunkId)).toEqual(["e"])
    database.close()
  })
})
