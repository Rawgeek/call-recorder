# Changelog

All notable changes to Call Recorder are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions use semantic
versioning.

## [0.1.10] - 2026-09-18

A correction to 0.1.9. The strip above the panel's content was still there, because the fit added
in that release never reached the window it was written for.

### Fixed
- The menu bar panel is put back under the menu bar every time the system moves or resizes it. The
  0.1.9 fit looked for a borderless window, and the panel is not one: the system gives it a title
  bar that is never drawn, so the rule that was meant to leave a person's own windows alone skipped
  the panel as well. The panel is now found from the inside. The popover's content reports the
  window it is drawn in, and that window is the one that is fitted. The fit also runs after every
  move and resize, because the system keeps the corner it placed and grows the window from there;
  that is what slides the top edge down the screen and leaves the desktop showing above the content
  as the popover changes height.
- The panel no longer keeps the app in the Dock. Promotion to a regular app counts titled windows,
  and the panel carries a title bar, so an open popover used to put a Dock icon and a menu bar on
  screen. The panel is named and excluded.

### Verified
- 594 tests pass. Five of them are new: the titled panel is placed under the menu bar, a resize of
  the panel is corrected, the sweep fits the panel and leaves a titled window that is not the panel
  alone, a panel shorter than its content is placed but never grown, and the panel is not counted
  when the app decides whether it stays a menu bar app. Each of the first four was run against the
  code without the fix, where it fails for the reason it was written for.

## [0.1.9] - 2026-09-18

A reading release. Every row in the recent list says how long its call ran, and the panel no
longer opens with a strip of nothing above its content.

### Added
- Each row in the recent list carries the length of its call as a clock: `1:04:22`. All three
  fields are always drawn, so a column of lengths can be read against the next one at a glance,
  and the digits are fixed-width so the column lines up. A call that has not ended — one still
  being recorded, or one whose end was never written — says nothing rather than showing a length
  it does not have.

### Fixed
- The menu bar panel no longer opens with a transparent strip above its content. SwiftUI sizes the
  panel window from the surface inside it, and that size only ever grows: a list that loses rows,
  or a card that is sent away, leaves the window at the tallest height the surface has had. The
  leftover strip sits above the content, nothing is drawn in it, and the desktop shows through it,
  which reads as a stray transparent header. The window is now given the height of what it holds,
  and its top edge is put against the menu bar, every time the panel comes on screen.

### Verified
- 590 tests pass. Six of them are new: four pin the panel's height and position, and two pin the
  length a row shows and the length it refuses to show.
- The invented library the published pictures are drawn from now carries three different call
  lengths, so the row's new field is visible in the documentation and not only in a test.

## [0.1.8] - 2026-09-17

A settings release. A version that is waiting installs when you ask for it, the check runs on a
step you choose, and a model you picked from the folded list stays in sight.

### Added
- The Updates card installs a waiting version at a press. A downloaded and checked version used to
  wait for the app to quit, which is the one moment the bundle is idle. Restart starts a small
  shell that waits for this process to end and then opens the app, and quits: the swap runs in the
  quit, as it always did, and the next launch is the new version. A restart during a call is
  refused, because the audio of a call still being captured has not been finished into a file that
  anything could put back. When that shell cannot be started at all, nothing quits and the row says
  what to do instead.
- Check for updates chooses how often the app looks for a release while it stays open: every 30
  minutes, every hour, every 2, 6, or 12 hours, or once a day. The app shipped with one step, six
  hours, and a settings file written before the choice existed lands on it. Changing the step ends
  the wait that is already running, so choosing half an hour does not mean waiting out the twelve
  hours the app was told before.
- A model chosen from the folded list is shown with the rows above it. Its row is where the file's
  state and its Delete control live, and a choice that can only be found by unfolding twenty-nine
  rows reads as though it had been forgotten.

### Changed
- A check that finds a release already waiting no longer fetches it again. The check repeats every
  few hours, and each one repeated the whole download, the unpack, and every check over the copy
  that was already waiting.

### Verified
- 584 tests pass. Eleven of them are new: the waiting shell and its log line, the restart that
  quits and the one that must not, the six steps and what an unreadable step costs, the check a
  changed step must not cut short, the wait a changed step ends, and the model the models page
  keeps showing.
- The Updates card was rendered in the waiting state before it was published, which is what caught
  a Restart button drawn as "Rest…" beside a wrapping sentence.

## [0.1.7] - 2026-09-17

A quiet release. Automatic recording stops when the room goes silent, and a diarization failure
reports the fault it actually met.

### Added
- Automatic recording stops after ten minutes without speech. A meeting that ends can leave its
  app holding the microphone, and the recorder then holds an empty room until the ceiling, hours
  later. The capture measures both sources, and speech is counted at -50 dBFS: the room tone of
  the recordings in the library sits at -66 to -53 dBFS and speech reaches -42 and above. The rail
  has the same switch as the other three, it applies only to a recording the app started by itself,
  and it fails open. A meter that has read nothing, or a buffer whose format it does not
  understand, is not evidence of silence: the rail does nothing rather than stop a call it cannot
  hear.

### Fixed
- A diarization run that failed for a real reason could be reported as an empty output. The
  script's standard output arrived through a pipe read by a thread on the utility queue, and the
  parent waited five seconds after the script had exited for that reader to finish; on a busy
  machine the reader could still be waiting to be scheduled, and the error it was carrying was
  replaced by one that names the wrong fault. Both streams now go to files, as they do for every
  other command the app runs.

### Verified
- 573 tests pass. Seven of the new ones cover the level measure and the meter, including the two
  cases where the meter must refuse to answer.
- The threshold was measured before it was chosen: every 20 ms window of the microphone and system
  track of the four recordings still on this Mac, reported as a peak level.

## [0.1.6] - 2026-09-17

An accuracy release. A transcript holds each sentence once, and automatic recording stays inside
limits it was missing.

### Added
- Repeated speech is removed from a transcript, while a call is transcribed and over the saved
  library. Transcription runs in five-minute chunks that overlap, and a microphone also hears the
  speakers, so the same sentence reaches the model twice and both copies are written down: one call
  in the library held 473 repeated runs, and 17.2% of the words across four calls were said twice.
  A repeat is removed only when it is the same words, five or more of them, and the first copy is
  the one that stays, so a word the model heard differently is never chosen between. The repair
  that runs when the cleaning rules move applies the rule to the saved library as well, and
  Settings > Recovery reports the words it took out.
- Settings > General > Automatic recording: three backstops for the recordings the app starts by
  itself. The voice recorder, dictation, the system assistant, and the services behind them, which
  are matched by bundle-identifier prefix, no longer start a recording. A recording shorter than
  the floor, 30 seconds by default, is moved to Recently Deleted instead of being transcribed. A
  recording that reaches the ceiling, 180 minutes by default, is stopped and kept. Each of the
  three has its own switch. A switch and the number beside it are one setting rather than two, so
  they cannot disagree about whether the rail is on: switching a limit off leaves no limit, and
  switching it back on starts from the standard. A recording started by hand is outside all three.
- `docs/pitfalls.md`: the traps this app has already paid for, each with the rule it bought.

### Changed
- The transcript cleaning rules are at version five, so the saved library is repaired once on the
  next launch. The repair copies what it rewrites into the Backups folder first, as it does for a
  glossary repair.

### Verified
- 561 tests pass, 28 of them new: 12 over the repeat rule and 16 over the rails, including the
  cases where a rule has to stay out of the way.
- The repeat rule was measured on four recorded calls before it was written: 174 runs, 1 358 words
  of 7 917, which is 17.2% of the library, and the count is the same whether a copy sits 50 words
  away or 400.

### Fixed
- The transcript a call is saved from, the JSON the search index is built from, and the markdown a
  person reads are cleaned in one pass, so the three cannot disagree about what was said.

## [0.1.5] - 2026-09-17

The first release the app installs by itself, and the one that stops an update from fetching the
runtime again.

### Changed
- The runtime archive is built deterministically: file times are flattened and the entries are
  written in sorted order. Every earlier release produced an archive with a new hash even when
  nothing about the runtime had changed, so the first launch after an update fetched and unpacked
  all 36 MB again. One tree now always produces the same bytes, so an update that does not touch
  the runtime reuses the copy already unpacked beside the app.
- The package script unpacks the archive it built and refuses one whose `bun` did not come out
  executable, which is the part a sorted archive has to get right.

## [0.1.4] - 2026-09-17

An updates release. Call Recorder keeps itself current with the releases of its own repository,
and installs one when it quits.

### Added
- The app follows `Rawgeek/call-recorder` at launch and every six hours. A newer release is
  downloaded, compared with the digest the release published, and unpacked beside the app, where
  the bundle inside it is checked again: identifier, version, a valid signature, and the same
  signer as the copy that is running. Nothing is swapped while the app is in use.
- The swap happens as the app quits, which is the one moment the bundle is idle, so the next
  launch is the new version and no call is interrupted. The version that was working is kept in
  Application Support, and Settings > General > Updates can put it back the same way.
- Settings > General > Updates shows the version, the automatic option, a check now, download
  progress, and whatever is waiting. A version the user went back from is still offered, and is
  never installed by itself again.
- Every step is written to `~/Library/Logs/CallRecorder/app-update.log`, including the path of
  the copy that was kept.
- A swap interrupted between its two renames is repaired at the next launch, and a copy left
  behind by an earlier run is removed rather than trusted.

## [0.1.3] - 2026-09-17

A size release. The app bundle is 10 MB instead of 49 MB, and every Whisper model the model host
publishes can now be installed.

### Changed
- The JavaScript runtime travels as a release asset instead of inside the app. It was 36 MB of the
  49 MB bundle. The app fetches it once, with the same byte-counted downloader the models use, and
  Settings > Models shows it as a row with its own progress, Retry, and state. The archive is kept
  in Application Support, so a Mac that has fetched it once can rebuild the runtime with no
  network, and the runtime folder itself is 95 MB unpacked either way.
- Codex can start the MCP server with no app running, so the script at the registered path fetches
  the archive itself when it has to. Both paths write the same file, and the hash in the bundle
  decides whether what arrived is accepted. The registered path is unchanged.
- The app binary is stripped of the symbol table nothing reads: 13.1 MB to 8.5 MB.
- `scripts/package-app.sh` builds the small app by default and writes the runtime archive beside
  it as a release asset. `CALL_RECORDER_EMBED_RUNTIME=1` builds the self-contained app instead,
  which needs no network.

### Added
- Every model file the host publishes is in the catalog: 33 files instead of 11. Large v1 was
  missing, and so were the 21 quantized files. Quantization matters where memory is tight: a
  five-bit Large v3 Turbo is 574 MB and about 1.3 GB of working set, against 1.6 GB and 2.3 GB for
  the full file.
- Quantized rows carry no word error rate of their own. The published figures belong to the full
  files, so repeating them beside a smaller file would claim an accuracy it does not have; the row
  says what it trades instead.
- The catalog was checked against the host: every file's byte count and SHA-256 match, the pin
  names the host's current revision, and the list is exactly the host's own file list.

### Verified
- The app fetches the runtime, verifies it, unpacks it, and indexes a call through it with the
  app's own entry point.

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
