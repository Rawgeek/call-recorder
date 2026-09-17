# Security and privacy

Call Recorder handles recordings of private conversations, so its security posture is part of
the product, not an extra.

## Reporting a vulnerability

Open a private report through GitHub: **Security -> Report a vulnerability** on this
repository. Please do not open a public issue for anything that could expose recordings,
transcripts, voiceprints, or key material.

Include the version and build number (menu-bar panel -> Settings -> General), what you did,
what happened, and the smallest reproduction you have. If a report involves the MCP server,
include the tool name and arguments.

## Design guarantees

These are properties the code is built to keep. A report that shows one of them failing is a
security bug, even without data loss.

- **Local only.** Recording, transcription, diarization, embedding, and search run on the
  machine. The only network requests are model downloads from the configured model host.
- **Voiceprints are encrypted.** The voice-profile key lives in the macOS Keychain
  (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`) and the profiles never appear in
  transcripts, search results, diagnostics, or MCP output.
- **The MCP server cannot destroy work.** It exposes read tools for calls and transcripts,
  and write tools for vocabulary, participant records, and *queued* speaker requests. It
  cannot start, stop, or delete a recording, and it cannot delete a transcript.
- **Writes are confirmed by the app.** A speaker mapping requested over MCP is queued and
  applied through the same path as the UI, so it can be undone by reopening the review.
- **Diagnostics are redacted.** Error reports and the diagnostics bundle carry messages,
  contexts, and stack traces, not audio, transcript text, or participant names.
- **Deletion is announced.** Audio is moved to a 24-hour Recently Deleted area only after the
  transcript and index are verified, and the purge is reported on the surface that owns it.
