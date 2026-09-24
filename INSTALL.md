# Call Recorder 0.1.26 — install, features, and Codex MCP

Call Recorder is a local macOS menu-bar app for meetings and calls. It records both sides
of a call, transcribes them on this Mac with Whisper, labels who spoke, and indexes every
transcript so Codex can search it later. Audio, transcripts, and voice profiles stay on
the machine. Nothing is uploaded to a cloud service.

---

## What is new in this build

- Every finished call now comes with a brief: what the call was about, what was agreed, who owes
  what, and what is left open, written on this Mac in the language the call was held in. The
  menu-bar row copies it, and Codex can read it from the MCP server. Settings > General >
  "Write a brief" switches it off.
- The menu-bar panel sits against the menu bar on a display whose menu bar hides itself, and the
  app's own menu is no longer turned into a bar when it is opened from the menu bar.
- A call recorded before briefs existed can be written up from its row, so the calls already on
  this Mac do not have to be recorded again to get one.
- A recording starts by itself only for a real call. The app that holds the microphone
  must also play the other side for five seconds, so a voice message or a dictation
  session no longer starts one. Every decision is logged with the app's name.
- A Mac with no audio input still records the other side. ScreenCaptureKit captures the
  call's system audio on its own; Settings > General > "Record when there is no
  microphone" keeps the older refusal one switch away.
- The Screen Recording permission is read when the app starts, so the card that names it
  and opens the right settings pane appears before a call rather than after one fails.
- Speaker detection finds FFmpeg's shared libraries, and the Speaker setup check decodes a
  real one-second WAV instead of only loading the model.
- The menu-bar panel no longer opens with a strip of nothing above its content, and every
  row in Recent shows how long its call ran.
- Discarding a recording is confirmed inside the panel, where the buttons answer.

The app draws its surfaces with Liquid Glass on macOS 26 and falls back to system
materials on macOS 15. No third-party design dependency is used.

---

## 1. Requirements

- Apple silicon Mac running macOS 15 (Sequoia) or newer.
- Local audio tools: brew install ffmpeg whisper-cpp
- Optional, for speaker labels: a local Python environment with pyannote.audio (step 5).

## 2. Install the compiled app

1. Unzip CallRecorder-0.1.1.zip.
2. Move Call Recorder.app to /Applications.
3. First launch only: right-click the app and choose Open. This build is signed locally,
   not notarized by Apple, so a double-click shows a warning. After the first open, a
   normal double-click works.
4. Approve the macOS prompts: Microphone and Screen & System Audio Recording. System audio
   capture is what records the other side of the call.
5. Open the menu-bar icon -> Settings:
   - Models: download a Whisper model. medium is a good default; larger models are slower
     but more accurate. The model runs locally.
   - General: choose the recording microphone (for example MacBook Pro Microphone), the
     recordings folder (default ~/Desktop/Call Recordings), and whether recording starts
     automatically when another app opens the microphone.
   - Participants: add the people you meet with, and mark which one is you.
6. Leave Start at login on if you want it always available.

## 3. Daily use

- The menu bar shows Start Recording, or it starts on its own when the microphone goes
  live and stops a couple of seconds after the call ends.
- Pause, Resume, and Stop are in the same menu. Stop asks who took part.
- Processing runs in the background, so the next call can start immediately.
- Recent lists the last calls. Click one to copy its transcript; the folder icon opens the
  recordings directory.
- Accidental recording? Choose Discard. It goes to Recently Deleted for 24 hours.

## 4. What you get per call

- transcript.md on the Desktop: speaker-labelled text, ready to read or paste.
- A compact metadata file used for speaker corrections and re-indexing.
- A search index entry, so any Codex session can look the call up by meaning or keyword.
- Source audio stays until the transcript and index are verified, then moves to Recently
  Deleted for 24 hours and is cleaned up. Discarded calls are recoverable the same way.
  Nothing is deleted silently.
- A brief of the call, in the menu-bar row and over MCP. It is written after the transcript, so it
  appears a few seconds after a call ends.

## 5. Optional: speaker identification

Whisper transcribes speech; it does not know who is speaking. Nemotron 3 Diarization says who spoke
when, the pyannote.audio community-1 embedder turns each of those voices into the profile a name is
matched against, and the app learns that profile when you confirm a name. All of it runs on the Mac.

1. Accept the licence for pyannote/speaker-diarization-community-1 on Hugging Face and sign
   in once so a token is stored locally (hf auth login). Nemotron 3 Diarization is not gated and
   needs no licence.
2. Create a Python environment with the packages:

       python3 -m venv ~/pyannote-env
       ~/pyannote-env/bin/pip install pyannote.audio torch torchaudio librosa
       ~/pyannote-env/bin/pip install "transformers @ git+https://github.com/huggingface/transformers@f324707307757d9c0b8dac1c4462eceff911fa2f"

   The turn model is read by transformers 5.18, which is not on PyPI yet, so that revision is
   pinned. Both models are downloaded once, on first use, into the Hugging Face cache.

3. In the app: open Review Speakers (the menu-bar panel, or Settings -> Recovery ->
   Review Speakers...), then Speaker setup -> Choose Python Environment, and select
   ~/pyannote-env/bin/python3. Press Check Speaker Setup; the panel should report that
   the local speaker model is ready.

Without this step the app still transcribes everything, with speakers shown as Speaker 1,
Speaker 2, and so on.

How labeling works:

- After a call, open Review Speakers. Each detected voice is shown as a card with
  playable excerpts and transcript samples.
- Pick the person and press Confirm. That is what teaches the voice; meeting
  participants alone do not identify anyone.
- Keep Anonymous leaves the voice unlabelled and stores no profile.
- One confirmed sample enables suggestions. Two allow automatic naming when the match is
  clearly better than every alternative.
- Voice profiles are encrypted locally with a key stored in the macOS Keychain. They are
  never included in transcripts, search, diagnostics, or MCP responses.
- A person can legitimately appear as several detected voices in one call; each one can be
  confirmed against the same name.

## 6. Model updates

Call Recorder checks the model host after launch and again every few hours. A download only
starts when the host publishes a file whose hash differs from the hash of the copy on disk, so
an unchanged model is never downloaded twice.

What makes the swap safe:

- The new file is downloaded beside the model in use, then verified against the published
  SHA-256. A file that does not match is discarded and never installed.
- The working model is moved aside first and only replaced on success. If the move fails, the
  old model is put back, so the app is never left without one.
- The copy from before the update is kept, so Settings > Models offers Revert.
- Nothing is swapped while a call is being recorded or transcribed. The check waits and retries
  on the next pass.

A model installed before this feature existed has no recorded hash. Call Recorder hashes it once,
stores the result, and reports it as "not verified yet" until then rather than claiming it is
current. Settings > Models shows the state of each model and a Check Now button.

The same tracking covers the Silero VAD filter and the local EmbeddingGemma model that powers
meaning-based transcript search. Both are downloads: the filter is about 865 KB and arrives
without being asked for, and the embedding model is downloaded from Settings > Models.

If the local embedding model changes, the vectors stored for existing transcripts are no longer
comparable with new query vectors. Search only ranks vectors produced by the model in use, and
re-indexing rebuilds them. Keyword search is unaffected throughout.


## 7. Improving transcript quality

- Vocabulary: add names and terms Whisper mistranscribes, with the words it uses instead
  (a product name heard as a similar-sounding word, for example). Both the preferred spelling
  and the wrong ones are given to the model, and the glossary can be edited from Codex
  over MCP.
- Whisper supports roughly a hundred languages and detects the language per call, so
  Russian and English calls are both fine.
- Recovery: if something fails, copy the error details from the menu, or use
  Settings -> Recovery to check the database, take a backup, restore working files, retry
  a failed call, or export a redacted diagnostics bundle.

## 8. Connect Codex to the MCP server

The app ships an MCP server. Codex uses it to search transcripts, read calls, manage
participants and vocabulary, and review speakers.

Register it once:

    codex mcp add call-recorder -- "/Applications/Call Recorder.app/Contents/Resources/indexer/bun" "/Applications/Call Recorder.app/Contents/Resources/indexer/mcp-server.js"

Then restart Codex so it loads the server, and confirm it is connected:

    codex mcp list

The server reads ~/Library/Application Support/CallRecorder/calls.db by default. To point it
at another database, set CALL_RECORDER_DB_PATH in the MCP configuration.

### Tools exposed (17)

Tool | Purpose
--- | ---
list_calls | Recent calls with date, status, participants, and whether each one has a brief.
search_calls | Hybrid BM25 and semantic search over every transcript, with date and participant filters.
get_call | One call: its participants, its transcript location, and its brief when the app has written one.
get_transcript | Paged transcript segments, optionally speaker-labelled.
list_participants | People on record, with role, company, and email.
upsert_participants | Add or update people so calls can be attributed.
list_glossary | Current vocabulary entries.
upsert_glossary_terms | Add or fix terms and their common mis-hearings.
delete_glossary_terms | Remove terms by spelling, reporting which were removed and which were not found.
merge_participants | Merge a duplicate person into the one you keep, moving call links and learned voices.
list_speaker_reviews | Voices waiting for a name, with transcript samples per speaker.
get_diarization_quality | Coverage report: how much speech was labelled and matched, plus warnings.
set_speaker_identity | Queue a name for a detected voice. The signed app applies it and rewrites the transcript.
reopen_speaker_review | Send a decided voice back to review so a wrong name can be corrected.
assign_speaker_lines | Move one run of transcript lines onto a person, or release it back to the voice.
get_speaker_identity_request | Status of a speaker mapping request.
get_speaker_line_request | Status of a queued line assignment.

The full guide, with configuration and example prompts, is in docs/mcp.md.

Safety properties worth knowing:

- Search and inference run locally. The embedding model is downloaded once and used offline.
- Recording controls are not exposed over MCP, and no recording or transcript can be deleted
  through it. What can be removed is vocabulary and saved people: a glossary term, or a duplicate
  person folded into the one you keep. Neither carries audio, and neither touches a transcript's
  text.
- Encrypted voice profiles are never readable through MCP, diagnostics, or search.
- Speaker mappings are queued as requests; the app performs them through the same
  confirmation and rollback path as the UI, so a bad mapping can be undone.

## 9. Build from source

    brew install ffmpeg whisper-cpp bun
    swift build -c release          # app and core library
    cd mcp && bun install && bun test

To produce a distributable app bundle:

    scripts/package-app.sh "dist/releases/Call Recorder 0.1.2"

Packaging needs bun on PATH (or CALL_RECORDER_BUN). With no signing identity named, the bundle is
signed ad-hoc, which needs no certificate and no keychain: it is a build for this machine. Name the
identity the releases use for a build that ships, or to replace an installed app without macOS
asking for the microphone and screen-recording permissions again:

    CALL_RECORDER_SIGNING_IDENTITY="Call Recorder Local Development" scripts/package-app.sh

Layout: Sources/CallRecorderApp (menu bar, capture, processing), Sources/CallRecorderCore
(database, matching, transcription boundaries), mcp/ (MCP server and indexer), and
scripts/package-app.sh.

Verification in this build: 648 Swift tests and 56 MCP tests pass, plus TypeScript and
Biome checks.

## 10. Troubleshooting

| Symptom | Fix |
| --- | --- |
| ffmpeg and ffprobe are required | brew install ffmpeg, then restart the app. |
| No transcript after a call | Settings -> Models: confirm a Whisper model is downloaded. |
| Transcript saved, speakers unnamed | Speaker detection failed or was never set up. Open Review Speakers and retry; the audio is retained until speakers are reviewed. |
| Speaker detection keeps failing | In Review Speakers, open Speaker setup -> Check Speaker Setup, and re-select the Python environment. |
| Nothing recorded from the other side | System Settings -> Privacy & Security -> Screen & System Audio Recording: enable Call Recorder, then restart the app. |
| Wrong microphone (headset instead of laptop) | Settings -> General -> Recording microphone. |
| Some transcripts are missing | Settings -> Recovery -> check database, restore working files, or retry the failed call. |
| Settings says a new version is ready, but the version did not change | The new version is installed when the app quits. Settings -> Updates -> Restart installs it now, without a manual download. |
| One person is shown as two voices, or two people as one | In Review Speakers, set the number beside "Voices detected" and press Separate again. Settings -> General -> "Separate voices by the people on the call" controls whether the app asks for that number on its own. |
| No brief after a call | Settings -> Models: download the brief model (2.4 GB) and install llama.cpp with brew install llama.cpp. The transcript is complete either way. |
| The menu-bar panel sits below the menu bar | Update to 0.1.15 or newer: the panel is placed against the row the icon is drawn in, which is right on a display whose menu bar hides itself. |
| A Mac with no microphone records the other side only | Expected on a Mac mini: Settings -> General -> "Record when there is no microphone" is on. Turn it off to refuse recordings without a microphone. |
