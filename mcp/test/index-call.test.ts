import { describe, expect, test } from "bun:test"
import { mkdtempSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { fileURLToPath } from "node:url"
import type { Client } from "@libsql/client"
import { type CallId, CallIdSchema } from "../src/contracts.ts"
import { openDatabase } from "../src/database.ts"
import {
  type DocumentEmbedder,
  indexCall,
  parseIndexCommand,
  runIndexCommand,
} from "../src/index-call.ts"

const vector = (): readonly number[] => [1, ...Array.from({ length: 255 }, () => 0)]

type IndexFixture = {
  readonly database: Client
  readonly callId: CallId
  readonly transcriptPath: string
}

class TestEmbeddingError extends Error {
  readonly name = "TestEmbeddingError"
}

const writeTranscript = async (path: string, callId: CallId, text: string): Promise<void> => {
  await Bun.write(
    path,
    JSON.stringify({
      callId,
      language: "ru",
      model: "small",
      participants: [],
      glossary: [],
      segments: [{ startMs: 0, endMs: 1_000, text }],
    }),
  )
}

const fixtureDatabase = async (): Promise<IndexFixture> => {
  const directory = mkdtempSync(join(tmpdir(), "call-recorder-index-"))
  const database = openDatabase(join(directory, "calls.db"))
  const callId = CallIdSchema.parse("3eab7aee-1f8a-48b9-94ca-d720858c8ed0")
  const transcriptPath = join(directory, "transcript.json")
  await writeTranscript(transcriptPath, callId, "Обсудили план запуска.")
  await database.executeMultiple(`
    PRAGMA foreign_keys = ON;
    CREATE TABLE calls (
      id TEXT PRIMARY KEY,
      started_at REAL NOT NULL,
      ended_at REAL,
      audio_path TEXT,
      status TEXT NOT NULL
    );
    CREATE TABLE transcripts (
      call_id TEXT PRIMARY KEY REFERENCES calls(id),
      language TEXT NOT NULL,
      model TEXT NOT NULL,
      text TEXT NOT NULL,
      markdown_path TEXT NOT NULL,
      json_path TEXT NOT NULL
    );
    CREATE TABLE index_jobs (
      call_id TEXT PRIMARY KEY REFERENCES calls(id),
      status TEXT NOT NULL,
      error TEXT
    );
  `)
  await database.batch([
    {
      sql: "INSERT INTO calls VALUES (?, ?, ?, ?, ?)",
      args: [callId, 1_800_000_000, 1_800_000_001, "/tmp/call.m4a", "indexing"],
    },
    {
      sql: "INSERT INTO transcripts VALUES (?, ?, ?, ?, ?, ?)",
      args: [callId, "ru", "small", "Обсудили план запуска.", "/tmp/transcript.md", transcriptPath],
    },
    { sql: "INSERT INTO index_jobs VALUES (?, ?, NULL)", args: [callId, "pending"] },
  ])
  return { database, callId, transcriptPath }
}

describe("indexCall", () => {
  test("parses an explicit local indexing command", () => {
    // Given
    const callId = "3eab7aee-1f8a-48b9-94ca-d720858c8ed0"

    // When
    const command = parseIndexCommand([
      "index",
      "--database",
      "/tmp/calls.db",
      "--call-id",
      callId,
      "--cache",
      "/tmp/models",
    ])

    // Then
    expect(command).toEqual({
      kind: "index",
      databasePath: "/tmp/calls.db",
      callId,
      cacheDirectory: "/tmp/models",
    })
  })

  test("parses an explicit local embedding-model download command", () => {
    // Given / When
    const command = parseIndexCommand(["download-model", "--cache", "/tmp/models"])

    // Then
    expect(command).toEqual({ kind: "download-model", cacheDirectory: "/tmp/models" })
  })

  test("model download command explicitly enables remote model acquisition", async () => {
    // Given
    /** Observation buffer: recording the model loader policy is its sole purpose. */
    const downloadPolicies: boolean[] = []
    const embedder: DocumentEmbedder = {
      modelVersion: "test-model:256",
      embedDocuments: async (documents) => documents.map(vector),
    }

    // When
    const result = await runIndexCommand(
      { kind: "download-model", cacheDirectory: "/tmp/models" },
      {
        openDatabase,
        loadEmbeddingService: async (_cacheDirectory, allowDownload) => {
          downloadPolicies.push(allowDownload)
          return embedder
        },
      },
    )

    // Then
    expect(result).toEqual({ kind: "model-ready" })
    expect(downloadPolicies).toEqual([true])
  })

  test("CLI rejects an unsafe relative database path", async () => {
    // Given
    const script = fileURLToPath(new URL("../src/index-call.ts", import.meta.url))

    // When
    const subprocess = Bun.spawn(
      [
        process.execPath,
        script,
        "index",
        "--database",
        "relative.db",
        "--call-id",
        "3eab7aee-1f8a-48b9-94ca-d720858c8ed0",
        "--cache",
        "/tmp/models",
      ],
      { stdout: "ignore", stderr: "ignore" },
    )

    // Then
    expect(await subprocess.exited).toBe(1)
  })

  test("indexes a pending transcript and marks the call ready", async () => {
    // Given
    const { database, callId } = await fixtureDatabase()
    const embedder: DocumentEmbedder = {
      modelVersion: "test-model:256",
      embedDocuments: async (documents) => documents.map(vector),
    }

    // When
    const result = await indexCall(database, callId, embedder)

    // Then
    expect(result).toEqual({ kind: "indexed", chunkCount: 1 })
    const chunks = await database.execute(
      "SELECT text, embedding_model FROM transcript_chunks WHERE call_id = ?",
      [callId],
    )
    expect(chunks.rows[0]?.[0]).toBe("Обсудили план запуска.")
    expect(chunks.rows[0]?.[1]).toBe("test-model:256")
    expect(
      (await database.execute("SELECT status FROM calls WHERE id = ?", [callId])).rows[0]?.[0],
    ).toBe("ready")
    const job = await database.execute("SELECT status, error FROM index_jobs WHERE call_id = ?", [
      callId,
    ])
    expect(job.rows[0]?.[0]).toBe("ready")
    expect(job.rows[0]?.[1]).toBeNull()
    database.close()
  })

  test("indexes committed transcript text after JSON cleanup", async () => {
    // Given
    const { database, callId, transcriptPath } = await fixtureDatabase()
    rmSync(transcriptPath)
    const embedder: DocumentEmbedder = {
      modelVersion: "test-model:256",
      embedDocuments: async (documents) => documents.map(vector),
    }

    // When
    const result = await indexCall(database, callId, embedder)

    // Then
    expect(result).toEqual({ kind: "indexed", chunkCount: 1 })
    const chunks = await database.execute("SELECT text FROM transcript_chunks WHERE call_id = ?", [
      callId,
    ])
    expect(chunks.rows[0]?.[0]).toBe("Обсудили план запуска.")
    database.close()
  })

  test("skips unchanged chunks already stored with the current model", async () => {
    // Given
    const { database, callId } = await fixtureDatabase()
    /** Observation counter: proving unchanged indexing avoids local model inference. */
    let embeddingCalls = 0
    const embedder: DocumentEmbedder = {
      modelVersion: "test-model:256",
      embedDocuments: async (documents) => {
        embeddingCalls += 1
        return documents.map(vector)
      },
    }
    await indexCall(database, callId, embedder)

    // When
    const result = await indexCall(database, callId, embedder)

    // Then
    expect(result).toEqual({ kind: "skipped", chunkCount: 1 })
    expect(embeddingCalls).toBe(1)
    database.close()
  })

  test("an embedding failure keeps prior chunks and leaves a retryable failed job", async () => {
    // Given
    const { database, callId, transcriptPath } = await fixtureDatabase()
    const workingEmbedder: DocumentEmbedder = {
      modelVersion: "test-model:256",
      embedDocuments: async (documents) => documents.map(vector),
    }
    await indexCall(database, callId, workingEmbedder)
    await writeTranscript(transcriptPath, callId, "Изменили план запуска.")
    const failingEmbedder: DocumentEmbedder = {
      modelVersion: "test-model:256",
      embedDocuments: async () => {
        throw new TestEmbeddingError("fixture embedding failure")
      },
    }

    // When / Then
    expect(indexCall(database, callId, failingEmbedder)).rejects.toBeInstanceOf(TestEmbeddingError)
    const chunks = await database.execute("SELECT text FROM transcript_chunks WHERE call_id = ?", [
      callId,
    ])
    expect(chunks.rows.map((row) => row[0])).toEqual(["Обсудили план запуска."])
    expect(
      (await database.execute("SELECT status FROM calls WHERE id = ?", [callId])).rows[0]?.[0],
    ).toBe("failed")
    const job = await database.execute("SELECT status, error FROM index_jobs WHERE call_id = ?", [
      callId,
    ])
    expect(job.rows[0]?.[0]).toBe("failed")
    expect(job.rows[0]?.[1]).toBe("fixture embedding failure")
    database.close()
  })
})
