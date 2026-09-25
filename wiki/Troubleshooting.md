# Troubleshooting

| Symptom | Fix |
| --- | --- |
| "ffmpeg and ffprobe are required" | `brew install ffmpeg`, then restart the app. |
| No transcript after a call | Settings -> Models: confirm the speech runtime says Ready and Qwen3-ASR 1.7B is downloaded. |
| The speech runtime offers Reinstall | The `mlx` packages on this Mac are not the versions this build reads with. Press Reinstall to put the pinned ones back. |
| Transcript saved, speakers unnamed | Speaker detection is not set up or failed. Open Review Speakers and retry; the audio is kept until speakers are reviewed. |
| Speaker detection keeps failing | Review Speakers -> Speaker setup -> Check Speaker Setup, and re-select the Python environment. |
| Nothing recorded from the other side | System Settings -> Privacy & Security -> Screen & System Audio Recording: enable Call Recorder, then restart the app. |
| A row says "One side only" | System audio was not captured for that call. Check the permission above. |
| `codex mcp list` shows no server | Re-run `codex mcp add` with the exact quoted paths, then restart Codex. |
| Tools say "database is locked" | Close the app's Settings window and retry; the app and the server share one local database. |
| Semantic search returns nothing | The embedding model has not been downloaded yet. Let Settings -> Models finish, or use lexical search. |
| Database looks damaged | Settings -> Recovery: check the database, take a backup, or restore working files. |

Every error surface in the app has **Copy Error Details**, and Settings -> Recovery can export
a redacted diagnostics bundle. Include one of them in an issue; both exclude audio, transcript
text, and voiceprints.

