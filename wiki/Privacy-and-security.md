# Privacy and security

Call Recorder records private conversations, so its privacy and security properties are part of
the product.

- **Local processing.** Recording and transcription run on the Mac. In the direct-download build,
  diarization, embedding, and transcript search also run locally; that build contacts GitHub for
  update checks, app updates, and its signed indexer-runtime archive. The Mac App Store build has
  no JavaScript indexer/MCP runtime or user-facing transcript search. It keeps only a native
  internal transcript index, receives application updates through the App Store, and contacts
  configured model hosts for requested speech models and supporting data models, such as the VAD
  model that may be prepared automatically.
- **Voiceprints are encrypted.** The key lives in the macOS Keychain; profiles never appear in
  transcripts, search results, diagnostics, or MCP output.
- **The MCP server cannot destroy work.** It exposes read tools for calls and transcripts and
  write tools for vocabulary, people, and queued speaker requests. It cannot start, stop, or
  delete a recording, and cannot delete a transcript.
- **Speaker writes are confirmed by the app.** A mapping requested over MCP goes through the
  same path as the UI, and can be undone by reopening the review.
- **Diagnostics are redacted.** Reports carry messages, contexts, and stack traces, not audio,
  transcript text, or participant names.
- **Deletion is announced.** Audio moves to a 24-hour Recently Deleted area only after the
  transcript and index are verified, and the purge is reported on the surface that owns it.

To report a vulnerability, use GitHub's private vulnerability reporting on the repository
(Security -> Report a vulnerability).
