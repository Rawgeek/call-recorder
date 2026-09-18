# App Review notes — draft

These notes are ready to adapt for the submitted build. Replace bracketed fields and verify the
steps against the final signed package before pasting them into App Store Connect.

Call Recorder is a menu-bar-only macOS app, so it does not open a Dock window. After launch, use
the waveform icon in the menu bar.

No account or login is required. No special hardware is required beyond a microphone. For a full
recording test:

1. Launch Call Recorder and approve Microphone and Screen & System Audio Recording permissions.
2. Open the menu-bar panel and select Start Recording.
3. Play any non-confidential audio on the Mac and speak into the microphone.
4. Stop the recording. In Settings > Models, install a Whisper model if one is not already present.
5. Wait for local processing, then select the completed call to view/copy its transcript.

The recordings folder defaults to the app's sandboxed Application Support directory and can be
changed with the folder picker. A Whisper speech model is downloaded only after a user action. A
small voice-activity model may be prepared automatically; these are data/models, not
executable application updates. The Mac App Store build uses Apple AVFoundation for audio
processing and embeds only the pinned whisper-cli executable helper. It does not use the direct
build's GitHub application updater or runtime download. Application updates come from the App
Store.

Transcript search, Codex MCP, speaker identification, and speaker review are unavailable in this
distribution and are not required to test recording or transcription. The native transcript index
is an internal processing artifact and has no Store-facing search control.

Reviewer contact: [NAME, EMAIL, PHONE]

Review with the submitted build: [VERSION] ([BUILD]) on [MAC MODEL / macOS VERSION].
