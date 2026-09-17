# Codex MCP setup

The app ships a local MCP server. Codex uses it to search transcripts, read calls, manage
participants and vocabulary, and review speakers.

## Register

```sh
codex mcp add call-recorder -- "/Applications/Call Recorder.app/Contents/Resources/indexer/bun" "/Applications/Call Recorder.app/Contents/Resources/indexer/mcp-server.js"
codex mcp list
```

Restart Codex after adding the server. From a source checkout, point `codex mcp add` at
`bun <repo>/mcp/src/server.ts` instead.

The default database is `~/Library/Application Support/CallRecorder/calls.db`. Set
`CALL_RECORDER_DB_PATH` in the MCP configuration to use another one.

## Tools

| Tool | Purpose |
| --- | --- |
| `list_calls` | Recent calls with date, status, and participants. |
| `search_calls` | BM25, semantic, or hybrid search over transcript chunks, with filters. |
| `get_call` | One call's metadata. |
| `get_transcript` | A bounded page of transcript segments. |
| `list_participants` | Saved people with role, company, and email. |
| `upsert_participants` | Add or update people. |
| `merge_participants` | Fold a duplicate person into the one kept. |
| `list_glossary` | Vocabulary terms and alternatives. |
| `upsert_glossary_terms` | Add terms and the spellings Whisper produces. |
| `delete_glossary_terms` | Remove terms by spelling. |
| `list_speaker_reviews` | Unresolved voices with samples and suggestions. |
| `get_diarization_quality` | Coverage report for one call. |
| `set_speaker_identity` | Queue a name for a detected voice. |
| `reopen_speaker_review` | Send a decided voice back to review. |
| `assign_speaker_lines` | Move a run of lines onto a person. |
| `get_speaker_identity_request` | Check a queued speaker mapping. |
| `get_speaker_line_request` | Check a queued line assignment. |

Speaker changes are queued as requests and applied by the running app through the same path
as the UI, so any mapping can be undone. Recording controls and deletion are not exposed.

The full guide is in [docs/mcp.md](https://github.com/Rawgeek/call-recorder/blob/main/docs/mcp.md).

