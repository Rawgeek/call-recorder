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
answer before it is kept. A piece the model does not keep -- it raised, it looped, or it said
nothing at all -- is read again as both of its halves, front first, and each half keeps the times it
has in the call; a half that loops is dropped and counted, and the app has its own rule for a
transcript that lost too much.

Usage:
  python3 qwen_asr.py --model <folder> --audio <wav> --output <json> [--language ru] [--hotwords a,b]
  python3 qwen_asr.py --self-check
  python3 qwen_asr.py --retry-check

The audio must already be 16 kHz mono, which the app converts it to before calling this script.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from collections.abc import Callable
from dataclasses import dataclass

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

#: Copies of one phrase inside an answer that are a decoder loop rather than emphasis.
#:
#: The rule above needs eighty tokens before it looks, and a fifteen-second piece mostly answers
#: with fewer: an answer that says one phrase three times was passed through to the transcript, and
#: the app's own quality guard then refused the whole recording rather than the piece. On
#: 2026-09-29 the nineteen-minute lesson that ran from 11:15 and the thirty-eight-minute one from
#: 14:03 were read twice each and neither transcript was written at all. The numbers are the app's,
#: so the two agree on what a loop is; the answer here is the one every other loop in this script
#: already gets, which is to read the piece again through a narrower window and drop it if it loops
#: twice. A single word is left alone on purpose: a person does say "no no no", which is why the
#: app looks for a phrase of two words or more.
PHRASE_COPY_FLOOR = 3
PHRASE_MINIMUM_WORDS = 2
PHRASE_MAXIMUM_WORDS = 8
PHRASE_SHARE_LIMIT = 0.5


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Read a recording with Qwen3-ASR.")
    parser.add_argument("--model", help="Folder holding the MLX model.")
    parser.add_argument("--audio", help="16 kHz mono wave to read.")
    parser.add_argument("--output", help="Where the JSON goes.")
    parser.add_argument("--language", default="auto", help="Language code, or auto.")
    # Fifteen seconds, measured on the 2026-09-24 call (4221 s of Russian and English): 362 pieces
    # in 247.7 s, against 14 pieces of about five minutes in 255.6 s. Shorter pieces are not slower
    # here, and they place a speaker on a turn four times more closely, because the diarization is
    # merged into the transcript by the overlap of a piece.
    parser.add_argument("--chunk-seconds", type=float, default=15.0)
    parser.add_argument("--overlap-seconds", type=float, default=1.5)
    parser.add_argument("--max-tokens", type=int, default=2048)
    parser.add_argument("--hotwords", default="", help="Comma-separated names and terms.")
    parser.add_argument(
        "--self-check",
        action="store_true",
        help="Answer the loop question for the built-in examples, without a model",
    )
    parser.add_argument(
        "--retry-check",
        action="store_true",
        help="Answer the retry question for the built-in scenarios, without a model",
    )
    return parser.parse_args()


def spoken_words(text: str) -> list[str]:
    return [word for word in (text or "").replace("\n", " ").split(" ") if word]


def is_looping(text: str) -> bool:
    """Whether an answer is a decoder loop rather than speech."""
    tokens = spoken_words(text)
    if len(tokens) >= REPEAT_COUNT_FLOOR * 2:
        counts: dict[str, int] = {}
        for token in tokens:
            counts[token] = counts.get(token, 0) + 1
        if max(counts.values()) / len(tokens) >= REPEAT_SHARE_LIMIT:
            return True
    return repeated_phrase_copies(tokens) >= PHRASE_COPY_FLOOR


def non_overlapping_copies(phrase: tuple[str, ...], tokens: list[str]) -> int:
    """How many copies of one phrase sit end to end, the way the app's cleaning pass takes them."""
    count = 0
    index = 0
    length = len(phrase)
    while index + length <= len(tokens):
        if tuple(tokens[index:index + length]) == phrase:
            count += 1
            index += length
        else:
            index += 1
    return count


def repeated_phrase_copies(tokens: list[str]) -> int:
    """The copies the longest repeated phrase makes up, when they are most of the answer.

    Overlapping runs are not counted, for the reason the app counts them the same way: six words
    that hold three copies of a two-word phrase are three copies and not four, and a person
    agreeing six times in one breath has said nothing twice.
    """
    if len(tokens) < PHRASE_MINIMUM_WORDS * PHRASE_COPY_FLOOR:
        return 0
    longest = min(PHRASE_MAXIMUM_WORDS, len(tokens) // PHRASE_COPY_FLOOR)
    for length in range(longest, PHRASE_MINIMUM_WORDS - 1, -1):
        checked: set[tuple[str, ...]] = set()
        for start in range(0, len(tokens) - length + 1):
            phrase = tuple(tokens[start:start + length])
            if phrase in checked:
                continue
            checked.add(phrase)
            copies = non_overlapping_copies(phrase, tokens)
            if copies < PHRASE_COPY_FLOOR:
                continue
            if (copies - 1) * length / len(tokens) >= PHRASE_SHARE_LIMIT:
                return copies
    return 0


def self_check() -> int:
    """Answer the loop question for the built-in examples, so the rule can be read without a model.

    Every example is a shape a call in this library has produced. An answer this calls a loop is
    read again through a narrower window, and dropped when it loops twice, so the line between the
    two answers below is the line between a piece a call keeps and a piece it loses.
    """
    examples = [
        ("a phrase three times and nothing else", True, "Thank you. Thank you. Thank you."),
        ("a phrase twice is a person", False, "Thank you. Thank you."),
        (
            "a person agreeing six times in one breath",
            False,
            "да да да да да да просто действительно столько стоит конечно лучше казаться они а может быть",
        ),
        ("one word said eighteen times", True, " ".join(["да"] * 18)),
        ("a short answer with one word repeated", False, "Yes, yes, that is right."),
        (
            "ordinary speech",
            False,
            "The warehouse will ship it on Friday and I will check the numbers.",
        ),
        ("a language written without spaces", False, "ใช่ค่ะแต่ว่าเมื่อก่อนปกติเวลาที่คุณครูใส่ไปในกูเกิล"),
        ("a long answer that repeats one word", True, " ".join(["hello"] * 120)),
    ]
    answers = {
        name: {"looping": is_looping(text), "expected": expected}
        for name, expected, text in examples
    }
    print(json.dumps(answers, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if all(answer["looping"] == answer["expected"] for answer in answers.values()) else 1


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


@dataclass
class PieceReading:
    """What one piece of the call answered with, over every window it was read in."""

    segments: list[dict[str, object]]
    tokens: int = 0
    unreadable: int = 0
    failed_attempts: int = 0
    detected: str = ""


def read_piece(
    decoder: Callable[[float, float], object],
    start: float,
    end: float,
    *,
    index: int,
) -> PieceReading:
    """Reads one piece of the call, halving it when the whole of it cannot be kept.

    A piece the model raises on, loops on, or says nothing about is offered again as both of its
    halves, front first. Reading the front half alone is what the retry used to do, and it left the
    back half of every piece it could not keep out of the transcript without a word. Each half is
    placed by the times it has in the call, so a piece costs the words the model could not read and
    nothing else. The loop question is asked of every window the model answers, the whole piece
    included, and a window that loops is dropped and counted rather than kept.
    """
    reading = PieceReading(segments=[])

    def attempt(window_start: float, window_end: float, number: int) -> str | None:
        """One read of one window: its words when they can be kept, and None when they cannot."""
        try:
            result = decoder(window_start, window_end)
        except Exception as error:  # noqa: BLE001 - reported, not swallowed
            print(f"piece {index} attempt {number} failed: {error}", file=sys.stderr)
            reading.failed_attempts += 1
            return None
        reading.tokens += int(getattr(result, "generation_tokens", 0) or 0)
        if not reading.detected:
            reading.detected = language_code(getattr(result, "language", None))
        text = (result.text or "").strip()
        if is_looping(text):
            print(f"piece {index} attempt {number} looped", file=sys.stderr)
            reading.unreadable += 1
            return None
        return text or None

    text = attempt(start, end, 0)
    if text is not None:
        reading.segments.append({"start": start, "end": end, "text": text})
        return reading

    middle = start + (end - start) / 2
    for number, (half_start, half_end) in enumerate(((start, middle), (middle, end)), start=1):
        half = attempt(half_start, half_end, number)
        if half is not None:
            reading.segments.append({"start": half_start, "end": half_end, "text": half})
    return reading


class ScriptedAnswer:
    """What the model answered with, for a check that reads no audio."""

    def __init__(self, text: str, language: str = "ru") -> None:
        self.text = text
        self.language = language
        self.generation_tokens = len(text.split())


class ScriptedDecoder:
    """A model that answers by window, and records every window it was asked about.

    A scenario names the answer every window has, so the check drives the same helper a call drives
    and reads back what that helper asked about and what it kept.
    """

    def __init__(self, answers: dict[tuple[float, float], object]) -> None:
        self.answers = answers
        self.calls: list[tuple[float, float]] = []

    def __call__(self, start: float, end: float) -> object:
        self.calls.append((start, end))
        answer = self.answers.get((start, end))
        if isinstance(answer, Exception):
            raise answer
        if answer is None:
            raise LookupError(f"a window no scenario named: {start}-{end}")
        return answer


def retry_check() -> int:
    """Answer the retry question for the built-in scenarios, so the rule reads without a model.

    Every scenario reads one fifteen-second piece -- the length a call is read in -- with the
    shipping helper, driven by a model that answers by window. The shapes are the ones a piece of a
    call can answer with: the model answered the whole of it, looped on it, raised on it, raised on
    one half of it, and said nothing at all. Each scenario carries what the helper should have read
    and kept, and a scenario that answers differently makes this check fail.
    """
    piece = (0.0, 15.0)
    whole = ScriptedAnswer("the whole piece answers")
    looped = ScriptedAnswer("Thank you. Thank you. Thank you.")
    silent = ScriptedAnswer("")
    failed = RuntimeError("the decoder fell over")
    first = ScriptedAnswer("the first half of the piece")
    second = ScriptedAnswer("the second half of the piece")
    # A scenario is its name, the answer every window has, and what the check expects back: the
    # windows the helper read, the windows it kept, the loops it dropped, and the failures it met.
    scenarios = [
        (
            "a whole piece that answers is read once",
            {piece: whole},
            ([(0.0, 15.0)], [(0.0, 15.0)], 0, 0),
        ),
        (
            "a whole piece that loops is read as both halves",
            {piece: looped, (0.0, 7.5): first, (7.5, 15.0): second},
            ([(0.0, 15.0), (0.0, 7.5), (7.5, 15.0)], [(0.0, 7.5), (7.5, 15.0)], 1, 0),
        ),
        (
            "a whole piece that failed is read as both halves",
            {piece: failed, (0.0, 7.5): first, (7.5, 15.0): second},
            ([(0.0, 15.0), (0.0, 7.5), (7.5, 15.0)], [(0.0, 7.5), (7.5, 15.0)], 0, 1),
        ),
        (
            "a half that failed keeps the half that answered",
            {piece: failed, (0.0, 7.5): failed, (7.5, 15.0): second},
            ([(0.0, 15.0), (0.0, 7.5), (7.5, 15.0)], [(7.5, 15.0)], 0, 2),
        ),
        (
            "a whole piece that said nothing is read as both halves",
            {piece: silent, (0.0, 7.5): silent, (7.5, 15.0): silent},
            ([(0.0, 15.0), (0.0, 7.5), (7.5, 15.0)], [], 0, 0),
        ),
    ]
    answered: dict[str, dict[str, object]] = {}
    for name, answers, expected in scenarios:
        decoder = ScriptedDecoder(answers)
        reading = read_piece(decoder, piece[0], piece[1], index=0)
        observed = (
            [(call[0], call[1]) for call in decoder.calls],
            [(segment["start"], segment["end"]) for segment in reading.segments],
            reading.unreadable,
            reading.failed_attempts,
        )
        # A piece that kept nothing is the dropped piece the run reports, which is also the count
        # the exit code reads: a piece of silence is a quiet call, and not a runtime that failed.
        answered[name] = {
            "calls": [list(window) for window in observed[0]],
            "segments": [list(window) for window in observed[1]],
            "texts": [segment["text"] for segment in reading.segments],
            "unreadable": reading.unreadable,
            "failedAttempts": reading.failed_attempts,
            "dropped": 0 if reading.segments else 1,
            "kept": observed == expected,
        }
    print(json.dumps(answered, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if all(answer["kept"] for answer in answered.values()) else 1


def main() -> int:
    args = parse_args()
    started = time.time()

    if args.self_check:
        return self_check()
    if args.retry_check:
        return retry_check()
    if args.model is None or args.audio is None or args.output is None:
        print(
            "--model, --audio and --output are required unless a check is used",
            file=sys.stderr,
        )
        return 2

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

    def decode(from_seconds: float, to_seconds: float) -> object:
        """Reads one window of the converted track with the model."""
        return model.generate(
            audio[int(from_seconds * rate):int(to_seconds * rate)],
            max_tokens=args.max_tokens,
            language=language,
            hotwords=hotwords or None,
        )

    for index, (start, end) in enumerate(pieces):
        reading = read_piece(decode, start, end, index=index)
        # Every piece releases its buffers, including one that was thrown away: a loop holds the
        # cache of the whole decode, which is what turns a stuck piece into a growing process.
        mx.clear_cache()
        tokens += reading.tokens
        if not detected:
            detected = reading.detected
        if reading.segments:
            segments.extend(reading.segments)
        else:
            dropped += 1
        unreadable += reading.unreadable
        failed_attempts += reading.failed_attempts

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
