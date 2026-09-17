import { expect, test } from "bun:test"
import { mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { Client } from "@modelcontextprotocol/sdk/client/index.js"
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js"
import { openDatabase } from "../src/database.ts"
import type { QueryEmbedder } from "../src/search.ts"
import { createCallRecorderServer, SERVER_INSTRUCTIONS } from "../src/server.ts"

test("initializes the local server with the exact bounded tool set", async () => {
  const database = openDatabase(
    join(mkdtempSync(join(tmpdir(), "call-recorder-server-")), "calls.db"),
  )
  const embedder: QueryEmbedder = { modelVersion: "test:256", embedQuery: async () => [] }
  const server = createCallRecorderServer(database, embedder)
  const client = new Client({ name: "test-client", version: "1.0.0" })
  const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair()
  await server.connect(serverTransport)
  await client.connect(clientTransport)

  expect(client.getServerVersion()).toEqual({ name: "call-recorder", version: "0.2.0" })
  expect(client.getInstructions()).toBe(SERVER_INSTRUCTIONS)
  const tools = await client.listTools()
  expect(tools.tools.map(({ name }) => name)).toEqual([
    "list_calls",
    "search_calls",
    "get_call",
    "get_transcript",
    "list_participants",
    "list_glossary",
    "upsert_participants",
    "upsert_glossary_terms",
    "delete_glossary_terms",
    "merge_participants",
    "list_speaker_reviews",
    "get_diarization_quality",
    "get_speaker_identity_request",
    "set_speaker_identity",
    "reopen_speaker_review",
    "assign_speaker_lines",
    "get_speaker_line_request",
  ])
  expect(
    tools.tools
      .filter(
        ({ name }) =>
          name !== "upsert_participants" &&
          name !== "merge_participants" &&
          name !== "upsert_glossary_terms" &&
          name !== "delete_glossary_terms" &&
          name !== "set_speaker_identity" &&
          name !== "reopen_speaker_review" &&
          name !== "assign_speaker_lines",
      )
      .every(({ annotations }) => annotations?.readOnlyHint === true),
  ).toBeTrue()
  expect(
    tools.tools
      .filter(
        ({ name }) =>
          name === "upsert_participants" ||
          name === "upsert_glossary_terms" ||
          name === "delete_glossary_terms" ||
          name === "set_speaker_identity",
      )
      .every(({ annotations }) => annotations?.readOnlyHint === false),
  ).toBeTrue()
  expect(tools.tools.every(({ annotations }) => annotations?.openWorldHint === false)).toBeTrue()

  await client.close()
  await server.close()
  database.close()
})
