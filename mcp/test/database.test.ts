import { describe, expect, test } from "bun:test"
import { mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { migrateSearchSchema, openDatabase } from "../src/database.ts"

const temporaryDatabasePath = (): string =>
  join(mkdtempSync(join(tmpdir(), "call-recorder-mcp-")), "calls.db")

describe("local Turso database", () => {
  test("search migration is idempotent and enables vector plus BM25 queries", async () => {
    // Given
    const database = openDatabase(temporaryDatabasePath())
    await database.executeMultiple(`
      PRAGMA foreign_keys = ON;
      CREATE TABLE calls (id TEXT PRIMARY KEY);
      CREATE TABLE transcripts (call_id TEXT PRIMARY KEY REFERENCES calls(id));
      INSERT INTO calls (id) VALUES ('3eab7aee-1f8a-48b9-94ca-d720858c8ed0');
      INSERT INTO transcripts (call_id) VALUES ('3eab7aee-1f8a-48b9-94ca-d720858c8ed0');
    `)

    // When
    await migrateSearchSchema(database)
    await migrateSearchSchema(database)
    await database.execute({
      sql: `INSERT INTO transcript_chunks
        (id, call_id, start_ms, end_ms, text, content_hash, embedding, embedding_model)
        VALUES (?, ?, ?, ?, ?, ?, vector32(?), ?)`,
      args: [
        "chunk-1",
        "3eab7aee-1f8a-48b9-94ca-d720858c8ed0",
        0,
        1_000,
        "Discussed launch planning",
        "hash-1",
        JSON.stringify([1, ...Array.from({ length: 255 }, () => 0)]),
        "embeddinggemma-300m@q4:256",
      ],
    })
    const version = await database.execute("PRAGMA user_version")
    const lexical = await database.execute(
      "SELECT id, bm25(transcript_chunks_fts) AS score FROM transcript_chunks_fts " +
        "WHERE transcript_chunks_fts MATCH 'launch'",
    )
    const vector = await database.execute(
      "SELECT vector_distance_cos(vector32('[1,0]'), vector32('[1,0]')) AS distance",
    )
    const requests = await database.execute(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'speaker_review_requests'",
    )

    // Then
    expect(version.rows[0]?.[0]).toBe(2)
    expect(lexical.rows[0]?.[0]).toBe("chunk-1")
    expect(typeof lexical.rows[0]?.[1]).toBe("number")
    expect(vector.rows[0]?.[0]).toBe(0)
    expect(requests.rows[0]?.[0]).toBe("speaker_review_requests")

    database.close()
  })

  test("a completed search migration stays read-only while another writer is active", async () => {
    // Given
    const path = temporaryDatabasePath()
    const writerDatabase = openDatabase(path)
    await writerDatabase.executeMultiple(`
      CREATE TABLE calls (id TEXT PRIMARY KEY);
      CREATE TABLE transcripts (call_id TEXT PRIMARY KEY REFERENCES calls(id));
    `)
    await migrateSearchSchema(writerDatabase)
    const writer = await writerDatabase.transaction("write")
    const readerDatabase = openDatabase(path)

    try {
      // When
      await migrateSearchSchema(readerDatabase)

      // Then
      const version = await readerDatabase.execute("PRAGMA user_version")
      expect(version.rows[0]?.[0]).toBe(2)
    } finally {
      await writer.rollback()
      readerDatabase.close()
      writerDatabase.close()
    }
  })
})
