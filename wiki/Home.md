# Call Recorder

A private, local-first call recorder for macOS. It records both sides of a call, transcribes
it on the machine with Qwen3-ASR, labels who spoke, and keeps every transcript searchable by
keyword and by meaning. Codex can search and curate the library through a built-in MCP server.

**Repository:** https://github.com/Rawgeek/call-recorder
**Latest release:** https://github.com/Rawgeek/call-recorder/releases/latest

## Pages

- [[Installation]] — requirements, the prebuilt app, speaker setup.
- [[Codex MCP setup]] — register the MCP server and see the tools.
- [[Troubleshooting]] — the failures worth knowing about.
- [[Privacy and security]] — what leaves the machine (nothing) and how data is protected.

## Quick start

1. Download the latest release, unzip it, move `Call Recorder.app` to `/Applications`.
2. First launch only: right-click the app and choose **Open**.
3. Approve Microphone and Screen & System Audio Recording.
4. Open Settings -> Models: press **Set Up** beside the speech runtime, then download
   Qwen3-ASR 1.7B. A call waits for whichever half is missing.
5. Optional: open Settings -> Participants and add the people you meet with.

Requires `ffmpeg` from Homebrew and Python 3.10 or newer:

```sh
brew install ffmpeg python3
```

