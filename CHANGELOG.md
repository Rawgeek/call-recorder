# Changelog

All notable changes to Call Recorder are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions use semantic
versioning.

## [0.1.1] - 2026-09-17

Security update for the MCP package. Recording, transcription, and speaker behavior is
unchanged.

### Security
- Fixed all 18 open Dependabot alerts in `mcp/` by moving the affected transitive
  dependencies to their patched releases: `hono` 4.13.8, `fast-uri` 3.1.8, `qs` 6.16.0,
  `sharp` 0.35.4, and `adm-zip` 0.6.1.
- Added dependency overrides in both the npm and pnpm sections, so a fresh install resolves
  the patched versions even though the parent packages still declare older ranges.
- Pinned the MCP dependencies to exact versions. `latest` allowed the lockfile, CI, and the
  packaged app to drift apart.

### Verified
- `pnpm audit` reports no known vulnerabilities for the locked tree.
- The indexer still runs against the cached embedding model: `sharp` 0.35.4 loads under
  `@huggingface/transformers` 4.2.0 and produces 256-dimension query and document
  embeddings offline.

## [0.1.0] - 2026-09-17

First public release.

### Recording
- Both sides of a call: microphone plus system audio, saved as separate sources and one mix.
- Optional automatic start when another app opens the microphone, and automatic stop after
  the call ends.
- Manual start, pause, resume, stop, and discard from the menu-bar panel; the next call can
  start while an earlier one is still processed.
- One-sided-call detection: a row warns when the other side was never captured.

### Transcription
- Local Whisper transcription through whisper.cpp, with per-call language detection.
- Readable output: timestamps and non-speech annotations are removed, one line per turn.
- Glossary: preferred spellings reach the model as prompt context, and saved text is
  corrected with the same rules afterwards.

### Speakers
- Local diarization through pyannote.audio, with an optional Python environment.
- Encrypted voice profiles learn a voice when a name is confirmed, then suggest or apply
  that name on later calls. Voiceprints live in the macOS Keychain.
- Review Speakers with transcript samples and playable excerpts per voice, and line-level
  reassignment when one voice holds two people.

### Library and Codex
- Local Turso/libsql database with FTS5 (BM25) and 256-dimension vector search from a bundled
  local embedding model; hybrid ranking by default.
- MCP server with 17 tools for calls, transcripts, participants, glossary, and speaker
  review. Writes are queued as requests and applied by the signed app, so every change is
  undoable.

### Operations
- Self-updating models: download beside the model in use, verify SHA-256, swap atomically,
  keep the previous copy for revert.
- Recovery: database check and backup, working-file restore, failed-call retry, redacted
  diagnostics bundle, and Copy Error Details on every failure surface.
- Audio is moved to a 24-hour Recently Deleted area only after the transcript and index are
  verified; nothing is deleted silently.
