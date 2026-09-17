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
import { ParticipantSchema } from "../src/repositories.ts"
import type { QueryEmbedder } from "../src/search.ts"
import { createCallRecorderServer } from "../src/server.ts"

const callID = "3eab7aee-1f8a-48b9-94ca-d720858c8ed0"
const participantID = "51d1fee8-5085-420f-a393-70b28ebcc8a0"
const glossaryID = "a1267898-76bb-4588-938f-7acb02fe8d8c"
const vector = [1, ...Array.from({ length: 255 }, () => 0)]
const embedder: QueryEmbedder = { modelVersion: "test:256", embedQuery: async () => vector }
const TermsPageSchema = z.object({
  terms: z.array(z.object({ id: z.string(), preferred: z.string(), aliases: z.array(z.string()) })),
  total: z.int().nonnegative(),
  offset: z.int().nonnegative(),
  hasMore: z.boolean(),
  nextOffset: z.int().nonnegative().nullable(),
})
const TermsResultSchema = z.object({
  terms: z.array(z.object({ id: z.string(), preferred: z.string(), aliases: z.array(z.string()) })),
})
const DeletionSchema = z.object({
  deleted: z.array(z.string()),
  missing: z.array(z.string()),
})

const fixtureDatabase = async (): Promise<DatabaseClient> => {
  const path = join(mkdtempSync(join(tmpdir(), "call-recorder-tools-")), "calls.db")
  const database = openDatabase(path)
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
    CREATE TABLE call_participants (
      call_id TEXT NOT NULL REFERENCES calls(id),
      participant_id TEXT NOT NULL REFERENCES participants(id),
      PRIMARY KEY (call_id, participant_id)
    );
    CREATE TABLE glossary_terms (
      id TEXT PRIMARY KEY, preferred TEXT NOT NULL,
      normalized_preferred TEXT NOT NULL UNIQUE, aliases_json TEXT NOT NULL
    );
    CREATE TABLE transcripts (
      call_id TEXT PRIMARY KEY REFERENCES calls(id), language TEXT NOT NULL,
      model TEXT NOT NULL, text TEXT NOT NULL, markdown_path TEXT NOT NULL, json_path TEXT NOT NULL
    );
    INSERT INTO calls VALUES ('${callID}', 1800000000, NULL, '/tmp/call.m4a', 'ready');
    INSERT INTO participants VALUES (
      '${participantID}', 'Alice', 'alice', 'Engineer', 'Globex', 'alice@globex.com'
    );
    INSERT INTO call_participants VALUES ('${callID}', '${participantID}');
    INSERT INTO glossary_terms VALUES ('${glossaryID}', 'Codex', 'codex', '["Code X"]');
    INSERT INTO transcripts VALUES (
      '${callID}', 'en', 'whisper-small', 'Project Zephyr was approved.',
      '/tmp/transcript.md', '/tmp/transcript.json'
    );
  `)
  await migrateSearchSchema(database)
  for (const [id, startMs, endMs, text] of [
    ["chunk-1", 0, 1_000, "Project Zephyr was approved."],
    ["chunk-2", 1_000, 2_000, "Alice owns the launch plan."],
  ] as const) {
    await database.execute({
      sql: `INSERT INTO transcript_chunks
        (id, call_id, start_ms, end_ms, text, content_hash, embedding, embedding_model)
        VALUES (?, ?, ?, ?, ?, ?, vector32(?), ?)`,
      args: [id, callID, startMs, endMs, text, `hash-${id}`, JSON.stringify(vector), "test"],
    })
  }
  return database
}

describe("Call Recorder MCP tools", () => {
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

  test("merges a duplicate participant into the person you keep", async () => {
    const duplicateID = "9f0f2b0f-1f5a-4a2f-9d1f-1c2b3a4d5e6f"
    const secondCallID = "7c5a5f4e-2f1b-4f2c-9f0e-000000000002"
    await database.executeMultiple(`
      CREATE TABLE participant_voice_samples (
        id TEXT PRIMARY KEY, participant_id TEXT, encrypted_embedding BLOB
      );
      CREATE TABLE speaker_assignments (
        cluster_id TEXT PRIMARY KEY, participant_id TEXT
      );
      INSERT INTO calls VALUES ('${secondCallID}', 1800000001, NULL, NULL, 'ready');
      INSERT INTO participants VALUES (
        '${duplicateID}', 'Evan Novak', 'evan novak', NULL, NULL, 'alice@globex.com'
      );
      INSERT INTO call_participants VALUES ('${callID}', '${duplicateID}');
      INSERT INTO call_participants VALUES ('${secondCallID}', '${duplicateID}');
      INSERT INTO participant_voice_samples VALUES ('sample-1', '${duplicateID}', 'encrypted');
      INSERT INTO speaker_assignments VALUES ('cluster-1', '${duplicateID}');
    `)

    const result = await client.callTool({
      name: "merge_participants",
      arguments: { duplicateId: duplicateID, keepId: participantID },
    })

    expect(result.structuredContent).toMatchObject({
      participant: { id: participantID, name: "Alice", email: "alice@globex.com" },
      movedCalls: 1,
      movedVoiceSamples: 1,
    })
    const participants = await database.execute("SELECT id FROM participants")
    expect(participants.rows.map((row) => row[0])).toEqual([participantID])
    const links = await database.execute("SELECT call_id FROM call_participants ORDER BY call_id")
    expect(links.rows.map((row) => row[0]).sort()).toEqual([callID, secondCallID].sort())
    const samples = await database.execute("SELECT participant_id FROM participant_voice_samples")
    expect(samples.rows[0]?.[0]).toBe(participantID)
    const assignments = await database.execute("SELECT participant_id FROM speaker_assignments")
    expect(assignments.rows[0]?.[0]).toBe(participantID)
  })

  test("returns bounded call, search, participant, and glossary records", async () => {
    const calls = await client.callTool({ name: "list_calls", arguments: { limit: 50 } })
    expect(calls.structuredContent).toEqual({
      total: 1,
      offset: 0,
      hasMore: false,
      nextOffset: null,
      calls: [
        {
          id: callID,
          startedAt: "2027-01-15T08:00:00.000Z",
          endedAt: null,
          status: "ready",
          participants: [
            {
              id: participantID,
              name: "Alice",
              role: "Engineer",
              company: "Globex",
              email: "alice@globex.com",
            },
          ],
        },
      ],
    })

    const call = await client.callTool({ name: "get_call", arguments: { callId: callID } })
    expect(call.structuredContent).toEqual({
      call: {
        id: callID,
        startedAt: "2027-01-15T08:00:00.000Z",
        endedAt: null,
        status: "ready",
        audioPath: "/tmp/call.m4a",
        audioAvailable: false,
        participants: [
          {
            id: participantID,
            name: "Alice",
            role: "Engineer",
            company: "Globex",
            email: "alice@globex.com",
          },
        ],
        transcript: {
          language: "en",
          model: "whisper-small",
          markdownPath: "/tmp/transcript.md",
          jsonPath: "/tmp/transcript.json",
          hasSpeech: true,
        },
      },
    })

    const search = await client.callTool({
      name: "search_calls",
      arguments: { query: "Zephyr", mode: "lexical", limit: 1 },
    })
    expect(search.structuredContent).toEqual({
      results: [
        {
          chunkId: "chunk-1",
          callId: callID,
          startMs: 0,
          endMs: 1_000,
          text: "Project Zephyr was approved.",
        },
      ],
    })

    const participants = await client.callTool({
      name: "list_participants",
      arguments: { limit: 50 },
    })
    expect(participants.structuredContent).toEqual({
      total: 1,
      offset: 0,
      hasMore: false,
      nextOffset: null,
      participants: [
        {
          id: participantID,
          name: "Alice",
          role: "Engineer",
          company: "Globex",
          email: "alice@globex.com",
        },
      ],
    })
    const glossary = await client.callTool({ name: "list_glossary", arguments: { limit: 50 } })
    expect(glossary.structuredContent).toEqual({
      total: 1,
      offset: 0,
      hasMore: false,
      nextOffset: null,
      terms: [{ id: glossaryID, preferred: "Codex", aliases: ["Code X"] }],
    })
  })

  test("says whether a call still has audio, and whether its transcript holds speech", async () => {
    // The recoverable store sits beside the database the server was told to read, so the test
    // points that setting at a folder it owns. Without it the lookup would fall back to the real
    // application folder and the test would depend on this Mac's own recordings.
    const storeRoot = mkdtempSync(join(tmpdir(), "call-recorder-store-"))
    // Destructuring and Object.assign rather than member access: the compiler forbids dot access
    // on the environment's index signature and the linter forbids the bracket form, so neither
    // spelling of one key is available. Both tools accept these two.
    const { CALL_RECORDER_DB_PATH: previous } = process.env
    Object.assign(process.env, { CALL_RECORDER_DB_PATH: join(storeRoot, "calls.db") })
    try {
      const purged = "7c5a5f4e-2f1b-4f2c-9f0e-000000000010"
      const kept = "7c5a5f4e-2f1b-4f2c-9f0e-000000000011"
      const silent = "7c5a5f4e-2f1b-4f2c-9f0e-000000000012"
      await database.executeMultiple(`
        INSERT INTO calls VALUES ('${purged}', 1800000002, 1800000100, '/tmp/gone/call.m4a', 'ready');
        INSERT INTO calls VALUES ('${kept}', 1800000003, 1800000100, NULL, 'ready');
        INSERT INTO calls VALUES ('${silent}', 1800000004, 1800000100, NULL, 'ready');
        INSERT INTO transcripts VALUES (
          '${silent}', 'en', 'whisper-small', '   ', '/tmp/silent.md', '/tmp/silent.json'
        );
      `)
      // The app moves a finished recording into the recoverable store before its working folder
      // is removed. That audio is still there and still playable, and the server has to say so.
      const payload = join(storeRoot, "Recently Deleted", kept, "payload")
      mkdirSync(payload, { recursive: true })
      writeFileSync(join(payload, "call.m4a"), "audio")

      const read = async (id: string) =>
        z
          .object({
            call: z.object({
              audioPath: z.string().nullable(),
              audioAvailable: z.boolean(),
              transcript: z.object({ hasSpeech: z.boolean() }).nullable(),
            }),
          })
          .parse(
            (await client.callTool({ name: "get_call", arguments: { callId: id } }))
              .structuredContent,
          ).call

      const gone = await read(purged)
      expect(gone.audioPath).toBe("/tmp/gone/call.m4a")
      expect(gone.audioAvailable).toBe(false)

      const recoverable = await read(kept)
      expect(recoverable.audioAvailable).toBe(true)

      const noSpeech = await read(silent)
      expect(noSpeech.transcript?.hasSpeech).toBe(false)
    } finally {
      if (previous === undefined) {
        Object.assign(process.env, { CALL_RECORDER_DB_PATH: previous })
      } else {
        Object.assign(process.env, { CALL_RECORDER_DB_PATH: previous })
      }
    }
  })

  test("paginates transcript segments with a stable cursor", async () => {
    const first = await client.callTool({
      name: "get_transcript",
      arguments: { callId: callID, maxSegments: 1 },
    })
    expect(first.structuredContent).toEqual({
      transcript: {
        callId: callID,
        language: "en",
        model: "whisper-small",
        segments: [
          { id: "chunk-1", startMs: 0, endMs: 1_000, text: "Project Zephyr was approved." },
        ],
        nextCursor: "chunk-1",
      },
    })
    const second = await client.callTool({
      name: "get_transcript",
      arguments: { callId: callID, cursor: "chunk-1", maxSegments: 1 },
    })
    expect(second.structuredContent).toMatchObject({
      transcript: { segments: [{ id: "chunk-2" }], nextCursor: null },
    })
  })

  test("upserts normalized participants and glossary terms with stable IDs", async () => {
    const firstParticipant = await client.callTool({
      name: "upsert_participants",
      arguments: { names: [" Bob  Jones ", "bob jones"] },
    })
    const secondParticipant = await client.callTool({
      name: "upsert_participants",
      arguments: { names: ["Bob Jones"] },
    })
    expect(firstParticipant.structuredContent).toEqual(secondParticipant.structuredContent)
    const participantResult = z
      .object({ participants: z.array(ParticipantSchema) })
      .parse(firstParticipant.structuredContent)
    expect(firstParticipant.structuredContent).toMatchObject({
      participants: [{ id: expect.any(String), name: "Bob Jones" }],
    })
    expect(participantResult.participants[0]?.id).toBe(
      participantResult.participants[0]?.id.toUpperCase(),
    )

    const enrichedParticipant = await client.callTool({
      name: "upsert_participants",
      arguments: {
        participants: [
          {
            id: participantResult.participants[0]?.id,
            name: "Bob Jones",
            role: "Product Manager",
            company: "Globex",
            email: "bob@globex.com",
          },
        ],
      },
    })
    expect(enrichedParticipant.structuredContent).toMatchObject({
      participants: [
        {
          id: participantResult.participants[0]?.id,
          name: "Bob Jones",
          role: "Product Manager",
          company: "Globex",
          email: "bob@globex.com",
        },
      ],
    })

    const firstTerm = await client.callTool({
      name: "upsert_glossary_terms",
      arguments: { terms: [{ preferred: "Call Recorder", aliases: ["Call Wrecker"] }] },
    })
    const secondTerm = await client.callTool({
      name: "upsert_glossary_terms",
      arguments: { terms: [{ preferred: "call recorder", aliases: ["Recorder"] }] },
    })
    const firstTerms = TermsResultSchema.parse(firstTerm.structuredContent)
    expect(firstTerms.terms[0]?.id).toBe(firstTerms.terms[0]?.id.toUpperCase())
    expect(secondTerm.structuredContent).toMatchObject({
      terms: [{ id: firstTerms.terms[0]?.id, aliases: ["Recorder"] }],
    })
  })

  test("a duplicate glossary term can be removed and the removal is reported", async () => {
    // Two preferred spellings for one person is the case that motivated the tool: both entries
    // listed each other as an alias, so a correction could rewrite a name in either direction and
    // only the Vocabulary pane could end it. The reply names what went and what was never there,
    // because "nothing was deleted" and "nothing needed deleting" must not read the same.
    await client.callTool({
      name: "upsert_glossary_terms",
      arguments: {
        terms: [
          { preferred: "Priya", aliases: ["Priya Singh"] },
          { preferred: "Priya Singh", aliases: ["Priya"] },
        ],
      },
    })

    const removed = DeletionSchema.parse(
      (
        await client.callTool({
          name: "delete_glossary_terms",
          arguments: { terms: ["priya", "Not A Term"] },
        })
      ).structuredContent,
    )
    // Matching is case-insensitive, and the reply echoes the spelling the caller used.
    expect(removed).toEqual({ deleted: ["priya"], missing: ["Not A Term"] })

    const remaining = TermsResultSchema.parse(
      (
        await client.callTool({
          name: "list_glossary",
          arguments: { limit: 50 },
        })
      ).structuredContent,
    )
    const spellings = remaining.terms.map(({ preferred }) => preferred)
    expect(spellings).toContain("Priya Singh")
    expect(spellings).not.toContain("Priya")

    // Deleting the same term twice is not an error; the second call reports it as absent.
    const again = DeletionSchema.parse(
      (
        await client.callTool({
          name: "delete_glossary_terms",
          arguments: { terms: ["Priya"] },
        })
      ).structuredContent,
    )
    expect(again).toEqual({ deleted: [], missing: ["Priya"] })
  })

  test("a page reports the true total so a truncated list cannot read as complete", async () => {
    // The glossary is the case that broke: a real library holds more terms than the old cap
    // allowed, so a caller asking for all of them silently received a prefix of the alphabet
    // and an agent could answer "no such term" from a list that never reached that letter.
    await database.executeMultiple(
      Array.from({ length: 60 }, (_, index) => {
        const suffix = String(index).padStart(2, "0")
        // A stable, well-formed id per row; the reader validates ids as UUIDs.
        const id = `00000000-0000-4000-8000-0000000000${suffix}`
        return `INSERT INTO glossary_terms (id, preferred, normalized_preferred, aliases_json)
           VALUES ('${id}', 'Term${suffix}', 'term${suffix}', '[]');`
      }).join("\n"),
    )

    const first = TermsPageSchema.parse(
      (await client.callTool({ name: "list_glossary", arguments: { limit: 20 } }))
        .structuredContent,
    )
    expect(first.total).toBe(61)
    expect(first.terms).toHaveLength(20)
    expect(first.hasMore).toBe(true)
    expect(first.nextOffset).toBe(20)

    // Walking the offsets reaches every term, which the old fixed cap made impossible.
    const seen = new Set(first.terms.map((term) => term.preferred))
    let offset = first.nextOffset
    while (offset !== null) {
      const page = TermsPageSchema.parse(
        (await client.callTool({ name: "list_glossary", arguments: { limit: 500, offset } }))
          .structuredContent,
      )
      for (const term of page.terms) seen.add(term.preferred)
      offset = page.nextOffset
    }
    expect(seen.size).toBe(61)
    expect(seen.has("Term59")).toBe(true)
  })

  test("accepts a limit large enough for the whole glossary", async () => {
    // 51 used to be a validation error, so the cap itself, not the caller, decided how much
    // of the library was reachable.
    const all = TermsPageSchema.parse(
      (await client.callTool({ name: "list_glossary", arguments: { limit: 500 } }))
        .structuredContent,
    )
    expect(all.terms).toHaveLength(1)
    expect(all.hasMore).toBe(false)
    expect(all.nextOffset).toBeNull()
  })

  test("rejects over-broad input and reports missing records", async () => {
    const invalid = await client.callTool({ name: "list_calls", arguments: { limit: 501 } })
    expect(invalid).toMatchObject({ isError: true })
    const missing = await client.callTool({
      name: "get_call",
      arguments: { callId: "a9fc46c5-532f-41bb-af40-82c53423184e" },
    })
    expect(missing).toMatchObject({ isError: true })
  })

  test("never exposes voice identity tables or encrypted biometric values", async () => {
    const sentinel = "VOICEPRINT_SENTINEL_MUST_NOT_LEAVE_DATABASE"
    await database.executeMultiple(`
      CREATE TABLE participant_voice_samples (
        id TEXT PRIMARY KEY, participant_id TEXT, encrypted_embedding BLOB
      );
      CREATE TABLE pending_speaker_clusters (
        id TEXT PRIMARY KEY, call_id TEXT, encrypted_embedding BLOB
      );
      CREATE TABLE speaker_assignments (
        cluster_id TEXT PRIMARY KEY, participant_id TEXT
      );
      INSERT INTO participant_voice_samples VALUES ('sample', '${participantID}', '${sentinel}');
      INSERT INTO pending_speaker_clusters VALUES ('cluster', '${callID}', '${sentinel}');
      INSERT INTO speaker_assignments VALUES ('cluster', '${participantID}');
    `)

    const responses = await Promise.all([
      client.callTool({ name: "list_calls", arguments: { limit: 10 } }),
      client.callTool({ name: "get_call", arguments: { callId: callID } }),
      client.callTool({ name: "get_transcript", arguments: { callId: callID, maxSegments: 10 } }),
      client.callTool({ name: "list_participants", arguments: { limit: 10 } }),
      client.callTool({ name: "list_glossary", arguments: { limit: 10 } }),
    ])
    const serialized = JSON.stringify(responses)
    for (const forbidden of [
      sentinel,
      "participant_voice_samples",
      "pending_speaker_clusters",
      "speaker_assignments",
      "embedding-key-v1",
    ] as const) {
      expect(serialized).not.toContain(forbidden)
    }
  })
})
