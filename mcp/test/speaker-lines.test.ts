import { afterEach, beforeEach, describe, expect, test } from "bun:test"
import { mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import type { Client as DatabaseClient } from "@libsql/client"
import { Client } from "@modelcontextprotocol/sdk/client/index.js"
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js"
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js"
import { z } from "zod"
import { openDatabase } from "../src/database.ts"
import type { QueryEmbedder } from "../src/search.ts"
import { createCallRecorderServer } from "../src/server.ts"

const callID = "3EAB7AEE-1F8A-48B9-94CA-D720858C8ED0"
const otherCallID = "9C1B4E5A-2D3F-4A6B-8C7D-1E2F3A4B5C6D"
const participantID = "51D1FEE8-5085-420F-A393-70B28EBCC8A0"
const embedder: QueryEmbedder = { modelVersion: "test:256", embedQuery: async () => [] }

/// A database holding the request table the queued line changes land in.
///
/// The table is built here rather than by the MCP server: the server reads and writes a database the
/// signed app migrates, and these tests are about what the server puts in it.
const fixtureDatabase = async (): Promise<DatabaseClient> => {
  const directory = mkdtempSync(join(tmpdir(), "call-recorder-speaker-lines-"))
  const database = openDatabase(join(directory, "calls.db"))
  await database.executeMultiple(
    "PRAGMA foreign_keys = ON;" +
      "CREATE TABLE calls (id TEXT PRIMARY KEY, started_at REAL NOT NULL," +
      " ended_at REAL, audio_path TEXT, status TEXT NOT NULL);" +
      "CREATE TABLE participants (id TEXT PRIMARY KEY, name TEXT NOT NULL," +
      " normalized_name TEXT NOT NULL UNIQUE, role TEXT, company TEXT, email TEXT);" +
      "CREATE TABLE pending_speaker_clusters (id TEXT PRIMARY KEY," +
      " call_id TEXT NOT NULL REFERENCES calls(id), speaker_index INTEGER NOT NULL," +
      " speaker_label TEXT NOT NULL, model_version TEXT NOT NULL," +
      " encrypted_embedding BLOB NOT NULL, speech_ms INTEGER NOT NULL," +
      " created_at REAL NOT NULL, expires_at REAL NOT NULL);" +
      "CREATE TABLE speaker_review_requests (id TEXT PRIMARY KEY," +
      " cluster_id TEXT REFERENCES pending_speaker_clusters(id), " +
      " call_id TEXT REFERENCES calls(id), " +
      " participant_id TEXT REFERENCES participants(id), action TEXT NOT NULL," +
      " status TEXT NOT NULL, start_ms INTEGER, end_ms INTEGER, error TEXT," +
      " claim_token TEXT UNIQUE, created_at REAL NOT NULL, updated_at REAL NOT NULL," +
      " CHECK((action = 'assignLines' AND participant_id IS NOT NULL)" +
      " OR (action = 'releaseLines' AND participant_id IS NULL)));",
  )
  await database.batch([
    {
      sql: "INSERT INTO calls VALUES (?, 1800000000, NULL, NULL, 'ready')",
      args: [callID],
    },
    {
      sql: "INSERT INTO calls VALUES (?, 1800000001, NULL, NULL, 'ready')",
      args: [otherCallID],
    },
    {
      sql: "INSERT INTO participants VALUES (?, 'Adam', 'adam', NULL, NULL, NULL)",
      args: [participantID],
    },
  ])
  return database
}

describe("Call Recorder speaker line MCP tools", () => {
  let database: DatabaseClient
  let server: McpServer
  let client: Client

  beforeEach(async () => {
    database = await fixtureDatabase()
    server = createCallRecorderServer(database, embedder)
    client = new Client({ name: "test-client", version: "1.0.0" })
    const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair()
    await server.connect(serverTransport)
    await client.connect(clientTransport)
  })

  afterEach(async () => {
    await client.close()
    await server.close()
    database.close()
  })

  const queue = async (participantId: string | null, endMs = 30_000) =>
    z
      .object({
        request: z.object({
          id: z.uuid(),
          callId: z.uuid(),
          participantId: z.uuid().nullable(),
          startMs: z.int(),
          endMs: z.int(),
          action: z.enum(["assignLines", "releaseLines"]),
          status: z.string(),
        }),
      })
      .parse(
        (
          await client.callTool({
            name: "assign_speaker_lines",
            arguments: { callId: callID, startMs: 16_000, endMs, participantId },
          })
        ).structuredContent,
      ).request

  test("queues a line assignment for the signed app", async () => {
    const request = await queue(participantID)
    expect(request.action).toBe("assignLines")
    expect(request.participantId).toBe(participantID)
    expect(request.startMs).toBe(16_000)
    expect(request.endMs).toBe(30_000)
    expect(request.status).toBe("pending")
  })

  test("a null participant releases the lines instead of assigning them", async () => {
    // One tool for both directions: a caller that has the range and no name wants the lines back
    // under the voice own name, which is the only way an assignment is undone.
    const request = await queue(null)
    expect(request.action).toBe("releaseLines")
    expect(request.participantId).toBeNull()
  })

  test("asks for the same change twice returns the request already waiting", async () => {
    const first = await queue(participantID)
    const second = await queue(participantID)
    expect(second.id).toBe(first.id)
    const rows = await database.execute("SELECT count(*) FROM speaker_review_requests")
    expect(Number(rows.rows[0]?.[0])).toBe(1)
  })

  test("refuses a range that ends before it starts", async () => {
    // A range the app could only fail on is refused where the caller can be told why.
    const result = await client.callTool({
      name: "assign_speaker_lines",
      arguments: { callId: callID, startMs: 30_000, endMs: 16_000, participantId: participantID },
    })
    expect(result.isError).toBe(true)
  })

  test("refuses a person the roster does not hold", async () => {
    const result = await client.callTool({
      name: "assign_speaker_lines",
      arguments: {
        callId: callID,
        startMs: 16_000,
        endMs: 30_000,
        participantId: "00000000-0000-4000-8000-000000000000",
      },
    })
    expect(result.isError).toBe(true)
  })

  test("refuses a call the library does not hold", async () => {
    const result = await client.callTool({
      name: "assign_speaker_lines",
      arguments: {
        callId: "00000000-0000-4000-8000-000000000001",
        startMs: 16_000,
        endMs: 30_000,
        participantId: participantID,
      },
    })
    expect(result.isError).toBe(true)
  })

  test("reports a queued request by its identifier", async () => {
    const request = await queue(participantID)
    const read = z
      .object({ request: z.object({ id: z.uuid(), callId: z.uuid(), status: z.string() }) })
      .parse(
        (
          await client.callTool({
            name: "get_speaker_line_request",
            arguments: { requestId: request.id },
          })
        ).structuredContent,
      ).request
    expect(read.id).toBe(request.id)
    expect(read.callId).toBe(callID)
    expect(read.status).toBe("pending")
  })

  test("never returns a voiceprint from a line request", async () => {
    await database.execute({
      sql: "INSERT INTO pending_speaker_clusters VALUES (?, ?, 0, 'S', 'm', ?, 1, 1, 1)",
      args: [
        "5BC36497-D417-48CF-A2B0-E3F7D42AE98F",
        callID,
        "VOICEPRINT_SENTINEL_MUST_NOT_LEAVE_DATABASE",
      ],
    })
    const request = await queue(participantID)
    expect(JSON.stringify(request)).not.toContain("VOICEPRINT_SENTINEL")
  })
})
