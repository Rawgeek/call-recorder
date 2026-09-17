# Installation

## Requirements

- Apple silicon Mac, macOS 15 (Sequoia) or newer.
- Homebrew packages: `ffmpeg` and `whisper-cpp`.
- Optional, for speaker labels: a local Python environment with `pyannote.audio`.

## From a release

1. Download `CallRecorder-0.1.1.zip` from the releases page and unzip it.
2. Move `Call Recorder.app` to `/Applications`.
3. First launch only: right-click the app and choose **Open**. The build is signed locally, not
   notarized by Apple.
4. Approve **Microphone** and **Screen & System Audio Recording**.
5. Settings -> Models: download a Whisper model (`medium` is a good default).
6. Settings -> General: choose the microphone and the recordings folder.
7. Settings -> Participants: add people and mark which one is you.

## From source

```sh
brew install ffmpeg whisper-cpp bun
git clone https://github.com/Rawgeek/call-recorder.git
cd call-recorder
swift build -c release
```

Create a distributable bundle with:

```sh
scripts/package-app.sh "dist/Call Recorder 0.1.1"
```

## Speaker identification (optional)

1. Accept the licence for `pyannote/speaker-diarization-community-1` on Hugging Face and sign
   in once (`hf auth login`).
2. ```sh
   python3 -m venv ~/pyannote-env
   ~/pyannote-env/bin/pip install pyannote.audio torch torchaudio
   ```
3. In the app, open Review Speakers -> Speaker setup -> Choose Python Environment and select
   `~/pyannote-env/bin/python3`, then press **Check Speaker Setup**.

Without this step the app still transcribes everything, with speakers shown as Speaker 1,
Speaker 2, and so on.
