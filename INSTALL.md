# Call Recorder 0.1.33 — install, features, and Codex MCP

Call Recorder is a local macOS menu-bar app for meetings and calls. It records both sides
of a call, transcribes them on this Mac with Qwen3-ASR, labels who spoke, and indexes every
transcript so Codex can search it later. Audio, transcripts, and voice profiles stay on
the machine. Nothing is uploaded to a cloud service.

---

## What is new in this build

- Calls are read by Qwen3-ASR 1.7B, at eight bits, on MLX. It reads Russian and English in one
  pass, including a call that mixes them, and it keeps every participant name: on a seventy-minute
  Russian call with English product names it answered 8,547 words and covered the whole recording.
- The model and the runtime it needs are one card in **Settings > Models**. The runtime is a
  Python environment the app keeps beside its models and builds from the Python already on the
  Mac, then installs `mlx` and `mlx-audio` into at pinned versions. Both halves are downloads.
- A recording is read in pieces of fifteen seconds, so a long call cannot be cut short by a token
  budget. A piece that loops instead of speaking is read again through a narrower window, and one
  that loops twice is dropped rather than written down.
- The live transcript, the running summary, the quick chat, and the post-call brief are gone, and
  with them whisper.cpp, the Silero filter, the Parakeet engine, and the brief model.
- The vocabulary is sent as a list of words the reader can weight rather than as a prompt trimmed
  to a character budget, and the Vocabulary pane says how many saved terms are sent.

The app draws its surfaces with Liquid Glass on macOS 26 and falls back to system
materials on macOS 15. No third-party design dependency is used.

---

## 1. Requirements

- Apple silicon Mac running macOS 15 (Sequoia) or newer.
- Local audio tools: brew install ffmpeg
- Python 3.10 or newer, which the app uses once to build the environment the transcription model
  runs in: brew install python3, or the installer from python.org. The app finds it in
  /opt/homebrew/bin, /usr/local/bin, or /usr/bin, and the first one that is new enough is the one
  it uses. /usr/bin/python3 on macOS is older than 3.10, so a Python has to be installed.
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
   - Models: press Set Up beside the speech runtime, then download the transcription model
     (Qwen3-ASR 1.7B, 2.3 GB). Setting the runtime up uses the Python on this Mac, makes an
     environment beside the models, and fetches the two packages the model runs on, about a
     gigabyte. Everything runs locally. A call waits for whichever half is missing, and the row
     says which one it is.
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
- A set of voices to name, when speaker detection was set up and the call held voices the app has
  not met before.

## 5. Optional: speaker identification

The transcriber turns speech into words; it does not know who is speaking. Nemotron 3 Diarization says who spoke
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

   The environment chosen here is also the one the transcription model runs in, so it needs the
   transcription packages as well. Settings > Models shows a Speech runtime row: if it says the
   modules are missing, press Install and the two pinned packages are added to this environment.
   Choosing the environment after the runtime was set up works the other way round, and the row
   says the same thing.

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
current. Settings > Models shows the state of each model, and opening the pane asks the host again.

The same tracking covers the local EmbeddingGemma model that powers meaning-based transcript
search. It is a download from Settings > Models, and search finds passages by keyword until it
arrives.

The speech runtime is tracked as well, though it is not a model file: Settings > Models reports
whether the two packages are importable and whether they are the versions this build reads with.
A package that has been replaced since reports its own versions and offers to put the pinned ones
back, because what the library answers is what a transcript is built from.

If the local embedding model changes, the vectors stored for existing transcripts are no longer
comparable with new query vectors. Search only ranks vectors produced by the model in use, and
re-indexing rebuilds them. Keyword search is unaffected throughout.


## 7. Improving transcript quality

- Vocabulary: add names and terms the transcriber mistranscribes, with the words it uses instead
  (a product name heard as a similar-sounding word, for example). Both the preferred spelling
  and the wrong ones correct the saved text, and the glossary can be edited from Codex over MCP.
  The names on the call and the terms used most are sent with the audio, up to sixty words.
- The reader detects the language per call, so Russian and English calls are both fine, including
  a call that mixes them. Naming the language in Settings > Models holds the reader to that
  language's script when two readings are close.
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
list_calls | Recent calls with date, status, participants, and whether an earlier version wrote a brief for one.
search_calls | Hybrid BM25 and semantic search over every transcript, with date and participant filters.
get_call | One call: its participants, its transcript location, and the brief an earlier version wrote, when there is one. Current versions write no brief, so read the transcript.
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

    brew install ffmpeg bun
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
| No transcript after a call | Settings -> Models: set up the speech runtime if the row asks for it, and download the transcription model if it says Not installed. Both halves are needed, and the row says which one is missing. |
| "No Python 3.10 or newer was found on this Mac" | Install Python (brew install python3, or python.org), then press Set Up again. |
| "Other versions" beside the speech runtime | A package in the environment is not the version this build reads with. Press Reinstall; the pinned versions are put back. |
| A call was read but the words stop partway | Retry the call from Settings -> Recovery. If it happens again, export diagnostics: the reader names the pieces it dropped in the log. |
| Transcript saved, speakers unnamed | Speaker detection failed or was never set up. Open Review Speakers and retry; the audio is retained until speakers are reviewed. |
| Speaker detection keeps failing | In Review Speakers, open Speaker setup -> Check Speaker Setup, and re-select the Python environment. |
| Nothing recorded from the other side | System Settings -> Privacy & Security -> Screen & System Audio Recording: enable Call Recorder, then restart the app. |
| Wrong microphone (headset instead of laptop) | Settings -> General -> Recording microphone. |
| Some transcripts are missing | Settings -> Recovery -> check database, restore working files, or retry the failed call. |
| Settings says a new version is ready, but the version did not change | The new version is installed when the app quits. Settings -> Updates -> Restart installs it now, without a manual download. |
| One person is shown as two voices, or two people as one | In Review Speakers, set the number beside "Voices detected" and press Separate again. Settings -> General -> "Separate voices by the people on the call" controls whether the app asks for that number on its own. |
| The menu-bar panel sits below the menu bar | Update to 0.1.15 or newer: the panel is placed against the row the icon is drawn in, which is right on a display whose menu bar hides itself. |
| A Mac with no microphone records the other side only | Expected on a Mac mini: Settings -> General -> "Record when there is no microphone" is on. Turn it off to refuse recordings without a microphone. |
