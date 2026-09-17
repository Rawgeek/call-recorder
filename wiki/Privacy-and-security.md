# Privacy and security

Call Recorder records private conversations, so its privacy and security properties are part of
the product.

- **Local only.** Recording, transcription, diarization, embedding, and search run on the Mac.
  The only network requests are model downloads from the configured model host.
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

