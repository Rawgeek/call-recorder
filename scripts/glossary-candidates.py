#!/usr/bin/env python3
"""Find proper nouns in transcript bodies that the glossary does not cover.

    scripts/glossary-candidates.py "path/to/transcripts" "term||term||term"

Only a capitalized word that is NOT the first word of its sentence counts. "Yeah", "And", "But",
and every other sentence opener is capitalized by grammar, and including them buries the few real
terms under a thousand English words.
"""
import re
import sys
from collections import Counter
from pathlib import Path

from transcript_text import transcript_body

folder = Path(sys.argv[1])
terms = {t.strip().lower() for t in sys.argv[2].split("||") if t.strip()}

sentence = re.compile(r"(?<=[.!?])\s+|\n+")
runs = re.compile(r"\b([A-Z][A-Za-z0-9&.\-]{2,}(?:\s+[A-Z][A-Za-z0-9&.\-]+){0,3})")

common = set("""I The A An And But Or So If Then Now Well Yes No Okay Ok Yeah Yep Hey All Right
Let What How Why When Where Who Which That This These Those There They Them Their You Your We Our
Us He She It Its His Her Just Very Maybe Basically Actually Please Thank Sorry Because Once For
Like One Two Three Four Five Six Seven Eight Nine Ten Are Was Were Is Be Been Being Do Does Did
Doesn Have Has Had Can Could Would Should Will Shall May Might Must Not Only Also Even Still
Something Anything Nothing Everything Someone Anyone Everyone Some Any Every No None Both Each
Other Another Such Same Different First Second Last Next After Before During While Since Until
Things Thing People Person Time Day Week Month Year Today Tomorrow Yesterday Morning Afternoon
Evening Night Good Great Fine Sure Cool Nice Perfect Exactly Correct Wrong True False Question
Answer Problem Issues Issue Talking Speaking Mention Add Bring Take Put Get Got Give Send Sent
Check Checking Look Looking See Seen Know Knew Think Thought Mean Means Want Need Try Tried
Work Working Works Call Called Calling Back Forward Over Under Again More Most Less Least
Kind Sort Bit Little Lot Much Many Few Enough Too Also Well Right Left Side Part Piece
""".split())
common_lower = {word.lower() for word in common}

counts = Counter()
files = sorted(folder.glob("*.md"))
for path in files:
    text = path.read_text(encoding="utf-8", errors="replace")
    body = transcript_body(text)
    for chunk in sentence.split(body):
        chunk = chunk.strip()
        if not chunk:
            continue
        words = chunk.split(" ")
        rest = " ".join(words[1:]) if len(words) > 1 else ""
        for match in runs.finditer(rest):
            candidate = re.sub(r"\s+", " ", match.group(1)).strip(" .,")
            if len(candidate) < 4:
                continue
            lowered = candidate.lower()
            if lowered in terms or lowered in common_lower:
                continue
            # The first word of a multi-word run must not itself be a common word.
            head = lowered.split(" ")[0].strip(".,")
            if head in common_lower:
                continue
            counts[candidate] += 1

print(f"files={len(files)} candidates={len(counts)}")
for candidate, count in counts.most_common(80):
    print(f"{count:5d}  {candidate}")
