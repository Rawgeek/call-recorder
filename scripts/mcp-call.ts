#!/usr/bin/env bun
// Small stdio client for the Call Recorder MCP server. Use it to check which tools the
// installed app serves and to call one tool from a terminal.
//
//   bun scripts/mcp-call.ts list
//   bun scripts/mcp-call.ts call list_participants '{}'
//   bun scripts/mcp-call.ts --dev list        # run from mcp/src instead of the installed app

const bundledBun = "/Applications/Call Recorder.app/Contents/Resources/indexer/bun"
const bundledServer = "/Applications/Call Recorder.app/Contents/Resources/indexer/mcp-server.js"

const args = process.argv.slice(2)
const useSource = args.includes("--dev")
const rest = args.filter((arg) => arg !== "--dev")
const [command = "list", toolName, toolArguments = "{}"] = rest

const invocation = useSource
  ? [bundledBun, "run", new URL("../mcp/src/server.ts", import.meta.url).pathname]
  : [bundledBun, bundledServer]

const child = Bun.spawn(invocation, { stdin: "pipe", stdout: "pipe", stderr: "pipe" })

let nextId = 1
const send = (method: string, params: unknown): number => {
  const id = nextId++
  const message = JSON.stringify({ jsonrpc: "2.0", id, method, params })
  child.stdin.write(`${message}\n`)
  child.stdin.flush()
  return id
}

const wanted = new Set<number>()
send("initialize", {
  protocolVersion: "2025-06-18",
  capabilities: {},
  clientInfo: { name: "mcp-call", version: "1.0.0" },
})
const listId = send("tools/list", {})
wanted.add(listId)
let callId: number | undefined
if (command === "call") {
  callId = send("tools/call", { name: toolName, arguments: JSON.parse(toolArguments) })
  wanted.add(callId)
}

const decoder = new TextDecoder()
let buffer = ""
const reader = child.stdout.getReader()
const deadline = Date.now() + 60_000
while (Date.now() < deadline) {
  const { value, done } = await reader.read()
  if (done) break
  buffer += decoder.decode(value, { stream: true })
  const lines = buffer.split("\n")
  buffer = lines.pop() ?? ""
  for (const line of lines) {
    if (!line.trim()) continue
    let message: { id?: number; result?: unknown; error?: unknown }
    try {
      message = JSON.parse(line)
    } catch {
      continue
    }
    if (message.id === undefined || !wanted.has(message.id)) continue
    if (command === "list") {
      const tools = (message.result as { tools?: Array<{ name: string }> } | undefined)?.tools ?? []
      console.log(tools.map((tool) => tool.name).sort().join("\n"))
    } else if (message.id === callId) {
      console.log(JSON.stringify(message.result ?? message.error, null, 2))
    }
    wanted.delete(message.id)
  }
  if (wanted.size === 0) break
}
child.kill()
const errors = await new Response(child.stderr).text()
if (errors.trim()) console.error(errors.trim().split("\n").slice(-5).join("\n"))

