# Changelog

All notable changes to Call Recorder are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions use semantic
versioning.

## [0.1.2] - 2026-09-17

A size release. The app bundle is 49 MB instead of 150 MB, and what it does is unchanged.

### Added
- A sentence behind an information glyph now appears in about a fifth of a second. The app draws
  it, because the system's own tooltip took three or four seconds on an 11-point glyph, and on
  many rows never appeared at all. Every settings pane uses it.
- A model that is downloading draws a ring that fills, with the share it has reached beside it.
  The bytes are counted as they arrive, so a slow transfer can be told from a stopped one.
- Settings > General > Storage: "Remove the audio of a finished call". Turning it off keeps each
  recording's audio beside its transcript. It is on by default, which is what the app did before
  the option existed, and the audio of a finished call is still recoverable for a day.
- The microphone menu offers the system's own choice first, named for the device macOS is set to
  use today, so following the system can be chosen and checked. Naming a device still pins it.

### Changed
- The JavaScript runtime ships as one compressed archive and is unpacked into
  `~/Library/Application Support/CallRecorder/runtime` on first use. The path Codex registers,
  `Contents/Resources/indexer/bun`, is still the entry point, so an existing MCP registration
  keeps working. The archive is checked against the hash recorded when the app was built.
- The Silero VAD filter is now a download of 865 KB from `ggml-org/whisper-vad`, managed like
  every other model: hashed before install, swapped in, revertible, and listed under
  Settings > Models > Components. The app fetches it at launch, and a transcription waits for
  it rather than failing.
- The packaged dependency tree carries only the files the runtime loads. The image library the
  embedding model imports at startup is answered by a stand-in that raises if anything ever uses
  it, the unused browser and CommonJS builds of that library are gone, and the ONNX library is
  stripped of its symbols. 78 MB of dependencies became 32 MB.
- Both JavaScript entry points are minified with identifier names kept, so a stack trace in the
  log still reads as code.
- `scripts/package-app.sh` can build without the signing key: `CALL_RECORDER_SKIP_SIGNING=1`.
- The clips the speaker review plays are now the excerpt with its silence removed, cut once and
  kept, so a turn that opens with seconds of room tone is judged on the words instead. A clip
  that cannot be cut leaves the recording playing as before.

### Fixed
- The app stopped starting index jobs when the runtime became one archive: it looked for a script
  that now lives inside the archive and quietly fell back to the command line. It reads the layout
  it was packaged with and names the entry point inside the archive.
- A row holding a download pushed its Cancel button off the edge of the card. The status chip,
  the ring, the share, and the button do not fit on one line; while a download runs the row shows
  the ring, the share, and the button.
- The runtime script treated a folder it could not create as another process holding the lock,
  and waited three minutes before failing for the wrong reason. It now reports what it could not
  create.
- The database client needs `detect-libc` to choose its native binding. The pruned tree keeps
  it; without it the MCP server stopped at its first query.
- The clip cutter wrote each part-finished file as `clip.m4a.partial`, a name ffmpeg refuses to
  choose a format for, so no clip was ever cut. The file keeps the extension it will be read
  with, and two tests now cut clips from real audio.

### Verified
- 485 tests pass, including new tests for the unpacking script and for the downloaded filter.
- The packaged runtime unpacks in under a second, serves all 17 MCP tools, and re-indexes a call
  against a copy of a real library, storing 256-dimension embeddings.

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
