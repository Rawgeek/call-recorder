#!/usr/bin/env -S .venv/bin/python3
"""Speaker diarization using pyannote.audio 4.x.

Requires: .venv with pyannote.audio and torch installed, plus access to
          pyannote/speaker-diarization-community-1.

Usage:
  .venv/bin/python3 diarize.py audio.wav [--num-speakers N]
  Outputs diarization turns and speaker centroids as JSON to stdout.
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

MODEL_VERSION: Final = (
    "pyannote/speaker-diarization-community-1@"
    "3533c8cf8e369892e6b79ff1bf80f7b0286a54ee"
)
EMBEDDING_DIMENSION: Final = 256


class SegmentPayload(TypedDict):
    start: float
    end: float
    speaker: str


class SpeakerPayload(TypedDict):
    speaker: str
    embedding: list[float]


class OutputPayload(TypedDict):
    model: str
    segments: list[SegmentPayload]
    speakers: list[SpeakerPayload]


class SpeakerEmbeddingError(RuntimeError):
    """Pyannote returned a centroid outside the supported matching boundary."""


def normalized_embedding(values) -> list[float]:
    """Return one finite unit-length centroid or an empty list for a zero centroid."""
    embedding = [float(value) for value in values.tolist()]
    if len(embedding) != EMBEDDING_DIMENSION or not all(map(math.isfinite, embedding)):
        raise SpeakerEmbeddingError("Unexpected speaker embedding shape or value.")
    norm = math.sqrt(math.fsum(value * value for value in embedding))
    if norm <= 0:
        return []
    return [value / norm for value in embedding]


def main() -> None:
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("audio", type=Path, nargs="?", help="16kHz mono WAV file")
    parser.add_argument("--check", action="store_true", help="Check the local runtime and cached model")
    parser.add_argument("--num-speakers", type=int, default=0,
                        help="Hint for number of speakers (0 = auto)")
    args = parser.parse_args()

    from pyannote.audio import Pipeline

    pipeline = Pipeline.from_pretrained(
        "pyannote/speaker-diarization-community-1",
        revision=MODEL_VERSION.split("@", 1)[1],
    )

    if args.check:
        print(json.dumps({"model": MODEL_VERSION, "segments": [], "speakers": []}))
        return
    if args.audio is None:
        parser.error("audio is required unless --check is used")

    import torch
    if torch.backends.mps.is_available():
        pipeline.to(torch.device("mps"))
    elif torch.cuda.is_available():
        pipeline.to(torch.device("cuda"))

    kwargs = {}
    if args.num_speakers and args.num_speakers > 0:
        kwargs["num_speakers"] = args.num_speakers

    output = pipeline(str(args.audio), **kwargs)
    diarization = output.exclusive_speaker_diarization

    segments: list[SegmentPayload] = []
    for turn, _, speaker in diarization.itertracks(yield_label=True):
        segments.append({
            "start": round(turn.start, 3),
            "end": round(turn.end, 3),
            "speaker": speaker,
        })

    segments.sort(key=lambda segment: segment["start"])

    speakers: list[SpeakerPayload] = []
    embeddings = output.speaker_embeddings
    if embeddings is not None:
        for index, speaker in enumerate(output.speaker_diarization.labels()):
            embedding = normalized_embedding(embeddings[index])
            if embedding:
                speakers.append({"speaker": speaker, "embedding": embedding})

    payload: OutputPayload = {
        "model": MODEL_VERSION,
        "segments": segments,
        "speakers": speakers,
    }
    print(json.dumps(payload, allow_nan=False, separators=(",", ":")))

if __name__ == "__main__":
    try:
        main()
    except Exception as error:  # noqa: BROAD_EXCEPT_OK
        import traceback
        print(json.dumps({"error": traceback.format_exc()}))
        sys.exit(1)
