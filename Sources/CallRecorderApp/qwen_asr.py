#!/usr/bin/env python3
"""Transcribe one recording with Qwen3-ASR on MLX.

The model reads a piece of audio at a time, and the library around it carries two traps that cost
a long meeting its second half:

* the token budget is spent by the file rather than by the piece, and the library stops once the
  budget is gone. A seventy-minute call came back ending in the middle of a sentence at exactly
  eight thousand one hundred and ninety-two tokens;
* a piece that opens on noise can send the decoder into a loop that repeats one letter until the
  budget runs out. One ten-minute piece of the same call answered with six thousand seven hundred
  words of the letter "с".

This script reads the call in overlapping pieces, gives every piece its own budget, and checks each
answer before it is kept. A piece whose words are mostly one repeated token is read again through a
narrower window; one that loops twice is dropped and counted, and the app has its own rule for a
transcript that lost too much.

Usage:
  python3 qwen_asr.py --model <folder> --audio <wav> --output <json> [--language ru] [--hotwords a,b]

The audio must already be 16 kHz mono, which the app converts it to before calling this script.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time

os.environ.setdefault("HF_HUB_OFFLINE", "1")
os.environ.setdefault("HF_HUB_DISABLE_TELEMETRY", "1")
os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")

from pathlib import Path

#: What an import the reading needs failed with, or None when everything is in place.
#:
#: An interpreter that cannot load these is answered with a sentence and exit 2, which is what the
#: app shows. Raised as the import happened, the module the runtime lacks would read as a Python
#: traceback in the middle of a call's log instead of as a runtime to install.
RUNTIME_IMPORT_ERROR: str | None = None

try:
    import mlx.core as mx
    import numpy as np
except Exception as error:  # noqa: BLE001 - reported, not swallowed
    RUNTIME_IMPORT_ERROR = str(error)
    np = None

#: Share of one repeated word above which an answer is read as a loop rather than as speech.
REPEAT_SHARE_LIMIT = 0.25

#: A loop is a long answer with no variety, so the check is only worth running past this length.
REPEAT_COUNT_FLOOR = 40


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Read a recording with Qwen3-ASR.")
    parser.add_argument("--model", required=True, help="Folder holding the MLX model.")
    parser.add_argument("--audio", required=True, help="16 kHz mono wave to read.")
    parser.add_argument("--output", required=True, help="Where the JSON goes.")
    parser.add_argument("--language", default="auto", help="Language code, or auto.")
    # Fifteen seconds, measured on the 2026-09-24 call (4221 s of Russian and English): 362 pieces
    # in 247.7 s, against 14 pieces of about five minutes in 255.6 s. Shorter pieces are not slower
    # here, and they place a speaker on a turn four times more closely, because the diarization is
    # merged into the transcript by the overlap of a piece.
    parser.add_argument("--chunk-seconds", type=float, default=15.0)
    parser.add_argument("--overlap-seconds", type=float, default=1.5)
    parser.add_argument("--max-tokens", type=int, default=2048)
    parser.add_argument("--hotwords", default="", help="Comma-separated names and terms.")
    return parser.parse_args()


def spoken_words(text: str) -> list[str]:
    return [word for word in (text or "").replace("\n", " ").split(" ") if word]


def is_looping(text: str) -> bool:
    """Whether an answer is a decoder loop rather than speech."""
    tokens = spoken_words(text)
    if len(tokens) < REPEAT_COUNT_FLOOR * 2:
        return False
    counts: dict[str, int] = {}
    for token in tokens:
        counts[token] = counts.get(token, 0) + 1
    return max(counts.values()) / len(tokens) >= REPEAT_SHARE_LIMIT


def language_code(value: object) -> str:
    """The language the model reported, as a two-letter code.

    The library answers with a list when the audio was read in batches and with a string when it
    was not, so both shapes arrive here.
    """
    if isinstance(value, (list, tuple)):
        value = value[0] if value else None
    if not isinstance(value, str):
        return ""
    code = value.strip().lower()
    return code if len(code) == 2 else ""


def quiet_cut(audio: "np.ndarray", rate: int, start: float, end: float) -> float:
    """Moves a cut back to the quietest moment near it, so no word is split in two."""
    window = int(rate * min(10.0, max(1.0, (end - start) / 4)))
    edge = int(end * rate)
    tail = audio[max(0, edge - window):edge]
    if len(tail) == 0:
        return end
    frame = max(1, int(rate * 0.05))
    trimmed = tail[: len(tail) - len(tail) % frame]
    if len(trimmed) == 0:
        return end
    energy = np.sqrt((trimmed.reshape(-1, frame) ** 2).mean(axis=1))
    quiet = int(np.argmin(energy))
    return max(start + 1.0, (edge - len(tail)) / rate + quiet * 0.05)


def split_audio(
    audio: "np.ndarray", rate: int, chunk_seconds: float, overlap_seconds: float
) -> list[tuple[float, float]]:
    total = len(audio) / rate
    if total <= chunk_seconds:
        return [(0.0, total)]
    pieces: list[tuple[float, float]] = []
    start = 0.0
    while start < total - 1.0:
        end = min(start + chunk_seconds, total)
        if end < total:
            end = quiet_cut(audio, rate, start, end)
        pieces.append((start, end))
        start = max(end - overlap_seconds, start + 1.0)
    return pieces


def main() -> int:
    args = parse_args()
    started = time.time()

    if RUNTIME_IMPORT_ERROR is not None:
        print(f"the speech runtime cannot read audio: {RUNTIME_IMPORT_ERROR}", file=sys.stderr)
        return 2
    try:
        from mlx_audio.stt.utils import load_audio, load_model
    except Exception as error:  # noqa: BLE001 - reported, not swallowed
        print(f"the speech runtime cannot read audio: {error}", file=sys.stderr)
        return 2

    if not (Path(args.model) / "config.json").exists():
        print(f"the model folder is incomplete: {args.model}", file=sys.stderr)
        return 3

    model = load_model(args.model)
    rate = int(model.sample_rate)
    audio = np.asarray(load_audio(args.audio), dtype=np.float32)
    language = None if args.language in ("", "auto", "unknown") else args.language
    hotwords = [word.strip() for word in args.hotwords.split(",") if word.strip()]

    pieces = split_audio(audio, rate, args.chunk_seconds, args.overlap_seconds)
    print(
        f"reading {len(audio) / rate:.1f}s of audio in {len(pieces)} piece(s)",
        file=sys.stderr,
    )

    segments: list[dict[str, object]] = []
    # A piece is dropped either because there was nothing in it to read, which is what a recording
    # of silence answers, or because the model answered with something unusable. The difference
    # decides the exit code: silence is a reading of a quiet call, and unusable answers on every
    # piece are a runtime that could not read at all. Reported as one number, a broken run would
    # look like a call nobody spoke on, and the app would keep an empty reading as the truth.
    dropped = 0
    unreadable = 0
    failed_attempts = 0
    tokens = 0
    detected = ""
    for index, (start, end) in enumerate(pieces):
        answer = None
        for attempt, (piece_start, piece_end) in enumerate(
            [(start, end), (start, min(end, start + (end - start) / 2))]
        ):
            try:
                result = model.generate(
                    audio[int(piece_start * rate):int(piece_end * rate)],
                    max_tokens=args.max_tokens,
                    language=language,
                    hotwords=hotwords or None,
                )
            except Exception as error:  # noqa: BLE001 - reported, not swallowed
                print(f"piece {index} attempt {attempt} failed: {error}", file=sys.stderr)
                failed_attempts += 1
                continue
            tokens += int(getattr(result, "generation_tokens", 0) or 0)
            if not detected:
                detected = language_code(getattr(result, "language", None))
            text = (result.text or "").strip()
            if is_looping(text):
                print(f"piece {index} attempt {attempt} looped", file=sys.stderr)
                unreadable += 1
                continue
            if text:
                answer = {"start": piece_start, "end": piece_end, "text": text}
                break
        # Every piece releases its buffers, including one that was thrown away: a loop holds the
        # cache of the whole decode, which is what turns a stuck piece into a growing process.
        mx.clear_cache()
        if answer is None:
            dropped += 1
            continue
        segments.append(answer)

    payload = {
        "language": args.language,
        "detectedLanguage": detected,
        "duration": len(audio) / rate,
        "segments": segments,
        "dropped": dropped,
        "generationTokens": tokens,
        "seconds": time.time() - started,
    }
    with open(args.output, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, ensure_ascii=False)
    print(
        f"wrote {len(segments)} piece(s), dropped {dropped}, {tokens} tokens "
        f"in {time.time() - started:.1f}s",
        file=sys.stderr,
    )
    if not segments and (unreadable or failed_attempts):
        print(
            f"no piece of {len(pieces)} could be read: {unreadable} answer(s) repeated instead of "
            f"speaking, {failed_attempts} attempt(s) raised. The runtime or the model is not "
            "reading this audio.",
            file=sys.stderr,
        )
        return 4
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
