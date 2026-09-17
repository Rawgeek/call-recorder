Call Recorder 0.1.11

Requirements
- Apple silicon Mac running macOS 15 or newer.
- Install local audio tools: brew install ffmpeg whisper-cpp

Setup
1. Move Call Recorder.app to Applications.
2. Right-click the app and choose Open on first launch. This internal build is locally signed, not Apple-notarized.
3. Allow Microphone and Screen & System Audio Recording when macOS asks.
4. Open Settings > Models and download a Whisper model. The silence filter, about 865 KB,
   downloads on its own, and transcription waits for it. The indexer runtime, about 36 MB, is
   fetched the same way and shows its own row with progress.
5. Open Settings > General and choose the microphone to record.
6. In Settings > Participants, choose the person speaking into that microphone. On a fresh
   install the app files your own voice under your macOS account name; change it there if
   you prefer another label.
7. Keep Start Call Recorder at login enabled for automatic launch.

Updates
- From this version on, Call Recorder checks its own repository at launch and every six hours.
- A newer release is downloaded and checked in the background, and installed when the app quits:
  the next time you open it, it is the new version. Nothing happens while a call is running.
- Settings > General > Updates shows the state, and keeps the version the update replaced so it
  can be put back. The log is at ~/Library/Logs/CallRecorder/app-update.log.

Queued calls process in the background, so the next recording can start immediately.
Automatic recording leaves out apps that are not calls (the voice recorder, dictation, the
system assistant), sets aside a recording shorter than 30 seconds instead of transcribing it,
stops one that reaches 180 minutes, and stops one whose tracks stay quieter than speech for ten
minutes. Settings > General turns each of those off, and a recording started by hand is outside
all four.
The same sentence reaches the model twice when chunks overlap or the microphone hears the
speakers; the repeat is removed as the call is transcribed, so a transcript holds it once.
Microphone and system audio are captured separately. Whisper transcribes each available
source locally; a missing source does not discard the other one.
The menu shows the five latest calls; select a completed call to copy its transcript.
The app fetches its own JavaScript runtime once and unpacks it into Application Support. That
takes a minute on a slow line, happens once, and the archive is kept so it never happens twice.

Speaker identification
- Remote voices remain Speaker 1, Speaker 2, etc. unless a safe match is available.
- Review Speakers is nonblocking: Likely Name is only a suggestion; Confirm enrolls that
  voice, while Keep Unknown stores no name.
- Only explicit confirmations train a profile. Automatic matches never train themselves.
- Voiceprints are AES-GCM encrypted locally with a key in macOS Keychain. They are never
  returned by MCP, diagnostics, transcript search, or logs.
- Participant editor shows No Profile, Learning, or Ready. Reset is recoverable for 24 hours.
- Unresolved speaker evidence and source audio stay local until Confirm or Keep
  Unknown, then normal recoverable cleanup runs.

Optional local speaker runtime
Speaker diarization uses pyannote.audio locally. If it is unavailable, transcription still
finishes with anonymous labels. The app checks CALL_RECORDER_PYTHON first, then:
  ~/Library/Application Support/CallRecorder/python/bin/python3
the migration development environment, and python3 on PATH.
No call audio is uploaded. Model files may need to be downloaded once after accepting the
pyannote/speaker-diarization-community-1 license and signing in to Hugging Face.

If an operation fails, copy its error details or use Settings > Recovery to retry,
check or back up the database, and export a redacted diagnostics bundle. A failure while
unpacking the runtime is written to ~/Library/Logs/CallRecorder/indexer-runtime.log, and
Settings > Models reports it under Components.

After a transcript and search index are verified, working audio moves to Recently Deleted
for 24 hours. The desktop retains the compact Markdown transcript; private normalized
metadata is retained only to support speaker corrections and reindexing.

Recordings, transcripts, glossary data, participant profiles, and multilingual search
embeddings stay on this Mac. The search indexer is included in the app.

Optional Codex MCP
After moving the app to Applications, run:
codex mcp add call-recorder -- "/Applications/Call Recorder.app/Contents/Resources/indexer/bun" "/Applications/Call Recorder.app/Contents/Resources/indexer/mcp-server.js"
Restart Codex once so it loads the 17-tool schema including speaker review,
mapping, and quality tools.
