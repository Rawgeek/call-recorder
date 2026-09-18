# Third-party software notice checklist

This is a release gate. The package script now embeds the pinned whisper.cpp license and the
license from the exact `libsql-swift` checkout, and records hashes for both. Confirm that these are
the complete customer-facing notices for the final linked binary, not merely the package names.

Verify and record the version/commit, source URL, license text, copyright notices, build flags,
linked libraries, architecture, SHA-256, and redistribution obligations for at least:

- whisper.cpp / whisper-cli, its linked libraries, and every downloadable Whisper model's separate
  license or terms.
- Every Swift package actually linked into the Store executable, at the revision pinned in
  `Package.resolved`, including native components where applicable.
- Apple/system frameworks and any other native code found by inspecting the final bundle.

The Store bundle must not contain ffmpeg, ffprobe, Bun, the JavaScript indexer/MCP runtime, or the
Python diarization helper. If that distribution boundary changes, update this checklist and repeat
legal review before packaging.

Do not submit until counsel or the accountable release owner has approved the final notices and
all corresponding license texts/source offers are included where required. Keep a machine-readable
software bill of materials, the verified whisper-cli and license input hashes, and the helper's
signed-byte manifest with the release record.
