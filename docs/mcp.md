# Codex integration (MCP)

Call Recorder ships a local [Model Context Protocol](https://modelcontextprotocol.io) server.
It lets Codex search the transcript library, read calls, manage the people and vocabulary that
improve transcription, and review speakers. Everything runs on this Mac: the server reads the
same local database the app uses, and embeddings are computed by a bundled local model.

## Register the server

Installed app:

```sh
codex mcp add call-recorder -- "/Applications/Call Recorder.app/Contents/Resources/indexer/bun" "/Applications/Call Recorder.app/Contents/Resources/indexer/mcp-server.js"
```

From a source checkout, without installing:

```sh
codex mcp add call-recorder -- bun "$PWD/mcp/src/server.ts"
```

Restart Codex after adding the server, then confirm it is connected:

```sh
codex mcp list
```

Or add it to `~/.codex/config.toml` by hand:

```toml
[mcp_servers.call-recorder]
command = "/Applications/Call Recorder.app/Contents/Resources/indexer/bun"
args = ["/Applications/Call Recorder.app/Contents/Resources/indexer/mcp-server.js"]

# Optional: point at a database other than the default.
# env = { CALL_RECORDER_DB_PATH = "/path/to/calls.db" }
```

The default database is `~/Library/Application Support/CallRecorder/calls.db`.

## The first start

The runtime that serves these tools travels as one compressed archive of about 36 MB, fetched once
and unpacked into `~/Library/Application Support/CallRecorder/runtime`, which takes a few
seconds and happens once for each app version. Every later start uses that copy, and the path
above never changes, so an existing registration keeps working.

- A failed unpack is written to `~/Library/Logs/CallRecorder/indexer-runtime.log`, and the app
  reports it under Settings > Models > Components.
- The archive is kept at `~/Library/Application Support/CallRecorder/runtime.zip`, so a runtime
  folder that is deleted or damaged is rebuilt from it without a second download.
- The app and this script both fetch the archive when it is missing, and both check it against the
  hash recorded in the app before anything is unpacked.
- To force a fresh unpack, delete the `runtime` folder. Nothing else reads it.
- `CALL_RECORDER_RUNTIME_DIR` moves the folder, which is what the test suite does.

## Tools

| Tool | Purpose |
| --- | --- |
| `list_calls` | Recent calls with date, status, participants, and whether each one has a brief. |
| `search_calls` | Search transcript chunks with BM25, semantic, or hybrid ranking. Filters: participants, date range. |
| `get_call` | One call: its participants, its transcript location, and its brief when the app has written one. The brief is the short written version of the call, so read it before the transcript. |
| `get_transcript` | A bounded page of transcript segments. |
| `list_participants` | Saved people with role, company, and email. |
| `upsert_participants` | Add or update reusable people. |
| `list_glossary` | Current vocabulary terms and their alternatives. |
| `upsert_glossary_terms` | Add terms and the spellings Whisper produces for them. |
| `delete_glossary_terms` | Remove terms by spelling, reporting which were removed and which were not found. |
| `merge_participants` | Fold a duplicate person into the one kept, moving call links and learned voices. |
| `list_speaker_reviews` | Unresolved voices with participant suggestions, transcript samples, and audio availability. |
| `get_diarization_quality` | Coverage report for one call: labelled speech, attributed speech, unresolved voices, speech per voice. |
| `set_speaker_identity` | Queue a name for a detected voice. |
| `reopen_speaker_review` | Send a decided voice back to review so a wrong name can be corrected. |
| `assign_speaker_lines` | Move a run of transcript lines onto a person, or release them back to the voice. |
| `get_speaker_identity_request` | Check whether a queued speaker mapping was applied. |
| `get_speaker_line_request` | Check whether a queued line assignment was applied. |

## How writes work

The server never records and never deletes audio or transcripts. It can write vocabulary,
participant records, and **speaker requests**:

1. A tool such as `set_speaker_identity` writes a request row and returns a request id.
2. The running app claims the request, applies it through the same path as the UI, and rewrites
   the affected transcript.
3. `get_speaker_identity_request` (or `get_speaker_line_request`) reports the outcome.

Because every speaker change goes through the app's confirmation path, a wrong mapping can be
undone with `reopen_speaker_review`. Vocabulary and participant edits take effect on the next
transcription and correction pass.

Voiceprints are never exposed: no tool returns profile data, and encrypted voice material is
not part of any response.

## Example prompts

- "Search my transcripts for the decision about the warehouse cutover in August and quote the
  lines with their call dates."
- "Which calls this week mention the vendor bill? Summarize each one."
- "Add Dmytro Lysenko, Staff Engineer, to the participants."
- "Add the term 'OpenBorders'; Whisper writes it as 'Open Border' and 'Openboarders'."
- "Show me the unresolved speakers and play me the excerpts; suggest which participant each
  voice is, and confirm the ones you are sure of."

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| `codex mcp list` does not show the server | Re-run the `codex mcp add` command with the exact quoted paths, then restart Codex. |
| Tools return "database is locked" | Close the app's Settings window, then retry. The app and the server share one local database. |
| Semantic search returns nothing | The embedding model has not been downloaded yet. Open the app once and let Models finish, or open a call so the indexer can run. Keyword (`lexical`) search works without it. |
| A speaker request stays pending | The app must be running to apply queued requests. Start Call Recorder and check again. |
