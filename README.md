# Call Recorder

A private, local-first call recorder for macOS. Call Recorder records both sides of a call,
transcribes it on your Mac with Whisper, labels who spoke, and keeps every transcript
searchable by keyword and by meaning. Codex can search, read, and curate the library through a
built-in MCP server.

Audio, transcripts, voice profiles, and the search index never leave the machine.

![The menu-bar panel while recording](docs/images/menu-bar-recording.png)

## Features

**Recording**

- Records both sides of a call: the microphone and the system audio.
- Optional automatic start when another app opens the microphone, with automatic stop a couple
  of seconds after the call ends.
- Manual Start, Pause, Resume, Stop, and Discard from the menu-bar panel. The next call can
  start while an earlier one is still being processed.
- One-sided-call detection warns when the other side of the conversation was never captured.

**Transcription**

- Whisper runs locally through whisper.cpp, in roughly a hundred languages; the language is
  detected per call, so English and Russian calls need no configuration.
- Output is cleaned for reading: no timestamps, no `[music]`-style annotations, one line per
  spoken turn.
- Each call produces a Markdown transcript in the recordings folder, named by date and time.

**Speakers**

- Local diarization through pyannote.audio separates the recording into voices.
- Optional encrypted voice profiles: confirming a name teaches the voice, and later calls are
  suggested or named automatically. Voiceprints are stored in the macOS Keychain and are never
  part of transcripts, search, diagnostics, or MCP responses.
- Review Speakers shows transcript samples and playable excerpts for each unresolved voice, and
  a run of lines can be moved to a different person when one voice holds two speakers.

**Vocabulary**

- A glossary holds product names, people, and the ways Whisper mishears them. Preferred
  spellings are given to the model before transcription, and the saved text is corrected
  afterwards with the same rules.

**Library and Codex**

- Every transcript is indexed into a local Turso/libsql database with FTS5 (BM25) ranking and
  256-dimension vector embeddings from a bundled local model. Search is hybrid by default.
- The bundled MCP server exposes 17 tools for calls, transcripts, participants, glossary, and
  speaker review. See [docs/mcp.md](docs/mcp.md).

**Operations**

- Menu-bar app; there is no window to keep open.
- Models update themselves: the new file is downloaded beside the model in use, verified
  against a published SHA-256, swapped atomically, and the previous copy is kept for revert.
- Recovery tools: database check and backup, restore of working files, retry of failed calls,
  a redacted diagnostics bundle, and Copy Error Details on every failure surface.
- Audio is moved to a 24-hour "Recently Deleted" area only after the transcript and the search
  index are verified. Nothing is deleted silently.

## Screenshots

| | |
| --- | --- |
| ![The menu-bar panel while recording](docs/images/menu-bar-recording.png) | ![Recent calls in the menu-bar panel](docs/images/menu-bar-recent.png) |
| ![Participants settings](docs/images/settings-people.png) | ![Vocabulary settings](docs/images/settings-vocabulary.png) |
| ![Models settings](docs/images/settings-models.png) | ![The vocabulary editor](docs/images/glossary-editor.png) |

## Requirements

- Apple silicon Mac running macOS 15 (Sequoia) or newer.
- [Homebrew](https://brew.sh) packages: `ffmpeg` (capture and conversion) and `whisper-cpp`
  (transcription).
- Optional, for speaker labels: a local Python environment with `pyannote.audio`.

## Install

### From a release

1. Download `Call Recorder 0.1.0.zip` from the
   [latest release](https://github.com/Rawgeek/call-recorder/releases/latest) and unzip it.
2. Move `Call Recorder.app` to `/Applications`.
3. First launch only: right-click the app and choose **Open**. The build is signed locally, not
   notarized by Apple, so a double-click shows a warning. After the first open, a normal
   double-click works.
4. Approve the macOS prompts: **Microphone** and **Screen & System Audio Recording**. The
   second permission is what records the other side of the call.
5. Open the menu-bar icon and choose **Settings**:
   - **Models**: download a Whisper model. `medium` is a good default; larger models are more
     accurate and slower. Everything runs locally.
   - **General**: choose the microphone, the recordings folder (default
     `~/Desktop/Call Recordings`), and whether recording starts when another app opens the
     microphone.
   - **Participants**: add the people you meet with, and mark which one is you.
6. Leave **Start at login** on if you want it always available.

### From source

```sh
brew install ffmpeg whisper-cpp bun
git clone https://github.com/Rawgeek/call-recorder.git
cd call-recorder
swift build -c release
```

Run it directly with `swift run CallRecorder`, or build a distributable bundle:

```sh
scripts/package-app.sh "dist/Call Recorder 0.1.0"
```

Packaging needs `bun` on `PATH` (or `CALL_RECORDER_BUN`) and a code-signing identity
(`CALL_RECORDER_SIGNING_IDENTITY`, default `Call Recorder Local Development`). To package
without a certificate, use `CALL_RECORDER_SIGNING_IDENTITY=-` for an ad-hoc signature.

### Speaker identification (optional)

Whisper transcribes speech; it does not know who is speaking. pyannote.audio splits the
recording into voices, and the app learns a voice profile when you confirm a name.

1. Accept the licence for `pyannote/speaker-diarization-community-1` on Hugging Face, and sign
   in once so a token is stored locally (`hf auth login`).
2. Create a Python environment:

   ```sh
   python3 -m venv ~/pyannote-env
   ~/pyannote-env/bin/pip install pyannote.audio torch torchaudio
   ```

3. In the app: open **Review Speakers** (from the menu-bar panel, or **Settings -> Recovery ->
   Review Speakers...**), then **Speaker setup -> Choose Python Environment**, and select
   `~/pyannote-env/bin/python3`. Press **Check Speaker Setup**; the panel should report that
   the local speaker model is ready.

Without this step the app still transcribes everything, with speakers shown as Speaker 1,
Speaker 2, and so on.

## Connect Codex (MCP)

The app ships an MCP server so Codex can search transcripts, read calls, manage participants
and vocabulary, and review speakers:

```sh
codex mcp add call-recorder -- "/Applications/Call Recorder.app/Contents/Resources/indexer/bun" "/Applications/Call Recorder.app/Contents/Resources/indexer/mcp-server.js"
codex mcp list
```

Restart Codex after adding the server so it loads the tools. The full tool list, the write
model, and example prompts are in [docs/mcp.md](docs/mcp.md).

## Where your files live

| Path | Contents |
| --- | --- |
| `~/Desktop/Call Recordings` | Transcripts (`<date-time>.md`) and a small metadata file per call. The folder is configurable. |
| `~/Library/Application Support/CallRecorder/calls.db` | The local library: calls, participants, glossary, transcripts, search index. |
| `~/Library/Application Support/CallRecorder/models` | Downloaded Whisper, VAD, and embedding models. |
| `~/Library/Application Support/CallRecorder/Recently Deleted` | Working folders kept for 24 hours after a call is finished or discarded. |
| macOS Keychain | The encryption key for voice profiles. |

## Privacy

- Recording, transcription, diarization, embedding, and search all run locally.
- No account, no telemetry, and no network call other than model downloads from the model host
  you configure.
- Voice profiles are encrypted with a key in the macOS Keychain, and are excluded from
  transcripts, diagnostics, and MCP responses.
- The MCP server exposes read tools for everything, and write tools only for vocabulary,
  participant records, and queued speaker requests. It cannot start, stop, or delete a
  recording or transcript.

## How it works

```
microphone --------\
                    >-- capture -- finalize (ffmpeg) --+-- whisper.cpp -- clean -- glossary fix
system audio ------ /                                  |                      |
                                                       |                      v
                                                       |            transcript + metadata
                                                       v                      |
                                              VAD / Silero (speech)           |
                                                       |                      v
                                                       v            Turso/libsql (chunks,
                                              pyannote diarization    FTS5 + vector index)
                                                       |                      |
                                                       v                      v
                                              speaker review  <----  MCP server for Codex
```

- **Capture**: microphone and system audio are recorded as separate sources, then mixed into
  one `call.m4a` during finalization.
- **Silence**: Silero VAD marks speech regions so silence never reaches Whisper.
- **Diarization**: pyannote.audio splits speech into voices; unmatched voices wait in Review
  Speakers.
- **Indexing**: the transcript is split into chunks; each chunk gets an embedding from the
  bundled local model and a row in the FTS5 index. Search ranks with BM25, vectors, or both.
- **Cleanup**: once the transcript and the index are verified and speaker review is settled,
  the working folder moves to Recently Deleted for 24 hours and is then purged.

## Development

```sh
swift build          # debug build
swift test           # 440 Swift tests
cd mcp && bun install && bun test    # 55 MCP tests, plus: bun run typecheck
```

Render every window to PNGs without packaging, signing, or installing:

```sh
scripts/preview.sh /tmp/call-recorder-preview
```

The renderer reads the real library by default, so review pictures show real data. To render
against a throwaway library instead, set `CALL_RECORDER_PREVIEW_HOME` to an empty directory.

The repository layout:

| Path | Contents |
| --- | --- |
| `Sources/CallRecorderApp` | Menu bar, capture, processing, settings, and review surfaces. |
| `Sources/CallRecorderCore` | Database, reducer, matchers, glossary correction, transcription boundaries. |
| `mcp/` | The MCP server and the transcript indexer (TypeScript, run by bun). |
| `scripts/` | Packaging, preview rendering, layout measurement, and glossary tooling. |
| `docs/` | Install guide, MCP guide, design contract, and screenshots. |

## Troubleshooting

See [INSTALL.md](INSTALL.md#10-troubleshooting) for the common failures: missing ffmpeg, no
system audio, a stuck transcription, an unavailable speaker environment, and database
recovery. Every error surface in the app also offers **Copy Error Details**, which is the most
useful thing to include in an issue.

## Contributing

Issues and pull requests are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) first; it
describes the build, the test suites, and the checks a change is expected to pass.

## License

MIT. See [LICENSE](LICENSE).
