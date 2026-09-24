#!/usr/bin/env -S .venv/bin/python3
"""Speaker diarization: Nemotron 3 names the turns, the pyannote embedder names the voices.

The turns come from NVIDIA Nemotron 3 Diarization, which answers eight channels of speech ordered
by first arrival. The 256-value centroids this app keeps as voice prints come from the pyannote
community-1 embedder, measured over the turns the other model found: the turn model has no
embedding head, and a voice print has to stay comparable with the ones already stored.

Measured on this Mac, on the system track of recorded calls (16 kHz mono, on the GPU):
  * a ten-minute two-voice call: 7.4 s here against 53 s of pyannote, and the ten-minute call with
    many voices: 2.8 s against 51 s.
  * a system track that was written and held no sound: no voice at all, against one voice pyannote
    invented and could not measure, which stopped that call at this stage six times over four days.

Requires: a Python environment holding torch, pyannote.audio, transformers 5.18 or newer (with
librosa), and both models in the local Hugging Face cache.

Usage:
  .venv/bin/python3 diarize.py audio.wav
  .venv/bin/python3 diarize.py audio.wav --num-speakers N
  .venv/bin/python3 diarize.py --check
  .venv/bin/python3 diarize.py --self-check
  Outputs diarization turns and speaker centroids as JSON to stdout.

A count is answered exactly by the pyannote separation, which is the slower of the two; a call with
no count is separated by the turn model, which counts the voices it hears.
"""

from __future__ import annotations

import json
import math
import os
import sys
from pathlib import Path
from typing import Final, TypedDict

os.environ["PYANNOTE_METRICS_ENABLED"] = "false"
os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"
os.environ["HF_HUB_OFFLINE"] = "1"

# The space a voice print lives in, and nothing else. A voice print is only compared with prints
# stored under the same string, so this names the embedder that produced the values rather than the
# detector that chose the moments: the detector changed, the embedder did not, and a person named on
# an older call is still matched on a call recorded today.
MODEL_VERSION: Final = (
    "pyannote/speaker-diarization-community-1@"
    "3533c8cf8e369892e6b79ff1bf80f7b0286a54ee"
)
EMBEDDING_PIPELINE: Final = "pyannote/speaker-diarization-community-1"
EMBEDDING_REVISION: Final = "3533c8cf8e369892e6b79ff1bf80f7b0286a54ee"

TURN_MODEL: Final = "nvidia/Nemotron-3-Diarization@a435e9867d79e789e90053f9b6d6834053af564a"
TURN_MODEL_ID: Final = "nvidia/Nemotron-3-Diarization"
TURN_MODEL_REVISION: Final = "a435e9867d79e789e90053f9b6d6834053af564a"

SAMPLING_RATE: Final = 16000
EMBEDDING_DIMENSION: Final = 256
FRAME_SECONDS: Final = 0.01
SPEECH_THRESHOLD: Final = 0.5

# The turn model answers with eight channels, ordered by first arrival. A call that holds more
# voices than this is separated into the eight that spoke first.
MAX_VOICES: Final = 8

# A run of speech shorter than this is a click, a breath or the tail of a word, and it carries
# nothing to name: the shortest runs on the calls measured here were 0.03 s to 0.1 s long, and 14 of
# the 217 runs of a many-voice call were under a quarter of a second.
MINIMUM_TURN_SECONDS: Final = 0.25

# One voice that pauses for less than this, with no other voice inside the pause, kept talking.
# Measured pauses between two runs of one voice reach down to 0.19 s, which is a breath inside a
# sentence rather than the end of a turn.
JOIN_GAP_SECONDS: Final = 0.30

# The turn model is not handed the whole call at once. Its encoder cost grows with the square of the
# length it is given: measured on this Mac, ten minutes of audio ran in 1.6 GB of memory and seventy
# minutes in 4.3 GB, and the library this app records holds calls of two and a half hours. A call
# longer than the threshold below is read in windows, and the voices of one window are joined to the
# voices of the windows before it by the same measure the app joins two pieces of one voice.
WINDOW_SECONDS: Final = 480.0
WINDOW_THRESHOLD_SECONDS: Final = 1200.0
MERGE_SIMILARITY: Final = 0.75

# The window the embedder reads in one step, and the share of it a voice has to be talking for on
# its own before its value is used. Both mirror the pyannote pipeline this app has always stored its
# voice prints with, so a centroid computed here means the same thing as one computed there.
CHUNK_SECONDS: Final = 10.0
ACTIVE_FRAMES_RATIO: Final = 0.2


class SegmentPayload(TypedDict):
    start: float
    end: float
    speaker: str


class SpeakerPayload(TypedDict):
    speaker: str
    embedding: list[float]


class OutputPayload(TypedDict):
    model: str
    turnModel: str
    segments: list[SegmentPayload]
    speakers: list[SpeakerPayload]


# The descriptor the one JSON payload is written to. It is set by silence_library_output, and a
# plain print is the fallback for a caller that runs main without it, which only a test does.
PAYLOAD_DESCRIPTOR: int | None = None


def silence_library_output() -> None:
    """Keep the standard output for the payload alone, and send library chatter to the error stream.

    transformers 5.18 prints a documentation warning of its own on the standard output the moment it
    is imported, and this script's whole contract with the app is one JSON object there: the warning
    in front of it made a pass that had found every voice look like a script that wrote nothing.
    The descriptor is duplicated first, so the payload still reaches the file the app reads.
    """
    global PAYLOAD_DESCRIPTOR
    PAYLOAD_DESCRIPTOR = os.dup(1)
    os.dup2(2, 1)
    sys.stdout = sys.stderr


def emit(payload) -> None:
    """Write one JSON object to the standard output the app reads, and nothing else."""
    data = json.dumps(payload, allow_nan=False, separators=(",", ":")).encode("utf-8")
    if PAYLOAD_DESCRIPTOR is None:
        sys.stdout.write(data.decode("utf-8") + "\n")
        return
    os.write(PAYLOAD_DESCRIPTOR, data + b"\n")


def check_audio_decoder() -> None:
    """Exercise TorchCodec and FFmpeg with a real, tiny WAV file."""
    import tempfile
    import wave
    from torchcodec.decoders import AudioDecoder

    with tempfile.TemporaryDirectory() as directory:
        audio = Path(directory) / "runtime-check.wav"
        with wave.open(str(audio), "wb") as output:
            output.setnchannels(1)
            output.setsampwidth(2)
            output.setframerate(SAMPLING_RATE)
            output.writeframes(b"\x00\x00" * 160)
        AudioDecoder(str(audio))


class EmbeddingValues:
    """The one tensor method this file uses, so a check can pass plain lists."""

    def __init__(self, values: list[float]) -> None:
        self._values = values

    def tolist(self) -> list[float]:
        return list(self._values)


def normalized_embedding(values) -> list[float]:
    """Return one finite unit-length centroid, or an empty list when there is none to use.

    pyannote hands back a centroid of the wrong size, or one holding a value that is not a number,
    for a voice it heard too little of. Raising on it ended the whole pass: the 2026-09-22 13:44
    call stood at this stage for five attempts, each one stopped by a single such voice. The voice
    is passed over instead, so its turns still reach the transcript and only matching it to a person
    by voice is given up. A centroid of no length was already treated this way.
    """
    embedding = [float(value) for value in values.tolist()]
    if len(embedding) != EMBEDDING_DIMENSION or not all(map(math.isfinite, embedding)):
        return []
    norm = math.sqrt(math.fsum(value * value for value in embedding))
    if norm <= 0:
        return []
    return [value / norm for value in embedding]


def self_check() -> None:
    """Put built-in centroids through the rules above and print the answer.

    pyannote and its model are left out on purpose: the packaged app carries them, and a machine
    without them can still run this. The three voices are the three answers a real pass gives. One
    centroid can be matched, one holds a value that is not a number, and one has the wrong length.
    Every voice keeps its turns, and only the first is offered for matching.
    """
    centroids = {
        "SPEAKER_00": [1.0] + [0.0] * (EMBEDDING_DIMENSION - 1),
        "SPEAKER_01": [float("nan")] + [0.0] * (EMBEDDING_DIMENSION - 1),
        "SPEAKER_02": [0.5, 0.5],
    }
    speakers: list[SpeakerPayload] = []
    for speaker, values in centroids.items():
        embedding = normalized_embedding(EmbeddingValues(values))
        if embedding:
            speakers.append({"speaker": speaker, "embedding": embedding})
    segments: list[SegmentPayload] = [
        {"start": float(index), "end": float(index) + 1.0, "speaker": speaker}
        for index, speaker in enumerate(centroids)
    ]
    payload: OutputPayload = {
        "model": MODEL_VERSION,
        "turnModel": TURN_MODEL,
        "segments": segments,
        "speakers": speakers,
    }
    emit(payload)


def voice_label(index: int) -> str:
    return f"SPEAKER_{index:02d}"


def on_accelerator(module, torch) -> None:
    """Put a model on the GPU when the machine has one, and leave it on the CPU when it does not."""
    if torch.backends.mps.is_available():
        module.to(torch.device("mps"))
    elif torch.cuda.is_available():
        module.to(torch.device("cuda"))


def load_turn_model():
    from transformers import AutoModelForAudioFrameClassification, AutoProcessor

    processor = AutoProcessor.from_pretrained(TURN_MODEL_ID, revision=TURN_MODEL_REVISION)
    model = AutoModelForAudioFrameClassification.from_pretrained(
        TURN_MODEL_ID, revision=TURN_MODEL_REVISION
    )
    model.eval()
    return processor, model


def load_embedder():
    from pyannote.audio import Pipeline

    return Pipeline.from_pretrained(EMBEDDING_PIPELINE, revision=EMBEDDING_REVISION)


def read_audio(audio: Path):
    """Read a file as the mono 16 kHz the turn model was trained on."""
    import librosa

    samples, _ = librosa.load(str(audio), sr=SAMPLING_RATE, mono=True)
    return samples


def speech_activity(processor, model, samples):
    """Run the turn model over one stretch of audio and return its speech frame by frame.

    The result is one column per voice and one row per 10 ms of the stretch it was given.
    """
    import numpy as np
    import torch

    inputs = processor(samples, sampling_rate=SAMPLING_RATE).to(
        model.device, dtype=model.dtype
    )
    with torch.inference_mode():
        logits = model(**inputs).logits
    probabilities = torch.sigmoid(logits)[0].to(torch.float32).cpu().numpy()
    turns = processor.extract_speaker_dict(logits, inputs.get("attention_mask"))[0]
    # 0.0 and 1.0 rather than probabilities: the embedder asks which frames hold one voice alone,
    # and a soft value has no answer to that.
    activity = (probabilities > SPEECH_THRESHOLD).astype(np.float32)
    return activity, turns


def window_slices(sample_count: int) -> list[tuple[float, int, int]]:
    """The stretches of a call the turn model is run over, as a start in seconds and two indices."""
    window_samples = int(round(WINDOW_SECONDS * SAMPLING_RATE))
    if sample_count <= int(round(WINDOW_THRESHOLD_SECONDS * SAMPLING_RATE)):
        return [(0.0, 0, sample_count)]
    slices: list[tuple[float, int, int]] = []
    first = 0
    while first < sample_count:
        last = min(sample_count, first + window_samples)
        slices.append((first / SAMPLING_RATE, first, last))
        first = last
    return slices


def long_enough(turns: list[dict]) -> list[SegmentPayload]:
    """Keep the runs of one stretch that are long enough to be speech."""
    return [
        {
            "start": float(turn["Start"]),
            "end": float(turn["End"]),
            "speaker": voice_label(int(turn["Speaker"])),
        }
        for turn in turns
        if float(turn["End"]) - float(turn["Start"]) >= MINIMUM_TURN_SECONDS
    ]


def joined_runs(segments: list[SegmentPayload]) -> list[SegmentPayload]:
    """Join one voice's runs across a pause too short to be the end of a turn.

    A pause with another voice inside it is not a pause: joining across it would hand the other
    voice's words to this one, so those two runs stay apart.
    """
    by_voice: dict[str, list[SegmentPayload]] = {}
    for segment in segments:
        by_voice.setdefault(segment["speaker"], []).append(segment)
    for spans in by_voice.values():
        spans.sort(key=lambda span: span["start"])

    def another_voice_speaks(start: float, end: float, speaker: str) -> bool:
        for other, spans in by_voice.items():
            if other == speaker:
                continue
            for span in spans:
                if span["start"] >= end:
                    break
                if span["end"] > start:
                    return True
        return False

    joined: list[SegmentPayload] = []
    for speaker, spans in by_voice.items():
        current = dict(spans[0])
        for span in spans[1:]:
            gap = span["start"] - current["end"]
            if 0 <= gap < JOIN_GAP_SECONDS and not another_voice_speaks(
                current["end"], span["start"], speaker
            ):
                current["end"] = span["end"]
            else:
                joined.append(current)
                current = dict(span)
        joined.append(current)
    joined.sort(key=lambda segment: (segment["start"], segment["speaker"]))
    return joined


def voice_prints(
    embedder, audio: Path, activity, speakers: set[str], start: float
) -> list[SpeakerPayload]:
    """Measure one centroid per voice, over the frames where that voice speaks alone.

    The audio is read in chunks rather than in one piece: an hour of it holds 58 million samples,
    and the embedder reads a waveform per chunk, so the memory it needs is the size of a chunk and
    not the size of the call. A voice's value is the mean of its chunk values where it talks alone
    for at least a fifth of the chunk, which is the rule the pyannote pipeline applies to its own
    values before it clusters them. The start is where this stretch begins in the call.
    """
    import numpy as np
    from pyannote.core import SlidingWindow, SlidingWindowFeature

    frame_count, voice_count = activity.shape
    chunk_frames = int(round(CHUNK_SECONDS / FRAME_SECONDS))
    chunk_count = max(1, math.ceil(frame_count / chunk_frames))
    padded = np.zeros((chunk_count * chunk_frames, voice_count), dtype=np.float32)
    padded[:frame_count] = activity
    chunks = padded.reshape(chunk_count, chunk_frames, voice_count)
    window = SlidingWindow(start=start, duration=CHUNK_SECONDS, step=CHUNK_SECONDS)
    embeddings = embedder.get_embeddings(
        str(audio), SlidingWindowFeature(chunks, window), exclude_overlap=True
    )

    alone = chunks * (chunks.sum(axis=2, keepdims=True) == 1)
    alone_frames = alone.sum(axis=1)
    speaking_frames = chunks.sum(axis=1)
    measured = ~np.isnan(embeddings).any(axis=2)
    # A voice is measured over the chunks where it talks on its own for at least a fifth of the
    # chunk, which is the share the pyannote pipeline asks of a value before it clusters it. A voice
    # that never reaches that share is measured over every chunk it speaks in instead. Measured on a
    # call read in windows: one voice held 49 seconds of speech and never a fifth of one chunk, and a
    # voice with no value at all is a voice that cannot be joined to its own name in the window
    # before, so it came back as a second person with the same 49 seconds.
    alone_enough = measured & (alone_frames >= ACTIVE_FRAMES_RATIO * chunk_frames)
    any_speech = measured & (speaking_frames > 0)

    speakers_out: list[SpeakerPayload] = []
    for index in range(embeddings.shape[1]):
        label = voice_label(index)
        if label not in speakers:
            continue
        values = embeddings[alone_enough[:, index], index]
        if values.shape[0] == 0:
            values = embeddings[any_speech[:, index], index]
        if values.shape[0] == 0:
            continue
        embedding = normalized_embedding(EmbeddingValues(np.mean(values, axis=0).tolist()))
        if embedding:
            speakers_out.append({"speaker": label, "embedding": embedding})
    return speakers_out


def mean_of(values: list[list[float]]) -> list[float]:
    """The mean of equal-length value lists, one per voice."""
    return [math.fsum(column) / len(values) for column in zip(*values)]


def cosine_similarity(left: list[float], right: list[float]) -> float:
    """How alike two values are, from -1 to 1, as the app's own matcher measures it."""
    product = math.fsum(a * b for a, b in zip(left, right))
    left_norm = math.sqrt(math.fsum(a * a for a in left))
    right_norm = math.sqrt(math.fsum(b * b for b in right))
    if left_norm <= 0 or right_norm <= 0:
        return 0.0
    return product / (left_norm * right_norm)


def window_voices(embedder, audio: Path, start: float, activity, turns) -> dict:
    """What one stretch of a call holds: its turns, one value per voice, and when each one arrived."""
    segments = long_enough(turns)
    speakers = {segment["speaker"] for segment in segments}
    prints = {
        payload["speaker"]: payload["embedding"]
        for payload in voice_prints(embedder, audio, activity, speakers, start)
    }
    seconds = {
        speaker: math.fsum(
            segment["end"] - segment["start"]
            for segment in segments
            if segment["speaker"] == speaker
        )
        for speaker in speakers
    }
    arrival = {
        speaker: start
        + min(
            segment["start"] for segment in segments if segment["speaker"] == speaker
        )
        for speaker in speakers
    }
    return {
        "turns": [
            {
                "start": round(start + segment["start"], 3),
                "end": round(start + segment["end"], 3),
                "speaker": segment["speaker"],
            }
            for segment in segments
        ],
        "prints": prints,
        "seconds": seconds,
        "arrival": arrival,
    }


def joined_windows(windows: list[dict]) -> tuple[list[SegmentPayload], list[SpeakerPayload]]:
    """One list of turns for the call, and one centroid per voice.

    A call read in windows hands back the same person under a different label in every window, so
    the voices of one window are matched to the voices of the windows before it. The match is the
    app's own rule for two pieces of one voice: pairs are taken from the closest down while both
    sides are free, and a pair closer than the threshold is one voice. A voice whose value could not
    be measured starts a voice of its own, and its turns keep their label, which is what the review
    window already shows for a voice with no value to match.
    """
    voices: list[dict] = []
    mappings: list[dict[str, str]] = []
    for window in windows:
        pairs = [
            (cosine_similarity(values, mean_of(voice["vectors"])), local, index)
            for local, values in window["prints"].items()
            for index, voice in enumerate(voices)
        ]
        pairs.sort(key=lambda pair: (-pair[0], pair[1], pair[2]))
        mapping: dict[str, str] = {}
        claimed_labels: set[str] = set()
        claimed_voices: set[int] = set()
        for score, local, index in pairs:
            if score < MERGE_SIMILARITY or local in claimed_labels or index in claimed_voices:
                continue
            claimed_labels.add(local)
            claimed_voices.add(index)
            mapping[local] = voices[index]["label"]
            voices[index]["vectors"].append(window["prints"][local])
        # The voices left over arrived for the first time, and they are numbered in the order they
        # were first heard so that a call read in one window keeps the model's own order.
        for local in sorted(
            window["seconds"], key=lambda name: (window["arrival"][name], name)
        ):
            if local in mapping:
                continue
            label = voice_label(len(voices))
            mapping[local] = label
            voices.append(
                {
                    "label": label,
                    "vectors": [window["prints"][local]] if local in window["prints"] else [],
                }
            )
        mappings.append(mapping)

    turns: list[SegmentPayload] = []
    for window, mapping in zip(windows, mappings):
        for segment in window["turns"]:
            turns.append(
                {
                    "start": segment["start"],
                    "end": segment["end"],
                    "speaker": mapping[segment["speaker"]],
                }
            )

    speakers: list[SpeakerPayload] = []
    for voice in voices:
        if not voice["vectors"]:
            continue
        embedding = normalized_embedding(
            EmbeddingValues(mean_of(voice["vectors"]))
        )
        if embedding:
            speakers.append({"speaker": voice["label"], "embedding": embedding})
    return joined_runs(turns), speakers


def separate_by_detector(audio: Path) -> OutputPayload:
    """The separation for a call no count was given for: it answers the voices it hears."""
    import torch

    processor, model = load_turn_model()
    on_accelerator(model, torch)
    samples = read_audio(audio)
    detected = []
    for start, first, last in window_slices(len(samples)):
        activity, turns = speech_activity(processor, model, samples[first:last])
        detected.append((start, activity, turns))
    del processor, model, samples

    embedder = load_embedder()
    on_accelerator(embedder, torch)
    windows = [
        window_voices(embedder, audio, start, activity, turns)
        for start, activity, turns in detected
    ]
    segments, speakers = joined_windows(windows)
    if not segments:
        return {
            "model": MODEL_VERSION,
            "turnModel": TURN_MODEL,
            "segments": [],
            "speakers": [],
        }
    return {
        "model": MODEL_VERSION,
        "turnModel": TURN_MODEL,
        "segments": segments,
        "speakers": speakers,
    }


def separate_into_count(audio: Path, count: int) -> OutputPayload:
    """The separation that answers exactly the number it is given.

    A count is a fact the app holds -- the people on the call, less the person recording -- or a
    number a person counted in the review window, and this is the only separation that can be held
    to one. It runs the embedder over its own turns, as it did before the turn model above was
    added, and it takes minutes where the turn model takes seconds.
    """
    import torch

    embedder = load_embedder()
    on_accelerator(embedder, torch)
    output = embedder(str(audio), num_speakers=count)
    diarization = output.exclusive_speaker_diarization

    segments: list[SegmentPayload] = []
    for turn, _, speaker in diarization.itertracks(yield_label=True):
        segments.append(
            {
                "start": round(turn.start, 3),
                "end": round(turn.end, 3),
                "speaker": speaker,
            }
        )
    segments.sort(key=lambda segment: segment["start"])

    speakers: list[SpeakerPayload] = []
    embeddings = output.speaker_embeddings
    if embeddings is not None:
        labels = list(output.speaker_diarization.labels())
        for index, speaker in enumerate(labels):
            # A label the pipeline left out of its embeddings is not a fault: the voice keeps its
            # turns in the segments above and is named by hand in the review window.
            if index >= len(embeddings):
                continue
            embedding = normalized_embedding(embeddings[index])
            if embedding:
                speakers.append({"speaker": speaker, "embedding": embedding})

    return {
        "model": MODEL_VERSION,
        "turnModel": TURN_MODEL,
        "segments": segments,
        "speakers": speakers,
    }


def main() -> None:
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("audio", type=Path, nargs="?", help="16kHz mono WAV file")
    parser.add_argument("--check", action="store_true", help="Check the local runtime and cached models")
    parser.add_argument("--num-speakers", type=int, default=0,
                        help="Separate into exactly this many voices")
    parser.add_argument("--self-check", action="store_true",
                        help="Put built-in centroids through the embedding rules")
    args = parser.parse_args()

    if args.self_check:
        self_check()
        return

    if args.check:
        check_audio_decoder()
        load_turn_model()
        load_embedder()
        payload: OutputPayload = {
            "model": MODEL_VERSION,
            "turnModel": TURN_MODEL,
            "segments": [],
            "speakers": [],
        }
        emit(payload)
        return
    if args.audio is None:
        parser.error("audio is required unless --check or --self-check is used")

    if args.num_speakers > 0:
        payload = separate_into_count(args.audio, args.num_speakers)
    else:
        payload = separate_by_detector(args.audio)
    emit(payload)


if __name__ == "__main__":
    silence_library_output()
    try:
        main()
    except Exception as error:  # noqa: BROAD_EXCEPT_OK
        import traceback
        emit({"error": traceback.format_exc()})
        sys.exit(1)
