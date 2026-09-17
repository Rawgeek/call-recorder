import { afterEach, beforeEach, describe, expect, test } from "bun:test"
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import type { Client as DatabaseClient } from "@libsql/client"
import { Client } from "@modelcontextprotocol/sdk/client/index.js"
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js"
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js"
import { z } from "zod"
import { migrateSearchSchema, openDatabase } from "../src/database.ts"
import type { QueryEmbedder } from "../src/search.ts"
import { createCallRecorderServer } from "../src/server.ts"

const callID = "3EAB7AEE-1F8A-48B9-94CA-D720858C8ED0"
const participantID = "51D1FEE8-5085-420F-A393-70B28EBCC8A0"
const clusterID = "5BC36497-D417-48CF-A2B0-E3F7D42AE98F"
const embedder: QueryEmbedder = { modelVersion: "test:256", embedQuery: async () => [] }

const fixtureDatabase = async (): Promise<DatabaseClient> => {
  const directory = mkdtempSync(join(tmpdir(), "call-recorder-speaker-tools-"))
  const recordingDirectory = join(directory, "recording")
  const audioPath = join(recordingDirectory, "call.m4a")
  const transcriptPath = join(directory, "transcript.json")
  mkdirSync(recordingDirectory)
  writeFileSync(audioPath, "audio")
  writeFileSync(
    transcriptPath,
    JSON.stringify({
      segments: [
        {
          startMs: 0,
          endMs: 1_000,
          text: "First identifying phrase.",
          speakerIndex: 0,
          source: "system",
        },
        {
          startMs: 1_000,
          endMs: 2_000,
          text: "A different voice.",
          speakerIndex: 1,
          source: "system",
        },
        {
          startMs: 2_000,
          endMs: 3_000,
          text: "Second identifying phrase.",
          speakerIndex: 0,
          source: "system",
        },
        { startMs: 3_000, endMs: 4_000, text: "No label.", source: "system" },
        {
          startMs: 4_000,
          endMs: 5_000,
          text: "Third identifying phrase.",
          speakerIndex: 0,
          source: "system",
        },
        {
          startMs: 5_000,
          endMs: 6_000,
          text: "Local microphone must never be used as remote voice evidence.",
          speakerIndex: 0,
          source: "microphone",
        },
      ],
    }),
  )
  const database = openDatabase(join(directory, "calls.db"))
  await database.executeMultiple(`
    PRAGMA foreign_keys = ON;
    CREATE TABLE calls (
      id TEXT PRIMARY KEY, started_at REAL NOT NULL, ended_at REAL,
      audio_path TEXT, status TEXT NOT NULL
    );
    CREATE TABLE participants (
      id TEXT PRIMARY KEY, name TEXT NOT NULL, normalized_name TEXT NOT NULL UNIQUE,
      role TEXT, company TEXT, email TEXT
    );
    CREATE TABLE transcripts (
      call_id TEXT PRIMARY KEY REFERENCES calls(id), language TEXT NOT NULL,
      model TEXT NOT NULL, text TEXT NOT NULL, markdown_path TEXT NOT NULL, json_path TEXT NOT NULL
    );
    CREATE TABLE pending_speaker_clusters (
      id TEXT PRIMARY KEY, call_id TEXT NOT NULL REFERENCES calls(id),
      speaker_index INTEGER NOT NULL, speaker_label TEXT NOT NULL,
      model_version TEXT NOT NULL, encrypted_embedding BLOB NOT NULL,
      speech_ms INTEGER NOT NULL, created_at REAL NOT NULL, expires_at REAL NOT NULL
    );
    CREATE TABLE speaker_assignments (
      cluster_id TEXT PRIMARY KEY REFERENCES pending_speaker_clusters(id),
      call_id TEXT NOT NULL REFERENCES calls(id), speaker_index INTEGER NOT NULL,
      participant_id TEXT REFERENCES participants(id), state TEXT NOT NULL,
      confidence_band TEXT NOT NULL, updated_at REAL NOT NULL, reviewed_at REAL
    );
  `)
  await database.batch(
    [
      {
        sql: "INSERT INTO calls VALUES (?, 1800000000, NULL, ?, 'ready')",
        args: [callID, audioPath],
      },
      {
        sql: "INSERT INTO participants VALUES (?, 'Alice', 'alice', 'Engineer', 'Globex', NULL)",
        args: [participantID],
      },
      {
        sql: "INSERT INTO transcripts VALUES (?, 'en', 'small', 'text', '/tmp/t.md', ?)",
        args: [callID, transcriptPath],
      },
      {
        sql: `INSERT INTO pending_speaker_clusters
          VALUES (?, ?, 0, 'Speaker 1', 'model-v1', ?, 3000, 1600000000, 1700000000)`,
        args: [clusterID, callID, "VOICEPRINT_SENTINEL_MUST_NOT_LEAVE_DATABASE"],
      },
      {
        sql: `INSERT INTO speaker_assignments
          VALUES (?, ?, 0, ?, 'suggested', 'review', 1800000000, NULL)`,
        args: [clusterID, callID, participantID],
      },
    ],
    "write",
  )
  await migrateSearchSchema(database)
  return database
}

describe("Call Recorder speaker MCP tools", () => {
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

  test("lists three bounded speaker samples without exposing voiceprints", async () => {
    const result = await client.callTool({
      name: "list_speaker_reviews",
      arguments: { limit: 20 },
    })

    expect(result.structuredContent).toMatchObject({
      reviews: [
        {
          clusterId: clusterID,
          suggestedParticipant: { id: participantID, name: "Alice" },
          transcriptSamples: [
            { text: "First identifying phrase." },
            { text: "Second identifying phrase." },
            { text: "Third identifying phrase." },
          ],
          audioAvailable: true,
        },
      ],
    })
    expect(JSON.stringify(result)).not.toContain("VOICEPRINT_SENTINEL_MUST_NOT_LEAVE_DATABASE")
  })

  test("maps a speaker to a participant stored with a lowercase identifier", async () => {
    // Given
    const lowercaseID = "5d1c7a70-6a0f-4c9b-9e7d-2c7e6a1b0f31"
    await database.execute({
      sql: "INSERT INTO participants VALUES (?, 'Bob', 'bob', NULL, NULL, NULL)",
      args: [lowercaseID],
    })

    // When
    const result = await client.callTool({
      name: "set_speaker_identity",
      arguments: { clusterId: clusterID, participantId: lowercaseID.toUpperCase() },
    })

    // Then
    expect(result.structuredContent).toMatchObject({
      request: { participantId: lowercaseID, action: "confirm", status: "pending" },
    })
    const stored = await database.execute({
      sql: "SELECT participant_id FROM speaker_review_requests WHERE cluster_id = ?",
      args: [clusterID],
    })
    expect(stored.rows[0]?.[0]).toBe(lowercaseID)
  })

  test("reopens a decided speaker so a wrong name can be corrected", async () => {
    // Given a mapping the signed app already decided
    await database.execute({
      sql: "UPDATE speaker_assignments SET state = 'confirmed', reviewed_at = 1800000000 WHERE cluster_id = ?",
      args: [clusterID],
    })

    // When
    const result = await client.callTool({
      name: "reopen_speaker_review",
      arguments: { clusterId: clusterID.toLowerCase() },
    })

    // Then
    expect(result.structuredContent).toMatchObject({
      request: { clusterId: clusterID, participantId: null, action: "reopen", status: "pending" },
    })
    const stored = await database.execute({
      sql: "SELECT action, participant_id FROM speaker_review_requests WHERE cluster_id = ?",
      args: [clusterID],
    })
    expect(stored.rows[0]?.[0]).toBe("reopen")
    expect(stored.rows[0]?.[1]).toBeNull()
  })

  test("reports diarization coverage and unresolved speakers", async () => {
    const result = await client.callTool({
      name: "get_diarization_quality",
      arguments: { callId: callID },
    })

    expect(result.structuredContent).toMatchObject({
      report: {
        status: "review",
        systemSegmentCount: 5,
        diarizedSystemSegmentCount: 4,
        systemSpeechMs: 5_000,
        diarizedSystemSpeechMs: 4_000,
        diarizationCoverage: 0.8,
        unresolvedSpeakerCount: 1,
        warnings: ["missing_speaker_labels", "unresolved_speakers"],
      },
    })
  })

  test("queues an idempotent request without mutating the speaker assignment", async () => {
    const first = await client.callTool({
      name: "set_speaker_identity",
      arguments: { clusterId: clusterID.toLowerCase(), participantId: participantID.toLowerCase() },
    })
    const repeated = await client.callTool({
      name: "set_speaker_identity",
      arguments: { clusterId: clusterID, participantId: participantID },
    })

    expect(repeated.structuredContent).toEqual(first.structuredContent)
    const requestId = z
      .object({ request: z.object({ id: z.uuid(), status: z.literal("pending") }) })
      .parse(first.structuredContent).request.id
    const assignment = await database.execute({
      sql: "SELECT state, reviewed_at FROM speaker_assignments WHERE cluster_id = ?",
      args: [clusterID],
    })
    expect([assignment.rows[0]?.[0], assignment.rows[0]?.[1]]).toEqual(["suggested", null])
    const status = await client.callTool({
      name: "get_speaker_identity_request",
      arguments: { requestId },
    })
    expect(status.structuredContent).toEqual(first.structuredContent)
  })
  test("re-queues a mapping after the speaker was already decided", async () => {
    // Given a speaker that is already confirmed for Alice
    await database.execute({
      sql: "UPDATE speaker_assignments SET state = ?, reviewed_at = 1800000000 WHERE cluster_id = ?",
      args: ["confirmed", clusterID],
    })
    await database.execute({
      sql:
        "INSERT INTO speaker_review_requests" +
        " (id, cluster_id, participant_id, action, status, created_at, updated_at)" +
        " VALUES (?, ?, ?, ?, ?, 1800000000, 1800000000)",
      args: [
        "11111111-2222-4333-8444-555555555555",
        clusterID,
        participantID,
        "confirm",
        "completed",
      ],
    })

    // When the mapping is requested again for the same participant
    const result = await client.callTool({
      name: "set_speaker_identity",
      arguments: { clusterId: clusterID, participantId: participantID },
    })

    // Then the queued request is pending again so the signed app re-applies it
    expect(result.structuredContent).toMatchObject({
      request: { clusterId: clusterID, participantId: participantID, status: "pending" },
    })
  })

  test("queues a correction for a speaker that was already reviewed", async () => {
    // Given a speaker that was previously kept unknown
    await database.execute({
      sql: "UPDATE speaker_assignments SET state = ?, reviewed_at = 1800000000 WHERE cluster_id = ?",
      args: ["unknown", clusterID],
    })

    // When a participant is confirmed for it
    const result = await client.callTool({
      name: "set_speaker_identity",
      arguments: { clusterId: clusterID, participantId: participantID },
    })

    // Then the correction is queued instead of being rejected
    expect(result.structuredContent).toMatchObject({
      request: { clusterId: clusterID, participantId: participantID, status: "pending" },
    })
  })

  test("flags two speakers that claim the same person", async () => {
    // Given one participant confirmed for a second speaker as well
    const secondClusterID = "6f2b1c84-0c2f-4c31-9f0e-8f9c1d2a3b44"
    await database.execute({
      sql: `INSERT INTO pending_speaker_clusters
        (id, call_id, speaker_index, speaker_label, model_version,
         encrypted_embedding, speech_ms, created_at, expires_at)
        VALUES (?, ?, 1, 'Speaker 2', 'model-v1', ?, 4000, 1600000000, 1700000000)`,
      args: [secondClusterID, callID, "SECOND_SENTINEL"],
    })
    await database.execute({
      sql: `INSERT INTO speaker_assignments
        (cluster_id, call_id, speaker_index, participant_id, state,
         confidence_band, updated_at, reviewed_at)
        VALUES (?, ?, 1, ?, 'confirmed', 'high', 1800000000, 1800000000)`,
      args: [secondClusterID, callID, participantID],
    })
    await database.execute({
      sql: `UPDATE speaker_assignments
        SET state = 'confirmed', reviewed_at = 1800000000 WHERE cluster_id = ?`,
      args: [clusterID],
    })

    // When the diarization report is requested
    const result = await client.callTool({
      name: "get_diarization_quality",
      arguments: { callId: callID },
    })

    // Then the duplicate identity is reported
    const report = z
      .object({ report: z.object({ warnings: z.array(z.string()) }) })
      .parse(result.structuredContent).report
    expect(report.warnings).toContain("duplicate_participants")
  })
})
