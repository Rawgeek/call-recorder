# Installation

## Requirements

- Apple silicon Mac, macOS 15 (Sequoia) or newer.
- Homebrew packages: `ffmpeg`, and `python3` at version 3.10 or newer. The app uses the Python
  once to build the environment the transcription model runs in.
- Optional, for speaker labels: that same environment holding `pyannote.audio`, `librosa`, and
  transformers 5.18, plus the local speaker models.

## From a release

1. Download the latest `CallRecorder-<version>.zip` from the releases page and unzip it.
2. Move `Call Recorder.app` to `/Applications`.
3. First launch only: right-click the app and choose **Open**. The build is signed locally, not
   notarized by Apple.
4. Approve **Microphone** and **Screen & System Audio Recording**.
5. Settings -> Models: press **Set Up** beside the speech runtime, which builds the Python
   environment and fetches `mlx` and `mlx-audio`, then download **Qwen3-ASR 1.7B** (2.3 GB).
6. Settings -> General: choose the microphone and the recordings folder.
7. Settings -> Participants: add people and mark which one is you.

## From source

```sh
brew install ffmpeg python3 bun
git clone https://github.com/Rawgeek/call-recorder.git
cd call-recorder
swift build -c release
```

Create a distributable bundle with:

```sh
scripts/package-app.sh "dist/Call Recorder <version>"
```

## Speaker identification (optional)

Nemotron 3 Diarization says who spoke when and the pyannote.audio community-1 embedder measures each
voice, so both are needed.

1. Accept the licence for `pyannote/speaker-diarization-community-1` on Hugging Face and sign
   in once (`hf auth login`). Nemotron 3 Diarization is not gated.
2. ```sh
   python3 -m venv ~/pyannote-env
   ~/pyannote-env/bin/pip install pyannote.audio torch torchaudio librosa
   ~/pyannote-env/bin/pip install "transformers @ git+https://github.com/huggingface/transformers@f324707307757d9c0b8dac1c4462eceff911fa2f"
   ```
3. In the app, open Review Speakers -> Speaker setup -> Choose Python Environment and select
   `~/pyannote-env/bin/python3`, then press **Check Speaker Setup**.

Without this step the app still transcribes everything, with speakers shown as Speaker 1,
Speaker 2, and so on.
