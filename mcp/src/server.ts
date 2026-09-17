import { join } from "node:path"
import type { Client } from "@libsql/client"
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js"
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js"
import {
  applicationDirectory,
  migrateSearchSchema,
  openDatabase,
  resolveDatabasePath,
} from "./database.ts"
import { embeddingModelVersion, loadEmbeddingService } from "./embedder.ts"
import type { QueryEmbedder } from "./search.ts"
import { registerSpeakerTools } from "./speaker-tools.ts"
import { registerTools } from "./tools.ts"

export const SERVER_INSTRUCTIONS =
  "Use these tools for local calls, transcripts, speaker review, and diarization quality. Data and inference stay on this Mac. Speaker mappings are applied by the signed app. Recording controls and deletion are intentionally unavailable."

export const createCallRecorderServer = (database: Client, embedder: QueryEmbedder): McpServer => {
  const server = new McpServer(
    { name: "call-recorder", version: "0.2.0" },
    { instructions: SERVER_INSTRUCTIONS },
  )
  registerTools(server, database, embedder)
  registerSpeakerTools(server, database)
  return server
}

const main = async (): Promise<void> => {
  const database = openDatabase(resolveDatabasePath())
  await migrateSearchSchema(database)
  let embeddingService: ReturnType<typeof loadEmbeddingService> | undefined
  const embedder: QueryEmbedder = {
    modelVersion: embeddingModelVersion(join(applicationDirectory(), "models", "embeddinggemma")),
    embedQuery: async (query) => {
      embeddingService ??= loadEmbeddingService(
        join(applicationDirectory(), "models", "embeddinggemma"),
        false,
      )
      return (await embeddingService).embedQuery(query)
    },
  }
  await createCallRecorderServer(database, embedder).connect(new StdioServerTransport())
}

if (import.meta.main) {
  main().catch((error: unknown) => {
    console.error(error instanceof Error ? error.message : "Call Recorder MCP failed")
    process.exitCode = 1
  })
}
